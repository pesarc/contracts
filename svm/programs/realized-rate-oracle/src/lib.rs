//! StableArc Realized-Rate Oracle — Solana (SVM).
//!
//! Self-referential price discovery: records the rate of every settlement that
//! actually clears on StableArc's own rail and exposes a time-weighted average
//! per directional pair. The price comes from our own realized local-to-local
//! flow, not a USD-referenced feed — no external provider can deny it, no
//! jurisdiction can compel it, and moving it costs real capital.
//!
//! This is the SVM sibling of the EVM `RealizedRateOracle`. It is the spine the
//! native Solana settlement stack and the `prediction-market` program resolve
//! against: `consult` returns the TWAP via Anchor return data, so a consumer
//! program can CPI in and read it.
//!
//! Module layout: `constants` · `error` · `events` · `state` · `utils` ·
//! `instructions/*`.

use anchor_lang::prelude::*;

pub mod constants;
pub mod error;
pub mod events;
pub mod instructions;
pub mod state;
pub mod utils;

use instructions::*;

declare_id!("4NUdEu7crxzR1AtHhaiMLk4q1ctTvhZLREq7Pbt9KNkK");

#[program]
pub mod realized_rate_oracle {
    use super::*;

    pub fn initialize(ctx: Context<Initialize>) -> Result<()> {
        instructions::initialize::handler(ctx)
    }

    pub fn set_recorder(ctx: Context<SetRecorder>, recorder: Pubkey, allowed: bool) -> Result<()> {
        instructions::set_recorder::handler(ctx, recorder, allowed)
    }

    pub fn record(
        ctx: Context<Record>,
        token_in: Pubkey,
        token_out: Pubkey,
        rate_1e18: u128,
    ) -> Result<()> {
        instructions::record::handler(ctx, token_in, token_out, rate_1e18)
    }

    /// TWAP over the trailing `window` seconds (returns rate_1e18 via return data).
    pub fn consult(
        ctx: Context<Consult>,
        token_in: Pubkey,
        token_out: Pubkey,
        window: u32,
    ) -> Result<u128> {
        instructions::consult::consult(ctx, token_in, token_out, window)
    }

    /// Most recent realized spot rate for a directional pair.
    pub fn latest_rate(ctx: Context<Consult>, token_in: Pubkey, token_out: Pubkey) -> Result<u128> {
        instructions::consult::latest_rate(ctx, token_in, token_out)
    }
}
