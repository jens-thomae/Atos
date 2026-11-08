//! Headless screenshot and accessibility-tree tests for Slint components (card #60).
//! How-to: docs/components/c4-toolkit/screenshot-tests.md

use std::path::{Path, PathBuf};

pub use i_slint_backend_testing::AccessibleRole;
use i_slint_backend_testing::{
    ElementHandle, ElementQuery, ElementRoot, TestingBackend, TestingBackendOptions,
};
use slint::ComponentHandle;

/// Largest allowed difference per colour channel (0-255) before a pixel counts as different.
/// Absorbs rounding noise between machines.
pub const CHANNEL_TOLERANCE: u8 = 2;
/// Share of all pixels that may differ by more than [`CHANNEL_TOLERANCE`].
pub const MAX_DIFFERING_PIXELS: f64 = 0.001;

/// Starts the headless backend for the current thread: software renderer, mocked time.
/// Call first in every test, before creating a component.
/// Text is only reproducible across machines if the `.slint` file under test does
/// `import "<path>/fonts/NotoSans-Regular.ttf";` (bundled in `fonts/`) and sets
/// `default-font-family: "Noto Sans";`.
pub fn init() {
    slint::platform::set_platform(Box::new(TestingBackend::new(TestingBackendOptions {
        mock_time: true,
        threading: false,
        renderer_name: Some("software".into()),
    })))
    .expect("atos_ui_test::init() must be the first Slint call in the test");
}

/// Renders `component` and compares it with `<manifest_dir>/tests/screenshots/<name>.png`.
/// `UPDATE_SCREENSHOTS=1` writes the reference instead. On a mismatch it writes
/// `<name>.actual.png` and `<name>.diff.png` (differing pixels in red) to
/// `$SCREENSHOT_DIFF_DIR` (default `target/screenshot-diffs`) and panics.
#[track_caller]
pub fn assert_screenshot(component: &impl ComponentHandle, manifest_dir: &str, name: &str) {
    component.show().expect("show");
    let snap = component.window().take_snapshot().expect("take_snapshot");
    let actual = image::RgbaImage::from_raw(snap.width(), snap.height(), snap.as_bytes().to_vec())
        .expect("buffer size");

    let reference = Path::new(manifest_dir)
        .join("tests/screenshots")
        .join(format!("{name}.png"));
    if std::env::var_os("UPDATE_SCREENSHOTS").is_some() {
        std::fs::create_dir_all(reference.parent().unwrap()).unwrap();
        actual.save(&reference).unwrap();
        return;
    }
    let expected = image::open(&reference)
        .unwrap_or_else(|e| {
            panic!(
                "{}: {e}; create it with UPDATE_SCREENSHOTS=1",
                reference.display()
            )
        })
        .to_rgba8();

    let (problem, diff) = compare(&expected, &actual);
    let Some(problem) = problem else { return };
    let dir = PathBuf::from(
        std::env::var_os("SCREENSHOT_DIFF_DIR").unwrap_or_else(|| "target/screenshot-diffs".into()),
    );
    std::fs::create_dir_all(&dir).unwrap();
    actual.save(dir.join(format!("{name}.actual.png"))).unwrap();
    diff.save(dir.join(format!("{name}.diff.png"))).unwrap();
    panic!(
        "screenshot `{name}` differs from {}: {problem}; see {}",
        reference.display(),
        dir.display()
    );
}

/// `None` if within tolerance, else a description. Also returns the diff image.
fn compare(
    expected: &image::RgbaImage,
    actual: &image::RgbaImage,
) -> (Option<String>, image::RgbaImage) {
    if expected.dimensions() != actual.dimensions() {
        let msg = format!(
            "size {:?} instead of {:?}",
            actual.dimensions(),
            expected.dimensions()
        );
        return (Some(msg), actual.clone());
    }
    let mut diff = actual.clone();
    let mut count = 0usize;
    for (x, y, e) in expected.enumerate_pixels() {
        let a = actual.get_pixel(x, y);
        if e.0
            .iter()
            .zip(a.0)
            .any(|(e, a)| e.abs_diff(a) > CHANNEL_TOLERANCE)
        {
            count += 1;
            diff.put_pixel(x, y, image::Rgba([255, 0, 0, 255]));
        }
    }
    let total = (expected.width() * expected.height()) as f64;
    if count as f64 / total > MAX_DIFFERING_PIXELS {
        (
            Some(format!(
                "{count} of {total} pixels differ by more than {CHANNEL_TOLERANCE}"
            )),
            diff,
        )
    } else {
        (None, diff)
    }
}

/// All elements that expose an accessible role, in document order, as (role, label).
pub fn accessibility_tree(root: &impl ComponentHandle) -> Vec<(AccessibleRole, String)> {
    // The element tree only exists once the window is shown.
    root.show().expect("show");
    ElementQuery::from_root(root)
        .match_predicate(|_| true)
        .find_all()
        .iter()
        .filter_map(|e| {
            let role = e.accessible_role()?;
            (role != AccessibleRole::None)
                .then(|| (role, e.accessible_label().unwrap_or_default().to_string()))
        })
        .collect()
}

/// Asserts that an element with this role and accessible label exists.
#[track_caller]
pub fn assert_accessible(root: &impl ComponentHandle, role: AccessibleRole, label: &str) {
    let tree = accessibility_tree(root);
    assert!(
        tree.iter().any(|(r, l)| *r == role && l == label),
        "no {role:?} named {label:?}; accessibility tree: {tree:?}"
    );
}

/// The element with this accessible label, to click or read further.
pub fn find_by_label(root: &impl ComponentHandle, label: &str) -> Option<ElementHandle> {
    root.show().expect("show");
    ElementHandle::find_by_accessible_label(root, label).next()
}

/// All elements with this accessible role, in document order.
pub fn elements_with_role(root: &impl ComponentHandle, role: AccessibleRole) -> Vec<ElementHandle> {
    root.show().expect("show");
    ElementQuery::from_root(root)
        .match_predicate(move |e| e.accessible_role() == Some(role))
        .find_all()
}

/// Accessible role and label of the root element (the window itself), which the queries skip.
pub fn root_accessibility(root: &impl ComponentHandle) -> (Option<AccessibleRole>, String) {
    root.show().expect("show");
    let e = root.root_element();
    (
        e.accessible_role(),
        e.accessible_label().unwrap_or_default().to_string(),
    )
}
