// SPDX-License-Identifier: MIT OR Apache-2.0
//! The window switcher's order and selection (#226), without any display: most recently used
//! order, one group per app, and which window the selection stands on.

/// One window as the switcher needs it.
#[derive(Clone, Debug, PartialEq)]
pub struct Win {
    pub id: u32,
    pub title: String,
    pub app_id: String,
}

/// The windows' activation history, newest first.
#[derive(Default)]
pub struct Mru(Vec<u32>);

impl Mru {
    /// `id` was activated: it is now the most recent.
    pub fn activated(&mut self, id: u32) {
        self.0.retain(|&x| x != id);
        self.0.insert(0, id);
    }

    /// `wins` (in opening order) most recently used first; windows never seen activated follow
    /// in opening order. Also forgets windows that are gone.
    pub fn order(&mut self, wins: &[Win]) -> Vec<Win> {
        self.0.retain(|id| wins.iter().any(|w| w.id == *id));
        let mut out: Vec<Win> = self
            .0
            .iter()
            .filter_map(|id| wins.iter().find(|w| w.id == *id).cloned())
            .collect();
        out.extend(wins.iter().filter(|w| !self.0.contains(&w.id)).cloned());
        out
    }
}

/// One tile: the windows of one app, most recent first.
#[derive(Clone, Debug, PartialEq)]
pub struct Group {
    pub app_id: String,
    pub windows: Vec<Win>,
}

/// Groups `ordered` (most recent first) by app, in the order of each app's most recent window.
/// A window without an app ID is its own group.
pub fn group(ordered: &[Win]) -> Vec<Group> {
    let mut groups: Vec<Group> = Vec::new();
    for w in ordered {
        match groups
            .iter_mut()
            .find(|g| !w.app_id.is_empty() && g.app_id == w.app_id)
        {
            Some(g) => g.windows.push(w.clone()),
            None => groups.push(Group {
                app_id: w.app_id.clone(),
                windows: vec![w.clone()],
            }),
        }
    }
    groups
}

/// The open switcher: its tiles and the selection (a tile, and a window within it).
#[derive(Debug, Default)]
pub struct Switcher {
    pub groups: Vec<Group>,
    pub tile: usize,
    pub win: usize,
    /// Windows asked to close during this opening: hidden until the compositor's list drops them,
    /// but never removed from the shell's own list, so an app that refuses to close comes back
    /// at the next opening.
    hidden: Vec<u32>,
}

impl Switcher {
    /// Opens on the next window after the current one (the first tile is the current window's app).
    pub fn open(ordered: &[Win]) -> Self {
        let groups = group(ordered);
        Self {
            tile: usize::from(groups.len() > 1),
            groups,
            win: 0,
            hidden: Vec::new(),
        }
    }

    pub fn step(&mut self, forward: bool) {
        let n = self.groups.len();
        if n > 0 {
            self.tile = if forward {
                (self.tile + 1) % n
            } else {
                (self.tile + n - 1) % n
            };
            self.win = 0;
        }
    }

    /// The next window of the selected app (backtick).
    pub fn same_app(&mut self) {
        if let Some(g) = self.groups.get(self.tile) {
            self.win = (self.win + 1) % g.windows.len();
        }
    }

    /// Hides `id` from the tiles for this opening.
    pub fn hide(&mut self, id: u32) {
        self.hidden.push(id);
    }

    pub fn selected(&self) -> Option<&Win> {
        self.groups.get(self.tile)?.windows.get(self.win)
    }

