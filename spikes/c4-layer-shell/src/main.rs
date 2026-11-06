//! Spike #59: Slint on wlr-layer-shell with an AccessKit tree. Not production code (see
//! docs/components/c4-toolkit/layer-shell-spike.md).

mod accesskit;
mod measure;
mod platform;

slint::include_modules!();

fn main() -> Result<(), Box<dyn std::error::Error>> {
    slint::platform::set_platform(Box::new(platform::WaylandPlatform::new()?))
        .map_err(|e| format!("{e:?}"))?;
    let panel = Panel::new()?;
    panel.run()?;
    Ok(())
}
