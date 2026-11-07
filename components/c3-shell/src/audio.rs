// SPDX-License-Identifier: MIT OR Apache-2.0
//! Volume and sound outputs over the native PipeWire protocol (owner decision on #65: PipeWire has
//! no D-Bus API). One thread runs a PipeWire loop that follows the audio sinks, the default sink
//! (the `default` metadata, which WirePlumber maintains) and the default sink's volume, and reports
//! every change as an [`Audio`] snapshot. Commands come back through a PipeWire channel.
//!
//! Volume is the perceptual scale of `wpctl` and the desktop mixers: the slider position is the
//! cube root of the sink's linear `channelVolumes`.

use std::cell::RefCell;
use std::collections::HashMap;
use std::io::Cursor;
use std::rc::Rc;

use pipewire as pw;
use pw::metadata::Metadata;
use pw::node::Node;
use pw::spa;
use pw::spa::pod::deserialize::PodDeserializer;
use pw::spa::pod::serialize::PodSerializer;
use pw::spa::pod::{Object, Pod, Property, Value, ValueArray};
use pw::types::ObjectType;

/// What the control centre shows of the audio system.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Audio {
    /// Default sink's volume, 0.0..=1.0 on the perceptual scale; `None` without a default sink.
    pub volume: Option<f32>,
    pub outputs: Vec<Output>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Output {
    /// PipeWire node id.
    pub id: u32,
    pub name: String,
    /// The device kind ("Bluetooth", "HDMI", ...); empty when there is nothing useful to say.
    pub detail: String,
    pub selected: bool,
}

pub enum Command {
    /// Perceptual volume, 0.0..=1.0, on the default sink.
    SetVolume(f32),
    /// Make the sink with this node id the default.
    SelectOutput(u32),
}

pub struct Handle(pw::channel::Sender<Command>);

impl Handle {
    pub fn send(&self, c: Command) {
        self.0.send(c).ok();
    }
}

/// Starts the PipeWire thread. `on_change` is called on that thread, so it must hand the snapshot
/// to the UI thread itself. Returns `None` if the thread cannot start; a missing PipeWire server
/// only ends the thread, and the control centre then shows no volume.
pub fn start(on_change: impl Fn(Audio) + Send + 'static) -> Option<Handle> {
    let (tx, rx) = pw::channel::channel::<Command>();
    std::thread::Builder::new()
        .name("pipewire".into())
        .spawn(move || {
            if let Err(e) = run(rx, on_change) {
                eprintln!("control centre: PipeWire unavailable: {e}");
            }
        })
        .ok()?;
    Some(Handle(tx))
}

/// Linear gain (what PipeWire stores) to slider position and back.
pub fn to_slider(linear: f32) -> f32 {
    linear.max(0.).cbrt().min(1.)
}
pub fn to_linear(slider: f32) -> f32 {
    slider.clamp(0., 1.).powi(3)
}

/// The sink name in the `default.audio.sink` metadata value, which is JSON `{"name":"..."}`.
pub fn default_sink_name(value: &str) -> Option<&str> {
    let rest = value.split("\"name\"").nth(1)?;
    let rest = rest
        .trim_start()
        .strip_prefix(':')?
        .trim_start()
        .strip_prefix('"')?;
    rest.split('"').next() // ponytail: no escapes; node names are [A-Za-z0-9_.:-]
}

/// Mean of `channelVolumes` in a Props pod.
pub fn channel_volume(pod: &[u8]) -> Option<f32> {
    let (_, Value::Object(obj)) = PodDeserializer::deserialize_any_from(pod).ok()? else {
        return None;
    };
    obj.properties.iter().find_map(|p| match &p.value {
        Value::ValueArray(ValueArray::Float(v))
            if p.key == spa::sys::SPA_PROP_channelVolumes && !v.is_empty() =>
        {
            Some(v.iter().sum::<f32>() / v.len() as f32)
        }
        _ => None,
    })
}

