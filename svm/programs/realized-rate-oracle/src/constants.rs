//! Program constants.

/// Ring-buffer depth of realized-rate observations kept per directional pair.
pub const CARDINALITY: usize = 32;

/// Fixed-point scale for rates: `rate_1e18` is "1e18 of tokenOut per 1 tokenIn".
pub const RATE_SCALE: u128 = 1_000_000_000_000_000_000; // 1e18
