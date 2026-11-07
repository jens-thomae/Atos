//! Design tokens → Slint globals (card #61).
//!
//! `cargo run -p tokens` rewrites `components/c4-toolkit/ui/tokens.slint` from `docs/design/tokens.json`.
//! `cargo run -p tokens -- --check` fails if the file is stale or a contrast budget (spec §7) is missed.

use serde_json::Value;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

type R<T> = Result<T, String>;

const TOKENS: &str = "docs/design/tokens.json";
const OUT: &str = "components/c4-toolkit/ui/tokens.slint";
const THEMES: [&str; 2] = ["light", "dark"];

// ---- colour -----------------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq)]
struct Rgba {
    r: f64,
    g: f64,
    b: f64,
    a: f64,
}

impl Rgba {
    /// `#rrggbb`, `rgb(r,g,b)` or `rgba(r,g,b,a)`: the forms the canvas uses.
    fn parse(s: &str) -> R<Rgba> {
        let bad = || format!("bad colour {s:?}");
        let s = s.trim();
        if let Some(h) = s.strip_prefix('#') {
            if h.len() != 6 {
                return Err(bad());
            }
            let c = |i: usize| {
                u8::from_str_radix(&h[i..i + 2], 16)
                    .map(f64::from)
                    .map_err(|_| bad())
            };
            return Ok(Rgba {
                r: c(0)?,
                g: c(2)?,
                b: c(4)?,
                a: 1.0,
            });
        }
        let inner = s
            .strip_prefix("rgba(")
            .or_else(|| s.strip_prefix("rgb("))
            .and_then(|x| x.strip_suffix(')'))
            .ok_or_else(bad)?;
        let p: Vec<f64> = inner
            .split(',')
            .map(|x| x.trim().parse().map_err(|_| bad()))
            .collect::<R<_>>()?;
        match p[..] {
            [r, g, b] => Ok(Rgba { r, g, b, a: 1.0 }),
            [r, g, b, a] => Ok(Rgba { r, g, b, a }),
            _ => Err(bad()),
        }
    }

    fn with_alpha(self, a: f64) -> Rgba {
        Rgba { a, ..self }
    }

    /// `self` drawn over opaque `bg`.
    fn over(self, bg: Rgba) -> Rgba {
        let m = |f: f64, b: f64| f * self.a + b * (1.0 - self.a);
        Rgba {
            r: m(self.r, bg.r),
            g: m(self.g, bg.g),
            b: m(self.b, bg.b),
            a: 1.0,
        }
    }

    fn mix(self, other: Rgba, t: f64) -> Rgba {
        let m = |a: f64, b: f64| a + (b - a) * t;
        Rgba {
            r: m(self.r, other.r),
            g: m(self.g, other.g),
            b: m(self.b, other.b),
            a: self.a,
        }
    }

    fn slint(self) -> String {
        let q = |x: f64| x.round().clamp(0.0, 255.0) as u8;
        if (self.a - 1.0).abs() < 1e-9 {
            format!("#{:02x}{:02x}{:02x}", q(self.r), q(self.g), q(self.b))
        } else {
            format!(
                "#{:02x}{:02x}{:02x}{:02x}",
                q(self.r),
                q(self.g),
                q(self.b),
                q(self.a * 255.0)
            )
        }
    }

    /// WCAG 2.x relative luminance of an opaque colour.
    fn luminance(self) -> f64 {
        let l = |c: f64| {
            let c = c / 255.0;
            if c <= 0.03928 {
                c / 12.92
            } else {
                ((c + 0.055) / 1.055).powf(2.4)
            }
        };
        0.2126 * l(self.r) + 0.7152 * l(self.g) + 0.0722 * l(self.b)
    }
}

fn contrast(fg: Rgba, bg: Rgba) -> f64 {
    let (a, b) = (fg.over(bg).luminance(), bg.luminance());
    (a.max(b) + 0.05) / (a.min(b) + 0.05)
}

// ---- tokens.json access -----------------------------------------------------------------------