/// A Props pod setting every one of `channels` to `linear`.
pub fn volume_pod(linear: f32, channels: usize) -> Vec<u8> {
    let obj = Object {
        type_: spa::sys::SPA_TYPE_OBJECT_Props,
        id: spa::sys::SPA_PARAM_Props,
        properties: vec![Property::new(
            spa::sys::SPA_PROP_channelVolumes,
            Value::ValueArray(ValueArray::Float(vec![linear; channels.max(1)])),
        )],
    };
    PodSerializer::serialize(Cursor::new(Vec::new()), &Value::Object(obj))
        .expect("serialising a Props pod")
        .0
        .into_inner()
}

struct Sink {
    node: Node,
    /// `node.name`, what the default metadata refers to.
    name: String,
    description: String,
    detail: String,
    linear: Option<f32>,
    channels: usize,
    _listener: pw::node::NodeListener,
}

#[derive(Default)]
struct Model {
    sinks: HashMap<u32, Sink>,
    default_name: Option<String>,
    metadata: Option<Metadata>,
}

impl Model {
    fn snapshot(&self) -> Audio {
        let mut outputs: Vec<Output> = self
            .sinks
            .iter()
            .map(|(id, s)| Output {
                id: *id,
                name: s.description.clone(),
                detail: s.detail.clone(),
                selected: self.default_name.as_deref() == Some(&s.name),
            })
            .collect();
        outputs.sort_by_key(|o| o.id);
        let volume = self
            .sinks
            .values()
            .find(|s| self.default_name.as_deref() == Some(&s.name))
            .and_then(|s| s.linear)
            .map(to_slider);
        Audio { volume, outputs }
    }
}

fn detail(props: &spa::utils::dict::DictRef) -> String {
    let bus = props.get("device.bus").unwrap_or("");
    let form = props.get("device.form-factor").unwrap_or("");
    let port = props.get("node.name").unwrap_or("");
    match (bus, form) {
        ("bluetooth", _) => "Bluetooth".into(),
        ("usb", _) => "USB".into(),
        _ if port.contains("hdmi") => "HDMI".into(),
        _ => String::new(),
    }
}

