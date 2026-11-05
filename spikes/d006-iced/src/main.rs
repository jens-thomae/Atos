//! D-006 Files prototype in libcosmic. Implements exactly
//! `docs/decisions/D-006-prototype-brief.md` §3; see README.md.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Instant, SystemTime};

use cosmic::app::{Core, Settings, Task};
use cosmic::iced::keyboard::{Key, Modifiers, key::Named};
use cosmic::iced::widget::{
    list,
    scrollable::{AbsoluteOffset, Viewport},
};
use cosmic::iced::{Event, Length, Point, Size, Subscription, event, keyboard, window};
use cosmic::widget::{self, Id, button, popover};
use cosmic::{Application, ApplicationExt, Element, theme};

// Fixed row height, so "scroll into view" and Page Up/Down can be computed
// without asking the list widget for its layout.
const ROW_H: f32 = 32.0;
const PLACES: [&str; 3] = ["Home", "File system", "Start folder"];
const MENU: [&str; 3] = ["Open", "Copy Path", "Properties"];
const AUTOSCROLL_SPEED: f32 = 2000.0;
const AUTOSCROLL_MAX_SECS: f32 = 10.0;

fn main() -> cosmic::iced::Result {
    let start = std::env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(home);
    let start = std::path::absolute(&start).unwrap_or(start);
    let settings = Settings::default().size(Size::new(1280.0, 800.0));
    cosmic::app::run::<App>(settings, start)
}

fn home() -> PathBuf {
    std::env::var_os("HOME").map_or_else(|| PathBuf::from("/"), PathBuf::from)
}

fn say(line: &str) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{line}");
    let _ = out.flush();
}

struct Entry {
    name: String,
    path: PathBuf,
    is_dir: bool,
    bytes: u64,
    size: String,
    modified: String,
}

fn read_folder(dir: &Path) -> Result<Vec<Entry>, String> {
    let mut entries: Vec<Entry> = std::fs::read_dir(dir)
        .map_err(|e| e.to_string())?
        .filter_map(Result::ok)
        .map(|e| {
            let path = e.path();
            let meta = std::fs::symlink_metadata(&path).ok();
            let is_dir = meta.as_ref().is_some_and(|m| m.is_dir());
            let bytes = meta.as_ref().map_or(0, |m| m.len());
            let modified = meta
                .and_then(|m| m.modified().ok())
                .map(format_time)
                .unwrap_or_default();
            Entry {
                name: e.file_name().to_string_lossy().into_owned(),
                path,
                is_dir,
                bytes,
                size: if is_dir {
                    "Folder".into()
                } else {
                    format_size(bytes)
                },
                modified,
            }
        })
        .collect();
    entries.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then_with(|| a.name.cmp(&b.name)));
    Ok(entries)
}

fn format_size(bytes: u64) -> String {
    if bytes < 1000 {
        return format!("{bytes} B");
    }
    let mut v = bytes as f64 / 1000.0;
    for unit in ["kB", "MB", "GB", "TB"] {
        if v < 1000.0 || unit == "TB" {
            return format!("{v:.1} {unit}");
        }
        v /= 1000.0;
    }
    unreachable!()
}

