// SPDX-License-Identifier: MIT OR Apache-2.0
fn main() {
    // Debug info makes the accessibility tree queryable from the tests (atos-ui-test).
    let config = slint_build::CompilerConfiguration::new().with_debug_info(true);
    slint_build::compile_with_config("ui/shell.slint", config.clone()).unwrap();
    // The bundled test font for the control centre screenshot (tests/control_centre.rs only).
    let out = std::path::PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
    slint_build::compile_with_output_path(
        "tests/ui/control_centre_font.slint",
        out.join("cc_test_font.rs"),
        config,
    )
    .unwrap();
    println!("cargo:rerun-if-changed=../c4-toolkit/ui/tokens.slint");
}
