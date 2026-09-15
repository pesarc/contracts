use anchor_lang::prelude::*;

use crate::error::OracleError;
use crate::events::RateRecorded;
use crate::state::{PairState, Recorder};
use crate::utils::record_rate;

/// Record a realized settlement rate: `rate_1e18` of `token_out` per `token_in`.
/// Recorder-gated; seeds the directional series on first print.
#[derive(Accounts)]
#[instruction(token_in: Pubkey, token_out: Pubkey)]
pub struct Record<'info> {
    #[account(
        init_if_needed,
        payer = signer,
        space = 8 + PairState::INIT_SPACE,
        seeds = [b"pair", token_in.as_ref(), token_out.as_ref()],
        bump
    )]
    pub pair: Box<Account<'info, PairState>>,
    #[account(
        seeds = [b"recorder", signer.key().as_ref()],
        bump = recorder.bump,
        constraint = recorder.allowed @ OracleError::NotRecorder
    )]
    pub recorder: Account<'info, Recorder>,
    #[account(mut)]
    pub signer: Signer<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(
    ctx: Context<Record>,
    token_in: Pubkey,
    token_out: Pubkey,
    rate_1e18: u128,
) -> Result<()> {
    require!(rate_1e18 != 0, OracleError::BadRate);
    let now = Clock::get()?.unix_timestamp;

    let pair = &mut ctx.accounts.pair;
    if pair.token_in == Pubkey::default() {
        pair.token_in = token_in;
        pair.token_out = token_out;
        pair.bump = ctx.bumps.pair;
    }
    record_rate(pair, now, rate_1e18);

    emit!(RateRecorded {
        token_in,
        token_out,
        rate_1e18,
        timestamp: now
    });
    Ok(())
}