fn format_time(t: SystemTime) -> String {
    jiff::Timestamp::try_from(t)
        .map(|ts| {
            ts.to_zoned(jiff::tz::TimeZone::system())
                .strftime("%Y-%m-%d %H:%M")
                .to_string()
        })
        .unwrap_or_default()
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Focus {
    Place(usize),
    Up,
    List,
}

struct Menu {
    row: usize,
    at: Option<Point>,
    focus: usize,
}

struct App {
    core: Core,
    start: PathBuf,
    cwd: PathBuf,
    entries: Result<list::Content<Entry>, String>,
    selected: Option<usize>,
    focus: Focus,
    menu: Option<Menu>,
    properties: Option<usize>,
    pointer: Point,
    scroll_y: f32,
    page_h: f32,
    first_frame: bool,
    autoscroll: Option<(Instant, Instant)>,
}

#[derive(Clone, Debug)]
enum Message {
    Place(usize),
    Up,
    Select(usize),
    Open(usize),
    ContextMenu(usize),
    MenuAction(usize),
    CloseMenu,
    CloseProperties,
    Pointer(Point),
    Scrolled(Viewport),
    Key(Key, Modifiers, event::Status),
    Frame(Instant),
}

fn list_id() -> Id {
    Id::new("list")
}
fn up_id() -> Id {
    Id::new("up")
}
fn place_id(i: usize) -> Id {
    Id::new(PLACES[i])
}
fn menu_id(i: usize) -> Id {
    Id::new(MENU[i])
}

impl App {
    fn len(&self) -> usize {
        self.entries.as_ref().map_or(0, |c| c.len())
    }

    fn entry(&self, i: usize) -> Option<&Entry> {
        self.entries.as_ref().ok()?.get(i)
    }

    fn navigate(&mut self, dir: PathBuf) -> Task<Message> {
        self.entries = read_folder(&dir).map(list::Content::with_items);
        self.cwd = dir;
        self.selected = None;
        self.scroll_y = 0.0;
        cosmic::iced::widget::scrollable::scroll_to(
            list_id(),
            AbsoluteOffset {
                x: None,
                y: Some(0.0),
            },
        )
    }

    fn open(&mut self, i: usize) -> Task<Message> {
        let Some(e) = self.entry(i) else {
            return Task::none();
        };
        if e.is_dir {
            let path = e.path.clone();
            self.navigate(path)
        } else {
            say(&format!("SPIKE_OPEN {}", e.path.display()));
            Task::none()
        }
    }

    fn up(&mut self) -> Task<Message> {
        match self.cwd.parent() {
            Some(p) => self.navigate(p.to_path_buf()),
            None => Task::none(),
        }
    }

    fn select(&mut self, i: usize) -> Task<Message> {
        self.selected = Some(i);
        // Scroll the selected row into view.
        let top = i as f32 * ROW_H;
        let y = if top < self.scroll_y {
            top
        } else if top + ROW_H > self.scroll_y + self.page_h {
            top + ROW_H - self.page_h
        } else {
            return Task::none();
        };
        self.scroll_y = y;
        cosmic::iced::widget::scrollable::scroll_to(
            list_id(),
            AbsoluteOffset {
                x: None,
                y: Some(y),
            },
        )
    }

    fn set_focus(&mut self, focus: Focus) -> Task<Message> {
        self.focus = focus;
        // ponytail: the list is not a focusable widget in libcosmic; focusing its
        // scrollable id only clears focus from the buttons (see README).
        widget::button::focus(match focus {
            Focus::Place(i) => place_id(i),
            Focus::Up => up_id(),
            Focus::List => list_id(),
        })
    }

    fn page(&self) -> usize {
        ((self.page_h / ROW_H) as usize).max(1)
    }

    fn key(&mut self, key: Key, mods: Modifiers, status: event::Status) -> Task<Message> {
        // A focused button already handled it (Enter); its message runs first.
        let named = match key {
            Key::Named(n) if status == event::Status::Ignored => n,
            _ => return Task::none(),
        };
        if self.properties.is_some() {
            if named == Named::Escape {
                return self.update(Message::CloseProperties);
            }
            return Task::none();
        }
        if let Some(menu) = &mut self.menu {
            return match named {
                Named::Escape => self.update(Message::CloseMenu),
                Named::ArrowDown | Named::ArrowUp => {
                    let n = MENU.len();
                    menu.focus = if named == Named::ArrowDown {
                        (menu.focus + 1) % n
                    } else {
                        (menu.focus + n - 1) % n
                    };
                    widget::button::focus(menu_id(menu.focus))
                }
                Named::Enter => {
                    let a = menu.focus;
                    self.update(Message::MenuAction(a))
                }
                _ => Task::none(),
            };
        }
        match named {
            Named::Tab => {
                let order = [Focus::Place(0), Focus::Up, Focus::List];
                let at = order
                    .iter()
                    .position(|f| std::mem::discriminant(f) == std::mem::discriminant(&self.focus))
                    .unwrap_or(2);
                let next = (at + if mods.shift() { 2 } else { 1 }) % 3;
                return self.set_focus(order[next]);
            }
            Named::Backspace => return self.up(),
            Named::ArrowUp if mods.alt() => return self.up(),
            _ => {}
        }
        match self.focus {
            Focus::Place(i) => match named {
                Named::ArrowDown if i + 1 < PLACES.len() => self.set_focus(Focus::Place(i + 1)),
                Named::ArrowUp if i > 0 => self.set_focus(Focus::Place(i - 1)),
                Named::Enter => self.update(Message::Place(i)),
                _ => Task::none(),
            },
            Focus::Up => Task::none(),
            Focus::List => {
                let len = self.len();
                if len == 0 {
                    return Task::none();
                }
                let last = len - 1;
                let target = match (named, self.selected) {
                    (Named::ArrowDown, None) | (Named::Home, _) => 0,
                    (Named::End, _) => last,
                    (Named::ArrowDown, Some(s)) => (s + 1).min(last),
                    (Named::ArrowUp, Some(s)) => s.saturating_sub(1),
                    (Named::PageDown, s) => s.map_or(0, |s| (s + self.page()).min(last)),
                    (Named::PageUp, s) => s.map_or(0, |s| s.saturating_sub(self.page())),
                    (Named::Enter, Some(s)) => return self.open(s),
                    (Named::ContextMenu, Some(s)) => return self.open_menu(s, None),
                    (Named::F10, Some(s)) if mods.shift() => return self.open_menu(s, None),
                    _ => return Task::none(),
                };
                self.select(target)
            }
        }
    }

    fn open_menu(&mut self, row: usize, at: Option<Point>) -> Task<Message> {
        self.menu = Some(Menu { row, at, focus: 0 });
        widget::button::focus(menu_id(0))
    }

    fn row_view<'a>(&self, i: usize, e: &'a Entry) -> Element<'a, Message> {
        let row = widget::row::with_children(vec![
            widget::text(e.name.as_str())
                .width(Length::FillPortion(3))
                .into(),
            widget::text(e.size.as_str())
                .width(Length::FillPortion(1))
                .into(),
            widget::text(e.modified.as_str())
                .width(Length::FillPortion(1))
                .into(),
        ]);
        // The button is only the toolkit's row look (selected state); clicks go
        // to the mouse area, so the button never takes Enter.
        let look = widget::button::custom(row)
            .name(e.name.as_str())
            .class(theme::Button::ListItem([0.0; 4]))
            .selected(self.selected == Some(i))
            .force_enabled(true)
            .width(Length::Fill)
            .height(ROW_H);
        widget::mouse_area(look)
            .on_press(Message::Select(i))
            .on_double_click(Message::Open(i))
            .on_right_press(Message::ContextMenu(i))
            .into()
    }
}

