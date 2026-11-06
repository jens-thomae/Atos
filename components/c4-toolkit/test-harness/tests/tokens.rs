// The generated tokens (components/c4-toolkit/ui/tokens.slint) compile and switch with theme and accent.
slint::include_modules!();

use atos_ui_test::init;
use slint::Color;

#[test]
fn tokens_follow_theme_and_accent() {
    init();
    let ui = TokensProbe::new().unwrap();
    let rgb = |c: Color| (c.red(), c.green(), c.blue());
    assert_eq!(rgb(ui.get_window_colour()), (0xF6, 0xF3, 0xEE));
    assert_eq!(rgb(ui.get_accent_colour()), (0x3A, 0x5B, 0xA8));
    ui.set_dark(true);
    assert_eq!(rgb(ui.get_window_colour()), (0x1F, 0x1C, 0x19));
    assert_eq!(rgb(ui.get_accent_colour()), (0x8F, 0xA3, 0xE0));
    ui.set_accent_name(AccentName::Teal);
    assert_eq!(rgb(ui.get_accent_colour()), (0x2F, 0x7C, 0x82));
    assert_eq!(ui.get_select_colour().alpha(), (0.16f32 * 255.0).round() as u8);
    assert_eq!(ui.get_body_size(), 14.0);
    assert_eq!(ui.get_space_4(), 16.0);
    assert_eq!(ui.get_window_radius(), 14.0);
    assert_eq!(ui.get_control_height(), 32.0);
    assert_eq!(ui.get_shadow_blur(), 60.0);
    assert_eq!(ui.get_snappy_response(), 180);
}
