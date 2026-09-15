use anchor_lang::prelude::*;

use crate::error::OracleError;
use crate::events::Consulted;
use crate::state::PairState;
use crate::utils::twap;

/// Read a directional pair. Returns values via Anchor return data, so a consumer
/// program (e.g. the PredictionMarket) can CPI in and read the result.
#[derive(Accounts)]
#[instruction(token_in: Pubkey, token_out: Pubkey)]
pub struct Consult<'info> {
    #[account(seeds = [b"pair", token_in.as_ref(), token_out.as_ref()], bump = pair.bump)]
    pub pair: Box<Account<'info, PairState>>,
}

/// Time-weighted average realized rate over the trailing `window` seconds.
pub fn consult(
    ctx: Context<Consult>,
    token_in: Pubkey,
    token_out: Pubkey,
    window: u32,
) -> Result<u128> {
    let pair = &ctx.accounts.pair;
    require!(pair.last_update != 0, OracleError::NoData);
    let now = Clock::get()?.unix_timestamp;
    let v = twap(pair, now, window);
    emit!(Consulted {
        token_in,
        token_out,
        window,
        twap_1e18: v
    });
    Ok(v)
}

/// Most recent realized rate (spot print) for a directional pair.
pub fn latest_rate(ctx: Context<Consult>, _token_in: Pubkey, _token_out: Pubkey) -> Result<u128> {
    let pair = &ctx.accounts.pair;
    require!(pair.last_update != 0, OracleError::NoData);
    Ok(pair.last_rate_1e18)
}
