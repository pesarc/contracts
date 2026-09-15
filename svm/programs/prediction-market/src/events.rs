use anchor_lang::prelude::*;

#[event]
pub struct Staked {
    pub market: Pubkey,
    pub user: Pubkey,
    pub is_yes: bool,
    pub amount: u64,
}

#[event]
pub struct Proposed {
    pub market: Pubkey,
    pub outcome: u8,
    pub dispute_until: i64,
}

#[event]
pub struct Disputed {
    pub market: Pubkey,
    pub disputer: Pubkey,
}

#[event]
pub struct Resolved {
    pub market: Pubkey,
    pub outcome: u8,
    pub winner_pool: u64,
    pub payout_pool: u64,
}

#[event]
pub struct Claimed {
    pub market: Pubkey,
    pub user: Pubkey,
    pub amount: u64,
}

#[event]
pub struct Refunded {
    pub market: Pubkey,
    pub user: Pubkey,
    pub amount: u64,
}
