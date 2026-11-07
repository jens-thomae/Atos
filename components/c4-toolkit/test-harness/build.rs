fn main() {
    // Debug info is what makes the accessibility tree queryable from tests.
    let config = slint_build::CompilerConfiguration::new().with_debug_info(true);
    slint_build::compile_with_config("tests/ui/all.slint", config).unwrap();
    println!("cargo:rerun-if-changed=../ui/tokens.slint");
}
