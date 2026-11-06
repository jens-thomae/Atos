//! Round-trip spike: parse sample, change one value, write back, and check the
//! diff is exactly one line. Run: `cargo run`.
use std::fs;

fn changed_lines(a: &str, b: &str) -> Vec<(String, String)> {
    let (a, b): (Vec<_>, Vec<_>) = (a.lines().collect(), b.lines().collect());
    assert_eq!(a.len(), b.len(), "line count changed");
    a.iter().zip(&b).filter(|(x, y)| x != y).map(|(x, y)| (x.to_string(), y.to_string())).collect()
}

fn report(name: &str, before: &str, after: &str) {
    let d = changed_lines(before, after);
    for (x, y) in &d {
        println!("{name}: -{x}\n{name}: +{y}");
    }
    assert_eq!(d.len(), 1, "{name}: diff touches {} lines", d.len());
    println!("{name}: OK, exactly one line changed\n");
}

fn toml_case() {
    let src = fs::read_to_string("sample.toml").unwrap();
    let mut doc: toml_edit::DocumentMut = src.parse().unwrap();
    // Change the window mode of the first workspace; keep the value's decor (the comment).
    let item = &mut doc["workspace"][0]["window_mode"];
    let decor = item.as_value().unwrap().decor().clone();
    let mut v = toml_edit::Value::from("floating");
    *v.decor_mut() = decor;
    *item = toml_edit::Item::Value(v);
    report("toml_edit", &src, &doc.to_string());
}

fn kdl_case() {
    let src = fs::read_to_string("sample.kdl").unwrap();
    let mut doc: kdl::KdlDocument = src.parse().unwrap();
    let node = doc.get_mut("workspace").unwrap().children_mut().as_mut().unwrap().get_mut("window-mode").unwrap();
    // Replace the value in place; the entry keeps its leading/trailing whitespace.
    // set_value alone leaves the old text in the entry's format, so the output would not change.
    // Dropping the format and autoformatting the one entry re-renders just that value.
    let e = &mut node.entries_mut()[0];
    e.set_value("floating");
    e.autoformat();
    report("kdl", &src, &doc.to_string());
}

fn main() {
    toml_case();
    kdl_case();
}
