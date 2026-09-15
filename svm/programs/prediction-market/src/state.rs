use anchor_lang::prelude::*;

#[account]
#[derive(InitSpace)]
pub struct Config {
    pub authority: Pubkey,
    pub treasury: Pubkey,
    pub protocol_fee_bps: u16,
    pub market_count: u64,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct Market {
    pub id: u64,
    pub collateral_mint: Pubkey,
    pub close_time: i64,
    pub resolve_time: i64,
    pub dispute_window: i64,
    pub dispute_until: i64,
    pub attestor: Pubkey,
    pub pool_yes: u64,
    pub pool_no: u64,
    pub winner_pool: u64,
    pub payout_pool: u64,
    pub bond: u64,
    pub proposer: Pubkey,
    pub disputer: Pubkey,
    pub proposed: u8,
    pub outcome: u8,
    pub status: u8,
    pub source_kind: u8,
    pub comparator: u8,
    pub threshold: u128,
    pub token_in: Pubkey,
    pub token_out: Pubkey,
    pub twap_window: u32,
    pub feed_ref: [u8; 32],
    /// Fee (bps) pinned when the market was created.
    pub fee_bps_cache: u16,
    #[max_len(160)]
    pub question: String,
    pub vault: Pubkey,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct Position {
    pub stake_yes: u64,
    pub stake_no: u64,
    pub claimed: bool,
    pub bump: u8,
}