    /// The windows changed (one closed, one opened) while open: new tiles, same selected window
    /// if it still exists, else the nearest tile.
    pub fn update(&mut self, ordered: &[Win]) {
        let id = self.selected().map(|w| w.id);
        let was = self.tile;
        let shown: Vec<Win> = ordered
            .iter()
            .filter(|w| !self.hidden.contains(&w.id))
            .cloned()
            .collect();
        self.groups = group(&shown);
        let found = id.and_then(|id| {
            self.groups
                .iter()
                .enumerate()
                .find_map(|(t, g)| g.windows.iter().position(|w| w.id == id).map(|w| (t, w)))
        });
        (self.tile, self.win) = found.unwrap_or((was.min(self.groups.len().saturating_sub(1)), 0));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(id: u32, app: &str) -> Win {
        Win {
            id,
            title: format!("w{id}"),
            app_id: app.into(),
        }
    }

    fn ids(ws: &[Win]) -> Vec<u32> {
        ws.iter().map(|w| w.id).collect()
    }

    #[test]
    fn most_recently_used_first_then_opening_order() {
        let wins = [w(1, "a"), w(2, "b"), w(3, "c")];
        let mut m = Mru::default();
        assert_eq!(ids(&m.order(&wins)), [1, 2, 3]);
        m.activated(3);
        m.activated(2);
        m.activated(3);
        assert_eq!(ids(&m.order(&wins)), [3, 2, 1]);
        // A closed window drops out of the history.
        assert_eq!(ids(&m.order(&wins[1..])), [3, 2]);
        assert_eq!(ids(&m.order(&wins)), [3, 2, 1]);
    }

    #[test]
    fn windows_of_one_app_share_a_tile_at_their_newest_position() {
        let g = group(&[
            w(1, "files"),
            w(2, "web"),
            w(3, "files"),
            w(4, ""),
            w(5, ""),
        ]);
        let shape: Vec<_> = g.iter().map(|g| ids(&g.windows)).collect();
        assert_eq!(shape, [vec![1, 3], vec![2], vec![4], vec![5]]);
    }

    #[test]
    fn opens_on_the_previous_app_and_wraps() {
        let mut s = Switcher::open(&[w(1, "a"), w(2, "b"), w(3, "c")]);
        assert_eq!(s.selected().unwrap().id, 2);
        s.step(true);
        s.step(true);
        assert_eq!(s.selected().unwrap().id, 1);
        s.step(false);
        assert_eq!(s.selected().unwrap().id, 3);
        assert_eq!(Switcher::open(&[w(1, "a")]).selected().unwrap().id, 1);
        assert!(Switcher::open(&[]).selected().is_none());
    }

    #[test]
    fn backtick_cycles_the_windows_of_the_selected_app_only() {
        let mut s = Switcher::open(&[w(1, "a"), w(2, "b"), w(3, "a"), w(4, "b")]);
        assert_eq!(s.selected().unwrap().id, 2);
        s.same_app();
        assert_eq!(s.selected().unwrap().id, 4);
        s.same_app();
        assert_eq!(s.selected().unwrap().id, 2);
    }

    #[test]
    fn a_window_asked_to_close_is_hidden_only_for_this_opening() {
        let wins = [w(1, "a"), w(2, "b"), w(3, "c")];
        let mut s = Switcher::open(&wins);
        s.hide(2);
        s.update(&wins); // the app refused: the list is unchanged
        let tiles: Vec<u32> = s.groups.iter().flat_map(|g| ids(&g.windows)).collect();
        assert_eq!(tiles, [1, 3]);
        assert_eq!(s.selected().unwrap().id, 3);
        // The next opening starts from the full list again.
        assert_eq!(Switcher::open(&wins).groups.len(), 3);
    }

    #[test]
    fn keeps_the_selected_window_when_the_list_changes() {
        let mut s = Switcher::open(&[w(1, "a"), w(2, "b"), w(3, "c")]);
        s.update(&[w(1, "a"), w(2, "b"), w(3, "c"), w(9, "z")]);
        assert_eq!(s.selected().unwrap().id, 2);
        s.update(&[w(1, "a"), w(3, "c")]); // the selected window closed
        assert_eq!(s.selected().unwrap().id, 3);
        s.update(&[]);
        assert!(s.selected().is_none());
    }
}
