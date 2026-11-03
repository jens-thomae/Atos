//! Exercises the toolchain until the workspace has real crates.
//! Delete it once another crate with tests exists.

/// Returns the number of components in spec §6.
pub fn component_count() -> usize {
    11
}

#[cfg(test)]
mod tests {
    #[test]
    fn counts_components() {
        assert_eq!(super::component_count(), 12);
    }
}
