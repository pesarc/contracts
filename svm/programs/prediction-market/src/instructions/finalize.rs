use anchor_lang::prelude::*;
use anchor_spl::token::{Token, TokenAccount};

use crate::constants::*;
use crate::error::PmError;
use crate::state::Market;
use crate::utils::{pay, settle_outcome};

/// Lock a proposed outcome once its window passes with no challenge; return the
/// proposer's bond (they were right).
// Boxed to keep the generated `try_accounts` stack frame under the 4KB limit.
#[derive(Accounts)]
pub struct Finalize<'info> {
    #[account(mut)]
    pub market: Box<Account<'info, Market>>,
    #[account(mut, address = market.vault)]
    pub vault: Box<Account<'info, TokenAccount>>,
    #[account(mut, token::mint = market.collateral_mint)]
    pub treasury_token: Box<Account<'info, TokenAccount>>,
    #[account(mut, token::mint = market.collateral_mint)]
    pub proposer_token: Box<Account<'info, TokenAccount>>,
    pub token_program: Program<'info, Token>,
}

pub fn handler(ctx: Context<Finalize>) -> Result<()> {
    let m = &mut ctx.accounts.market;
    require!(m.status == ST_PROPOSED, PmError::BadStatus);
    require!(
        Clock::get()?.unix_timestamp >= m.dispute_until,
        PmError::WindowOpen
    );

    let proposed = m.proposed;
    let proposer = m.proposer;
    let bond = m.bond;
    let fee = settle_outcome(m, proposed);

    let market_ai = ctx.accounts.market.to_account_info();
    let id_bytes = ctx.accounts.market.id.to_le_bytes();
    let bump = [ctx.accounts.market.bump];
    let seeds: &[&[u8]] = &[b"market", id_bytes.as_ref(), &bump];

    if fee > 0 {
        pay(
            &ctx.accounts.token_program,
            &ctx.accounts.vault,
            &ctx.accounts.treasury_token,
            &market_ai,
            seeds,
            fee,
        )?;
    }
    if proposer != Pubkey::default() && bond > 0 {
        pay(
            &ctx.accounts.token_program,
            &ctx.accounts.vault,
            &ctx.accounts.proposer_token,
            &market_ai,
            seeds,
            bond,
        )?;
    }
    Ok(())
}