fn at<'a>(v: &'a Value, path: &str) -> R<&'a Value> {
    path.split('.')
        .try_fold(v, |v, k| v.get(k))
        .ok_or_else(|| format!("{TOKENS}: missing {path}"))
}

fn num(v: &Value, path: &str) -> R<f64> {
    at(v, path)?
        .as_f64()
        .ok_or_else(|| format!("{TOKENS}: {path} is not a number"))
}

fn text<'a>(v: &'a Value, path: &str) -> R<&'a str> {
    at(v, path)?
        .as_str()
        .ok_or_else(|| format!("{TOKENS}: {path} is not a string"))
}

fn col(v: &Value, path: &str) -> R<Rgba> {
    Rgba::parse(text(v, path)?).map_err(|e| format!("{path}: {e}"))
}

fn keys<'a>(v: &'a Value, path: &str) -> R<Vec<&'a str>> {
    Ok(at(v, path)?
        .as_object()
        .ok_or_else(|| format!("{TOKENS}: {path} is not an object"))?
        .keys()
        .map(String::as_str)
        .collect())
}

/// A number as Slint source: `14px`, `0.5`, never `14.0px`.
fn n(x: f64) -> String {
    let s = format!("{x:.4}");
    s.trim_end_matches('0').trim_end_matches('.').to_string()
}

fn px(x: f64) -> String {
    format!("{}px", n(x))
}

// ---- generator --------------------------------------------------------------------------------

/// `dark ? <dark> : <light>`, or just the value when both themes agree.
fn themed(light: &str, dark: &str) -> String {
    if light == dark {
        light.to_string()
    } else {
        format!("Palette.dark ? {dark} : {light}")
    }
}

struct Accent {
    name: String,
    light: Rgba,
    dark: Rgba,
    hover: [Rgba; 2],
    pressed: [Rgba; 2],
}

fn accents(t: &Value) -> R<Vec<Accent>> {
    let (wm, bm) = (
        num(t, "accent.derive.hover_mix_white")?,
        num(t, "accent.derive.pressed_mix_black")?,
    );
    let (white, black) = (Rgba::parse("#FFFFFF")?, Rgba::parse("#000000")?);
    keys(t, "accent.colours")?
        .into_iter()
        .map(|name| {
            let p = |k: &str| format!("accent.colours.{name}.{k}");
            let (light, dark) = (col(t, &p("light"))?, col(t, &p("dark"))?);
            // Explicit hover/pressed win; otherwise derive (the canvas only gives them for blue in light).
            let state = |key: &str, base: Rgba, towards: Rgba, mix: f64, explicit_ok: bool| match t
                .pointer(&format!("/accent/colours/{name}/{key}"))
            {
                Some(s) if explicit_ok => Rgba::parse(s.as_str().unwrap_or("")),
                _ => Ok(base.mix(towards, mix)),
            };
            Ok(Accent {
                name: name.to_string(),
                light,
                dark,
                hover: [
                    state("hover", light, white, wm, true)?,
                    state("hover", dark, white, wm, false)?,
                ],
                pressed: [
                    state("pressed", light, black, bm, true)?,
                    state("pressed", dark, black, bm, false)?,
                ],
            })
        })
        .collect()
}