impl cosmic::Application for App {
    type Executor = cosmic::executor::Default;
    type Flags = PathBuf;
    type Message = Message;
    const APP_ID: &'static str = "org.atos.D006Files";

    fn core(&self) -> &Core {
        &self.core
    }

    fn core_mut(&mut self) -> &mut Core {
        &mut self.core
    }

    fn init(mut core: Core, start: PathBuf) -> (Self, Task<Message>) {
        // Tab order is the brief's (sidebar, Up, list), not the widget tree's.
        core.set_keyboard_nav(false);
        core.set_header_title("Files".into());
        let autoscroll = std::env::var("D006_AUTOSCROLL").is_ok_and(|v| v == "1");
        let mut app = App {
            core,
            entries: read_folder(&start).map(list::Content::with_items),
            cwd: start.clone(),
            start,
            selected: None,
            focus: Focus::List,
            menu: None,
            properties: None,
            pointer: Point::ORIGIN,
            scroll_y: 0.0,
            // Until the first scroll reports the real viewport: window minus header and path bar.
            page_h: 800.0 - 150.0,
            first_frame: false,
            autoscroll: None,
        };
        let now = Instant::now();
        if autoscroll {
            app.autoscroll = Some((now, now));
        }
        let title = match app.core.main_window_id() {
            Some(id) => app.set_window_title("Files".into(), id),
            None => Task::none(),
        };
        (app, title)
    }

    fn subscription(&self) -> Subscription<Message> {
        let keys = event::listen_with(|event, status, _| match event {
            Event::Keyboard(keyboard::Event::KeyPressed { key, modifiers, .. }) => {
                Some(Message::Key(key, modifiers, status))
            }
            _ => None,
        });
        // Frame ticks only while needed, so the idle app does no work.
        if !self.first_frame || self.autoscroll.is_some() {
            Subscription::batch([keys, window::frames().map(|(_, t)| Message::Frame(t))])
        } else {
            keys
        }
    }

