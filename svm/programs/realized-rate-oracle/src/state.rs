use anchor_lang::prelude::*;

use crate::constants::CARDINALITY;

#[account]
#[derive(InitSpace)]
pub struct Config {
    pub authority: Pubkey,
    pub bump: u8,
}

/// Marker PDA — existence at [b"recorder", recorder] means the recorder is
/// allowed. Created/closed by the authority via `set_recorder`.
#[account]
#[derive(InitSpace)]
pub struct Recorder {
    pub recorder: Pubkey,
    pub allowed: bool,
    pub bump: u8,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Default, InitSpace)]
pub struct Observation {
    pub timestamp: i64,
    /// Cumulative Σ(rate × seconds) up to `timestamp`.
    pub cumulative: u128,
}

/// Per directional pair (token_in -> token_out). Directional on purpose: the TWAP
/// of an inverse is not the inverse of a TWAP, so both directions are recorded.
#[account]
#[derive(InitSpace)]
pub struct PairState {
    pub token_in: Pubkey,
    pub token_out: Pubkey,
    pub last_update: i64,
    pub last_rate_1e18: u128,
    pub cumulative: u128,
    pub index: u8,
    pub cardinality: u8,
    pub observations: [Observation; CARDINALITY],
    pub bump: u8,
}