fn generate(t: &Value) -> R<String> {
    let mut o = String::new();
    let version = text(t, "version")?;
    let canvas = text(t, "canvas")?;
    let _ = write!(
        o,
        "// GENERATED by `cargo run -p tokens` from {TOKENS} (design language v{version}).\n\
         // Do not edit; change the JSON and regenerate. Canvas: {canvas}\n\n"
    );

    let accents = accents(t)?;
    let default = text(t, "accent.default")?;
    if !accents.iter().any(|a| a.name == default) {
        return Err(format!(
            "accent.default {default:?} is not in accent.colours"
        ));
    }
    let _ = writeln!(
        o,
        "export enum AccentName {{ {} }}\n",
        accents
            .iter()
            .map(|a| a.name.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    );
    o.push_str(
        "export struct TextStyle { size: length, line-height: length, weight: int, letter-spacing: length, family: string }\n\
         export struct Shadow { y: length, blur: length, color: color }\n\
         export struct Spring { response: duration, damping: float }\n\n",
    );

    // Fonts
    let _ = writeln!(
        o,
        "export global Fonts {{\n    out property <string> sans: \"{}\";\n    out property <string> mono: \"{}\";\n}}\n",
        text(t, "font.sans")?,
        text(t, "font.mono")?
    );

    // Type
    o.push_str("export global Type {\n");
    for name in keys(t, "type")? {
        let p = |k: &str| format!("type.{name}.{k}");
        let size = num(t, &p("size"))?;
        let family = match at(t, &p("family")).ok().and_then(Value::as_str) {
            Some("mono") => "Fonts.mono",
            None | Some("sans") => "Fonts.sans",
            Some(f) => return Err(format!("{}: unknown family {f:?}", p("family"))),
        };
        let _ = writeln!(
            o,
            "    out property <TextStyle> {name}: {{ size: {}, line-height: {}, weight: {}, letter-spacing: {}, family: {family} }};",
            px(size),
            px(num(t, &p("line"))?),
            num(t, &p("weight"))? as i64,
            px(num(t, &p("tracking"))? * size)
        );
    }
    o.push_str("}\n\n");

    // Palette
    o.push_str("export global Palette {\n    in property <bool> dark: false;\n");
    let _ = writeln!(
        o,
        "    in property <AccentName> accent-name: AccentName.{default};\n"
    );
    let colour_pair = |path: &str| -> R<(Rgba, Rgba)> {
        Ok((
            col(t, &format!("{path}.light"))?,
            col(t, &format!("{path}.dark"))?,
        ))
    };
    for name in keys(t, "colour")? {
        let (l, d) = colour_pair(&format!("colour.{name}"))?;
        let _ = writeln!(
            o,
            "    out property <color> {name}: {};",
            themed(&l.slint(), &d.slint())
        );
    }
    o.push('\n');
    let chain = |f: &dyn Fn(&Accent, usize) -> Rgba| {
        let mut s = String::new();
        for (i, a) in accents.iter().enumerate() {
            let v = themed(&f(a, 0).slint(), &f(a, 1).slint());
            if i + 1 == accents.len() {
                let _ = write!(s, "({v})");
            } else {
                let _ = write!(s, "accent-name == AccentName.{} ? ({v}) : ", a.name);
            }
        }
        s
    };
    let _ = writeln!(
        o,
        "    out property <color> accent: {};",
        chain(&|a, i| [a.light, a.dark][i])
    );
    let _ = writeln!(
        o,
        "    out property <color> accent-hover: {};",
        chain(&|a, i| a.hover[i])
    );
    let _ = writeln!(
        o,
        "    out property <color> accent-pressed: {};",
        chain(&|a, i| a.pressed[i])
    );
    for name in keys(t, "overlay.accent-alpha")? {
        let (l, d) = (
            num(t, &format!("overlay.accent-alpha.{name}.light"))?,
            num(t, &format!("overlay.accent-alpha.{name}.dark"))?,
        );
        let _ = writeln!(
            o,
            "    out property <color> {name}: accent.with-alpha({});",
            themed(&n(l), &n(d))
        );
    }
    let (tl, td) = (col(t, "overlay.tint.light")?, col(t, "overlay.tint.dark")?);
    for name in keys(t, "overlay.alpha")? {
        let (l, d) = (
            num(t, &format!("overlay.alpha.{name}.light"))?,
            num(t, &format!("overlay.alpha.{name}.dark"))?,
        );
        let _ = writeln!(
            o,
            "    out property <color> {name}: {};",
            themed(&tl.with_alpha(l).slint(), &td.with_alpha(d).slint())
        );
    }
    for k in ["base", "hover", "pressed", "ink"] {
        let name = if k == "base" {
            "destructive".to_string()
        } else {
            format!("destructive-{k}")
        };
        let _ = writeln!(
            o,
            "    out property <color> {name}: {};",
            col(t, &format!("accent.destructive.{k}"))?.slint()
        );
    }
    for name in keys(t, "app-tile")? {
        let _ = writeln!(
            o,
            "    out property <color> app-tile-{name}: {};",
            col(t, &format!("app-tile.{name}"))?.slint()
        );
    }
    let _ = writeln!(
        o,
        "    out property <float> disabled-opacity: {};",
        n(num(t, "motion.disabled-opacity")?)
    );
    o.push_str("}\n\n");

    // Space, radius, size
    for (global, path, prefix) in [
        ("Space", "space", "s"),
        ("Radius", "radius", ""),
        ("Size", "size", ""),
    ] {
        let _ = writeln!(o, "export global {global} {{");
        for name in keys(t, path)? {
            let _ = writeln!(
                o,
                "    out property <length> {prefix}{name}: {};",
                px(num(t, &format!("{path}.{name}"))?)
            );
        }
        if path == "size" {
            let _ = writeln!(
                o,
                "    out property <length> frosted-blur: {};",
                px(num(t, "material.frosted-blur")?)
            );
            let _ = writeln!(
                o,
                "    out property <length> focus-ring-width: {};",
                px(num(t, "focus.width")?)
            );
            let _ = writeln!(
                o,
                "    out property <length> focus-ring-offset: {};",
                px(num(t, "focus.offset")?)
            );
        }
        o.push_str("}\n\n");
    }

    // Elevation: one property per shadow layer (Slint draws one shadow per element: stack rectangles).
    o.push_str("export global Elevation {\n");
    for level in keys(t, "elevation")? {
        let layers = |theme: &str| -> R<Vec<(f64, f64, Rgba)>> {
            at(t, &format!("elevation.{level}.{theme}"))?
                .as_array()
                .ok_or("elevation layers must be an array")?
                .iter()
                .map(|l| {
                    let l = l
                        .as_array()
                        .filter(|l| l.len() == 3)
                        .ok_or("elevation layer must be [y, blur, colour]")?;
                    Ok((
                        l[0].as_f64().ok_or("y")?,
                        l[1].as_f64().ok_or("blur")?,
                        Rgba::parse(l[2].as_str().ok_or("colour")?)?,
                    ))
                })
                .collect()
        };
        let (l, d) = (layers("light")?, layers("dark")?);
        if l.len() != d.len() {
            return Err(format!(
                "elevation.{level}: light and dark need the same number of layers"
            ));
        }
        for (i, (a, b)) in l.iter().zip(&d).enumerate() {
            let sh = |s: &(f64, f64, Rgba)| {
                format!(
                    "{{ y: {}, blur: {}, color: {} }}",
                    px(s.0),
                    px(s.1),
                    s.2.slint()
                )
            };
            let name = if l.len() == 1 {
                format!("elevation-{level}")
            } else {
                format!("elevation-{level}-{}", ["near", "far"][i])
            };
            let _ = writeln!(
                o,
                "    out property <Shadow> {name}: {};",
                themed(&sh(a), &sh(b))
            );
        }
    }
    o.push_str("}\n\n");

    // Motion
    o.push_str("export global Motion {\n");
    for name in ["snappy", "standard", "gentle"] {
        let _ = writeln!(
            o,
            "    out property <Spring> {name}: {{ response: {}ms, damping: {} }};",
            n(num(t, &format!("motion.{name}.response_ms"))?),
            n(num(t, &format!("motion.{name}.damping"))?)
        );
    }
    o.push_str("}\n");
    Ok(o)
}

// ---- contrast budget (spec §7: ≥ 4.5:1 body text, ≥ 3:1 large text and graphics) --------------

/// Misses on the default accent and the neutrals fail the build. Misses on the other accents and on
/// app tiles are advisory: the canvas values are the owner's, so they are reported, not changed (#61).
struct Contrast {
    failures: Vec<String>,
    advisories: Vec<String>,
}

fn contrast_report(t: &Value) -> R<Contrast> {
    let accents = accents(t)?;
    let default = text(t, "accent.default")?;
    let mut report = Contrast {
        failures: Vec::new(),
        advisories: Vec::new(),
    };
    let mut check = |theme: &str, what: &str, fg: Rgba, bg: Rgba, min: f64, advisory: bool| {
        let r = contrast(fg, bg);
        if r < min {
            let line = format!("{theme}: {what} is {r:.2}:1, needs {min}:1");
            if advisory {
                report.advisories.push(line)
            } else {
                report.failures.push(line)
            }
        }
    };
    for (i, theme) in THEMES.iter().enumerate() {
        let c = |name: &str| col(t, &format!("colour.{name}.{theme}"));
        let (window, sidebar, card, group) = (c("window")?, c("sidebar")?, c("card")?, c("group")?);
        for text in ["text", "text-2", "text-3"] {
            for (bg_name, bg) in [
                ("window", window),
                ("sidebar", sidebar),
                ("card", card),
                ("group", group),
            ] {
                check(
                    theme,
                    &format!("{text} on {bg_name}"),
                    c(text)?,
                    bg,
                    4.5,
                    false,
                );
            }
        }
        // Frosted panel: worst case over each wallpaper stop.
        let mut panel = window;
        for wp in ["wallpaper", "wallpaper-glow", "wallpaper-edge"] {
            panel = c("panel")?.over(c(wp)?);
            for txt in ["text", "text-3"] {
                check(
                    theme,
                    &format!("{txt} on panel over {wp}"),
                    c(txt)?,
                    panel,
                    4.5,
                    false,
                );
            }
        }
        for s in ["success", "warning", "error"] {
            for (bg_name, bg) in [
                ("window", window),
                ("sidebar", sidebar),
                ("card", card),
                ("group", group),
            ] {
                // The canvas only claims status colours on the window.
                check(
                    theme,
                    &format!("{s} on {bg_name}"),
                    c(s)?,
                    bg,
                    4.5,
                    bg_name != "window",
                );
            }
        }
        check(
            theme,
            "warning on privacy-bg over panel",
            c("warning")?,
            c("privacy-bg")?.over(panel),
            4.5,
            true,
        );
        let alpha = |name: &str| num(t, &format!("overlay.accent-alpha.{name}.{theme}"));
        for a in &accents {
            let acc = [a.light, a.dark][i];
            let name = &a.name;
            let adv = a.name != default;
            let selected = acc.with_alpha(alpha("select")?).over(window);
            check(
                theme,
                &format!("accent {name} on window"),
                acc,
                window,
                4.5,
                adv,
            );
            for (bg_name, bg) in [("sidebar", sidebar), ("card", card)] {
                check(
                    theme,
                    &format!("accent {name} on {bg_name}"),
                    acc,
                    bg,
                    4.5,
                    adv,
                );
            }
            check(
                theme,
                &format!("on-accent on accent {name} hover"),
                c("on-accent")?,
                a.hover[i],
                4.5,
                adv,
            );
            check(
                theme,
                &format!("accent {name} on group"),
                acc,
                group,
                4.5,
                adv,
            );
            check(
                theme,
                &format!("accent {name} on selected row"),
                acc,
                selected,
                4.5,
                adv,
            );
            check(
                theme,
                &format!("on-accent on accent {name}"),
                c("on-accent")?,
                acc,
                4.5,
                adv,
            );
            check(
                theme,
                &format!("on-accent on accent {name} pressed"),
                c("on-accent")?,
                a.pressed[i],
                4.5,
                adv,
            );
        }
    }
    let ink = col(t, "accent.destructive.ink")?;
    for k in ["base", "hover", "pressed"] {
        check(
            "both",
            &format!("destructive ink on {k}"),
            ink,
            col(t, &format!("accent.destructive.{k}"))?,
            4.5,
            false,
        );
    }
    let glyph = col(t, "app-tile.glyph")?;
    for name in keys(t, "app-tile")?.into_iter().filter(|k| *k != "glyph") {
        check(
            "both",
            &format!("app-tile glyph on {name}"),
            glyph,
            col(t, &format!("app-tile.{name}"))?,
            3.0,
            true,
        );
    }
    Ok(report)
}

// ---- literal check: UI code takes design values from the generated globals only ---------------

/// `.slint` files that may hold literals: the generated file, and test fixtures (not UI code).
const LITERAL_EXEMPT: [&str; 2] = [OUT, "components/c4-toolkit/test-harness/"];

/// Lines of `src` with a literal colour, length or duration. Comments and strings are ignored;
/// zero is allowed (`0px`).
fn literal_violations(src: &str) -> Vec<String> {
    let c: Vec<char> = src.chars().collect();
    let (mut i, mut line, mut bad) = (0, 1, Vec::new());
    let ident = |ch: char| ch.is_alphanumeric() || ch == '_' || ch == '-';
    while i < c.len() {
        match c[i] {
            '\n' => line += 1,
            '/' if c.get(i + 1) == Some(&'/') => {
                while i < c.len() && c[i] != '\n' {
                    i += 1;
                }
                continue;
            }
            '/' if c.get(i + 1) == Some(&'*') => {
                i += 2;
                while i + 1 < c.len() && !(c[i] == '*' && c[i + 1] == '/') {
                    line += (c[i] == '\n') as usize;
                    i += 1;
                }
                i += 2;
                continue;
            }
            '"' => {
                i += 1;
                while i < c.len() && c[i] != '"' {
                    if c[i] == '\\' {
                        i += 1;
                    }
                    line += (c.get(i) == Some(&'\n')) as usize;
                    i += 1;
                }
            }
            '#' if c.get(i + 1).is_some_and(char::is_ascii_hexdigit) => {
                let e = (i + 1..c.len())
                    .find(|&k| !c[k].is_alphanumeric())
                    .unwrap_or(c.len());
                bad.push(format!(
                    "line {line}: colour literal {}",
                    c[i..e].iter().collect::<String>()
                ));
                i = e;
                continue;
            }
            ch if ch.is_ascii_digit() && (i == 0 || !(ident(c[i - 1]) || c[i - 1] == '.')) => {
                let e = (i..c.len())
                    .find(|&k| !(c[k].is_ascii_digit() || c[k] == '.'))
                    .unwrap_or(c.len());
                let u = (e..c.len())
                    .find(|&k| !c[k].is_alphabetic())
                    .unwrap_or(c.len());
                let (num, unit): (String, String) =
                    (c[i..e].iter().collect(), c[e..u].iter().collect());
                if ["px", "phx", "pt", "rem", "ms", "s"].contains(&unit.as_str())
                    && num.parse::<f64>().is_ok_and(|v| v != 0.0)
                {
                    bad.push(format!("line {line}: literal {num}{unit}"));
                }
                i = u;
                continue;
            }
            ch if ch.is_alphabetic() => {
                let e = (i..c.len()).find(|&k| !ident(c[k])).unwrap_or(c.len());
                let word: String = c[i..e].iter().collect();
                if ["rgb", "rgba", "hsv", "hsl"].contains(&word.as_str()) && c.get(e) == Some(&'(')
                {
                    bad.push(format!("line {line}: colour function {word}("));
                }
                i = e;
                continue;
            }
            _ => {}
        }
        i += 1;
    }
    bad
}

fn slint_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() {
            if p.file_name()
                .is_some_and(|n| n != "target" && n != "node_modules")
            {
                slint_files(&p, out);
            }
        } else if p.extension().is_some_and(|x| x == "slint") {
            out.push(p);
        }
    }
}