    fn update(&mut self, message: Message) -> Task<Message> {
        match message {
            Message::Place(i) => {
                self.focus = Focus::Place(i);
                let dir = match i {
                    0 => home(),
                    1 => PathBuf::from("/"),
                    _ => self.start.clone(),
                };
                self.navigate(dir)
            }
            Message::Up => {
                self.focus = Focus::Up;
                self.up()
            }
            Message::Select(i) => {
                self.focus = Focus::List;
                self.selected = Some(i);
                Task::none()
            }
            Message::Open(i) => self.open(i),
            Message::ContextMenu(i) => {
                self.focus = Focus::List;
                self.selected = Some(i);
                let at = self.pointer;
                self.open_menu(i, Some(at))
            }
            Message::MenuAction(a) => {
                let Some(menu) = self.menu.take() else {
                    return Task::none();
                };
                let focus_list = self.set_focus(Focus::List);
                match a {
                    0 => Task::batch([focus_list, self.open(menu.row)]),
                    1 => match self.entry(menu.row) {
                        Some(e) => Task::batch([
                            focus_list,
                            cosmic::iced::clipboard::write(e.path.display().to_string()),
                        ]),
                        None => focus_list,
                    },
                    _ => {
                        self.properties = Some(menu.row);
                        focus_list
                    }
                }
            }
            Message::CloseMenu => {
                self.menu = None;
                self.set_focus(Focus::List)
            }
            Message::CloseProperties => {
                self.properties = None;
                self.set_focus(Focus::List)
            }
            Message::Pointer(p) => {
                self.pointer = p;
                Task::none()
            }
            Message::Scrolled(v) => {
                self.scroll_y = v.absolute_offset().y;
                self.page_h = v.bounds().height;
                Task::none()
            }
            Message::Key(key, mods, status) => self.key(key, mods, status),
            Message::Frame(now) => {
                if !self.first_frame {
                    // frames() fires on RedrawRequested; iced_winit delivers the
                    // message after that frame was drawn and presented.
                    self.first_frame = true;
                    say("BUDGET_FIRST_FRAME");
                }
                let Some((start, last)) = self.autoscroll else {
                    return Task::none();
                };
                let dt = now.saturating_duration_since(last).as_secs_f32();
                self.autoscroll = Some((start, now));
                let max = (self.len() as f32 * ROW_H - self.page_h).max(0.0);
                self.scroll_y = (self.scroll_y + AUTOSCROLL_SPEED * dt).min(max);
                if self.scroll_y >= max
                    || now.saturating_duration_since(start).as_secs_f32() >= AUTOSCROLL_MAX_SECS
                {
                    say("D006_AUTOSCROLL_DONE");
                    std::process::exit(0);
                }
                cosmic::iced::widget::scrollable::scroll_to(
                    list_id(),
                    AbsoluteOffset {
                        x: None,
                        y: Some(self.scroll_y),
                    },
                )
            }
        }
    }

    fn dialog(&self) -> Option<Element<'_, Message>> {
        let e = self.entry(self.properties?)?;
        let size = if e.is_dir {
            "Folder".to_string()
        } else {
            format!("{} bytes", e.bytes)
        };
        Some(
            widget::dialog()
                .title("Properties")
                .control(widget::column::with_children(vec![
                    widget::text(format!("Name: {}", e.name)).into(),
                    widget::text(format!("Path: {}", e.path.display())).into(),
                    widget::text(format!("Size: {size}")).into(),
                    widget::text(format!("Modified: {}", e.modified)).into(),
                ]))
                .primary_action(button::standard("Close").on_press(Message::CloseProperties))
                .into(),
        )
    }

    fn view(&self) -> Element<'_, Message> {
        let places = widget::column::with_children(
            PLACES
                .iter()
                .enumerate()
                .map(|(i, name)| {
                    button::text(*name)
                        .id(place_id(i))
                        .on_press(Message::Place(i))
                        .width(Length::Fill)
                        .into()
                })
                .collect::<Vec<_>>(),
        )
        .width(200);

        let path = widget::text(self.cwd.display().to_string()).width(Length::Fill);
        let up = button::standard("Up")
            .id(up_id())
            .on_press_maybe(self.cwd.parent().map(|_| Message::Up));
        let bar = widget::row::with_children(vec![up.into(), path.into()]).spacing(8);

        let header = widget::row::with_children(vec![
            widget::text("Name").width(Length::FillPortion(3)).into(),
            widget::text("Size").width(Length::FillPortion(1)).into(),
            widget::text("Modified")
                .width(Length::FillPortion(1))
                .into(),
        ]);

        let body: Element<'_, Message> = match &self.entries {
            Ok(content) => widget::scrollable(list(content, |i, e| self.row_view(i, e)))
                .id(list_id())
                .on_scroll(Message::Scrolled)
                .height(Length::Fill)
                .into(),
            Err(e) => widget::text(e.as_str()).into(),
        };

        let main = widget::column::with_children(vec![bar.into(), header.into(), body]).spacing(8);
        let content = widget::row::with_children(vec![places.into(), main.into()]).spacing(8);
        let content = widget::mouse_area(content).on_move(Message::Pointer);

        let mut pop = popover(content).on_close(Message::CloseMenu);
        if let Some(menu) = &self.menu {
            let items = widget::column::with_children(
                MENU.iter()
                    .enumerate()
                    .map(|(i, name)| {
                        button::text(*name)
                            .id(menu_id(i))
                            .class(theme::Button::MenuItem)
                            .on_press(Message::MenuAction(i))
                            .width(Length::Fill)
                            .into()
                    })
                    .collect::<Vec<_>>(),
            )
            .width(200);
            pop = pop
                .popup(widget::container(items).class(theme::Container::Dropdown))
                .position(
                    menu.at
                        .map_or(popover::Position::Center, popover::Position::Point),
                );
        }
        pop.into()
    }
}

#[cfg(test)]
mod tests {
    use super::format_size;

    #[test]
    fn sizes() {
        assert_eq!(format_size(0), "0 B");
        assert_eq!(format_size(120), "120 B");
        assert_eq!(format_size(345_678), "345.7 kB");
        assert_eq!(format_size(1_048_576), "1.0 MB");
    }
}
