use anchor_lang::prelude::*;

#[event]
pub struct RateRecorded {
    pub token_in: Pubkey,
    pub token_out: Pubkey,
    pub rate_1e18: u128,
    pub timestamp: i64,
}

#[event]
pub struct RecorderSet {
    pub recorder: Pubkey,
    pub allowed: bool,
}

/// Emitted by `consult` so off-chain clients get the TWAP without parsing
/// return data (the value is also returned via `set_return_data`).
#[event]
pub struct Consulted {
    pub token_in: Pubkey,
    pub token_out: Pubkey,
    pub window: u32,
    pub twap_1e18: u128,
}
