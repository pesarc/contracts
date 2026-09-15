//! Pesarc Prediction & Hedge Market — Solana (SVM).
//!
//! The SVM sibling of the EVM `PredictionMarket`: binary, **parimutuel**
//! markets settled in a local-currency SPL stablecoin (cNGN / cKES, never
//! USDC) so the stake, the payout, and the thing being hedged are the same
//! money — no dollar in the path.
//!
//! Resolution mirrors the EVM contract:
//!   - **Oracle** — FX/macro questions resolve trustlessly by CPI into the
//!     RealizedRateOracle: `propose_from_oracle` reads the realized-rate TWAP
//!     from the oracle's return data and compares it to the pinned threshold.
//!     Permissionless once `resolve_time` passes. No bond.
//!   - **Attested** — real-world macro data is proposed by a bonded attestor and
//!     held for a dispute window before it finalizes; the authority arbitrates.
//!
//! Non-custodial: funds live in a market-PDA-owned SPL vault; only the program
//! moves them, along the settle / claim / refund paths.
//!
//! Module layout: `constants` · `error` · `events` · `state` · `utils` ·
//! `instructions/*` (one context + handler per instruction).

use anchor_lang::prelude::*;

pub mod constants;
pub mod error;
pub mod events;
pub mod instructions;
pub mod state;
pub mod utils;

use instructions::*;

declare_id!("2aMC2CKjqwxmLrS6dv98c6pVYEKogRXxEuz3NZpzv8CZ");

#[program]
pub mod prediction_market {
    use super::*;

    pub fn initialize(
        ctx: Context<Initialize>,
        treasury: Pubkey,
        protocol_fee_bps: u16,
    ) -> Result<()> {
        instructions::initialize::handler(ctx, treasury, protocol_fee_bps)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn create_market(
        ctx: Context<CreateMarket>,
        question: String,
        close_time: i64,
        resolve_time: i64,
        dispute_window: i64,
        attestor: Pubkey,
        bond: u64,
        source_kind: u8,
        comparator: u8,
        threshold: u128,
        token_in: Pubkey,
        token_out: Pubkey,
        twap_window: u32,
        feed_ref: [u8; 32],
    ) -> Result<()> {
        instructions::create_market::handler(
            ctx,
            question,
            close_time,
            resolve_time,
            dispute_window,
            attestor,
            bond,
            source_kind,
            comparator,
            threshold,
            token_in,
            token_out,
            twap_window,
            feed_ref,
        )
    }

    pub fn stake(ctx: Context<Stake>, is_yes: bool, amount: u64) -> Result<()> {
        instructions::stake::handler(ctx, is_yes, amount)
    }

    pub fn propose_from_oracle(ctx: Context<ProposeOracle>) -> Result<()> {
        instructions::propose_oracle::handler(ctx)
    }

    pub fn propose(ctx: Context<Propose>, outcome: u8) -> Result<()> {
        instructions::propose::handler(ctx, outcome)
    }

    pub fn dispute(ctx: Context<Dispute>) -> Result<()> {
        instructions::dispute::handler(ctx)
    }

    pub fn finalize(ctx: Context<Finalize>) -> Result<()> {
        instructions::finalize::handler(ctx)
    }

    pub fn resolve_dispute(ctx: Context<ResolveDispute>, final_outcome: u8) -> Result<()> {
        instructions::resolve_dispute::handler(ctx, final_outcome)
    }

    pub fn claim(ctx: Context<Claim>) -> Result<()> {
        instructions::claim::claim(ctx)
    }

    pub fn refund(ctx: Context<Claim>) -> Result<()> {
        instructions::claim::refund(ctx)
    }
}