/// Literal violations in every non-exempt `.slint` file under `components/`.
fn literal_report(root: &Path) -> Vec<String> {
    let mut files = Vec::new();
    slint_files(&root.join("components"), &mut files);
    let mut bad = Vec::new();
    for f in files {
        let rel = f
            .strip_prefix(root)
            .unwrap_or(&f)
            .to_string_lossy()
            .replace('\\', "/");
        if LITERAL_EXEMPT.iter().any(|x| rel.starts_with(x)) {
            continue;
        }
        let src = std::fs::read_to_string(&f).unwrap_or_default();
        bad.extend(
            literal_violations(&src)
                .into_iter()
                .map(|v| format!("{rel}: {v}")),
        );
    }
    bad
}

/// Every `proposed` entry must name a real token, so the list cannot rot.
fn proposed_missing(t: &Value) -> Vec<String> {
    let list = t
        .get("proposed")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    list.iter()
        .filter_map(Value::as_str)
        .filter(|p| at(t, p).is_err())
        .map(str::to_string)
        .collect()
}

fn repo_root() -> PathBuf {
    // tools/tokens -> repo root
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repo root")
}

fn load() -> R<(Value, PathBuf)> {
    let root = repo_root();
    let raw = std::fs::read_to_string(root.join(TOKENS)).map_err(|e| format!("{TOKENS}: {e}"))?;
    Ok((
        serde_json::from_str(&raw).map_err(|e| format!("{TOKENS}: {e}"))?,
        root,
    ))
}

