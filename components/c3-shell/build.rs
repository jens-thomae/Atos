// SPDX-License-Identifier: MIT OR Apache-2.0
fn main() {
    // Debug info makes the accessibility tree queryable from the tests (atos-ui-test).
    let config = slint_build::CompilerConfiguration::new().with_debug_info(true);
    slint_build::compile_with_config("ui/dock.slint", config).unwrap();
    println!("cargo:rerun-if-changed=../c4-toolkit/ui/tokens.slint");
}