fn run(
    rx: pw::channel::Receiver<Command>,
    on_change: impl Fn(Audio) + 'static,
) -> Result<(), Box<dyn std::error::Error>> {
    pw::init();
    let main_loop = pw::main_loop::MainLoopRc::new(None)?;
    let context = pw::context::ContextRc::new(&main_loop, None)?;
    let core = context.connect_rc(None)?;
    let registry = core.get_registry_rc()?;

    let model = Rc::new(RefCell::new(Model::default()));
    let on_change = Rc::new(on_change);
    let last = Rc::new(RefCell::new(None::<Audio>));
    // Tells the UI only when the snapshot differs from the last one sent.
    let publish = {
        let (model, on_change, last) = (model.clone(), on_change.clone(), last.clone());
        Rc::new(move || {
            let now = model.borrow().snapshot();
            if last.borrow().as_ref() != Some(&now) {
                *last.borrow_mut() = Some(now.clone());
                on_change(now);
            }
        })
    };

    let metadata_listener = Rc::new(RefCell::new(None));
    let registry_weak = registry.downgrade();
    let _reg = registry
        .add_listener_local()
        .global({
            let (model, publish, metadata_listener) =
                (model.clone(), publish.clone(), metadata_listener.clone());
            move |obj| {
                let Some(registry) = registry_weak.upgrade() else {
                    return;
                };
                match obj.type_ {
                    ObjectType::Node => {
                        let Some(props) = obj.props.as_ref() else {
                            return;
                        };
                        if props.get("media.class") != Some("Audio/Sink") {
                            return;
                        }
                        let name = props.get("node.name").unwrap_or_default().to_string();
                        let description =
                            props.get("node.description").unwrap_or(&name).to_string();
                        let detail = detail(props);
                        let Ok(node) = registry.bind::<Node, _>(obj) else {
                            return;
                        };
                        let id = obj.id;
                        let listener = node
                            .add_listener_local()
                            .param({
                                let (model, publish) = (model.clone(), publish.clone());
                                move |_, _, _, _, param: Option<&Pod>| {
                                    let Some(bytes) = param.map(Pod::as_bytes) else {
                                        return;
                                    };
                                    if let Some(v) = channel_volume(bytes) {
                                        if let Some(s) = model.borrow_mut().sinks.get_mut(&id) {
                                            s.linear = Some(v);
                                        }
                                        publish();
                                    }
                                }
                            })
                            .register();
                        node.subscribe_params(&[spa::param::ParamType::Props]);
                        model.borrow_mut().sinks.insert(
                            id,
                            Sink {
                                node,
                                name,
                                description,
                                detail,
                                linear: None,
                                channels: 2,
                                _listener: listener,
                            },
                        );
                        publish();
                    }
                    ObjectType::Metadata => {
                        if obj.props.as_ref().and_then(|p| p.get("metadata.name"))
                            != Some("default")
                        {
                            return;
                        }
                        let Ok(md) = registry.bind::<Metadata, _>(obj) else {
                            return;
                        };
                        let l = md
                            .add_listener_local()
                            .property({
                                let (model, publish) = (model.clone(), publish.clone());
                                move |_subject, key, _type, value| {
                                    if key == Some("default.audio.sink") {
                                        model.borrow_mut().default_name =
                                            value.and_then(default_sink_name).map(str::to_string);
                                        publish();
                                    }
                                    0
                                }
                            })
                            .register();
                        *metadata_listener.borrow_mut() = Some(l);
                        model.borrow_mut().metadata = Some(md);
                    }
                    _ => {}
                }
            }
        })
        .global_remove({
            let (model, publish) = (model.clone(), publish.clone());
            move |id| {
                if model.borrow_mut().sinks.remove(&id).is_some() {
                    publish();
                }
            }
        })
        .register();

    let _cmd = rx.attach(main_loop.loop_(), {
        let (model, publish) = (model.clone(), publish.clone());
        move |c| {
            let mut m = model.borrow_mut();
            match c {
                Command::SetVolume(v) => {
                    let default = m.default_name.clone();
                    if let Some(s) = m
                        .sinks
                        .values_mut()
                        .find(|s| Some(&s.name) == default.as_ref())
                    {
                        let linear = to_linear(v);
                        let bytes = volume_pod(linear, s.channels);
                        if let Some(pod) = Pod::from_bytes(&bytes) {
                            s.node.set_param(spa::param::ParamType::Props, 0, pod);
                        }
                        s.linear = Some(linear);
                    }
                }
                Command::SelectOutput(id) => {
                    if let (Some(s), Some(md)) = (m.sinks.get(&id), m.metadata.as_ref()) {
                        let json = format!("{{\"name\":\"{}\"}}", s.name);
                        md.set_property(
                            0,
                            "default.configured.audio.sink",
                            Some("Spa:String:JSON"),
                            Some(&json),
                        );
                    }
                }
            }
            drop(m);
            publish();
        }
    });

    // Losing the server ends the thread (and with it the volume row, until the shell restarts).
    let ml = main_loop.downgrade();
    let _core = core
        .add_listener_local()
        .error(move |id, _, _, msg| {
            eprintln!("control centre: PipeWire error: {msg}");
            if id == 0
                && let Some(ml) = ml.upgrade()
            {
                ml.quit();
            }
        })
        .register();

    main_loop.run();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scale_round_trips() {
        for v in [0., 0.25, 0.6, 1.] {
            assert!((to_slider(to_linear(v)) - v).abs() < 1e-5);
        }
        assert_eq!(to_slider(4.), 1.);
    }

    #[test]
    fn reads_the_default_sink_name() {
        assert_eq!(
            default_sink_name(r#"{"name":"alsa_output.pci-0.analog"}"#),
            Some("alsa_output.pci-0.analog")
        );
        assert_eq!(default_sink_name(r#"{ "name" : "x" }"#), Some("x"));
        assert_eq!(default_sink_name("garbage"), None);
    }

    #[test]
    fn volume_pod_round_trips() {
        assert_eq!(channel_volume(&volume_pod(0.125, 2)), Some(0.125));
    }
}