fn main() -> std::process::ExitCode {
    let check = std::env::args().any(|a| a == "--check");
    let run = || -> R<()> {
        let (t, root) = load()?;
        let missing = proposed_missing(&t);
        if !missing.is_empty() {
            return Err(format!(
                "`proposed` names tokens that do not exist: {}",
                missing.join(", ")
            ));
        }
        let report = contrast_report(&t)?;
        for a in &report.advisories {
            eprintln!("tokens: warning: {a}");
        }
        let out = generate(&t)?;
        let path = root.join(OUT);
        if check {
            if std::fs::read_to_string(&path).ok().as_deref() != Some(&out) {
                return Err(format!(
                    "{OUT} is stale: run `cargo run -p tokens` and commit the result"
                ));
            }
        } else {
            std::fs::write(&path, &out).map_err(|e| format!("{OUT}: {e}"))?;
            println!("wrote {OUT}");
        }
        let mut fails = report.failures;
        fails.extend(
            literal_report(&root)
                .into_iter()
                .map(|v| format!("literal design value (use tokens): {v}")),
        );
        if fails.is_empty() {
            Ok(())
        } else {
            Err(format!(
                "contrast budget (spec §7) missed:\n  {}",
                fails.join("\n  ")
            ))
        }
    };
    match run() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("tokens: {e}");
            std::process::ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn contrast_known_values() {
        let (w, b) = (
            Rgba::parse("#FFFFFF").unwrap(),
            Rgba::parse("#000000").unwrap(),
        );
        assert!((contrast(b, w) - 21.0).abs() < 1e-9);
        // The canvas states white on the blue accent is 6.5:1.
        assert!((contrast(w, Rgba::parse("#3A5BA8").unwrap()) - 6.5).abs() < 0.1);
    }

    #[test]
    fn parses_canvas_forms() {
        assert_eq!(
            Rgba::parse("rgba(70,55,40,0.07)").unwrap().slint(),
            "#46372812"
        );
        assert_eq!(Rgba::parse("rgb(1,2,3)").unwrap().slint(), "#010203");
        assert!(Rgba::parse("#12345").is_err());
    }

    #[test]
    fn committed_tokens_are_valid_and_output_is_current() {
        let (t, root) = load().unwrap();
        assert_eq!(proposed_missing(&t), Vec::<String>::new());
        let committed = std::fs::read_to_string(root.join(OUT))
            .expect("generated file missing: run `cargo run -p tokens`");
        assert_eq!(
            committed,
            generate(&t).unwrap(),
            "{OUT} is stale: run `cargo run -p tokens`"
        );
    }

    #[test]
    fn literal_check_flags_bad_and_passes_clean() {
        let bad = "Rectangle { background: #1f1c19; width: 32px; animate x { duration: 200ms; } border-color: rgba(1,2,3,0.5); }";
        assert_eq!(literal_violations(bad).len(), 4);
        let clean = "// 32px #fff in a comment\n/* 5ms */\nRectangle { background: Palette.window; width: Size.control; x: 0px; opacity: 0.4; text: \"12px #abc\"; }";
        assert_eq!(literal_violations(clean), Vec::<String>::new());
    }

    #[test]
    fn no_literals_in_ui_code() {
        assert_eq!(literal_report(&repo_root()), Vec::<String>::new());
    }

    #[test]
    fn committed_tokens_meet_contrast_budget() {
        let (t, _) = load().unwrap();
        assert_eq!(contrast_report(&t).unwrap().failures, Vec::<String>::new());
    }
}
