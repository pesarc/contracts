use anchor_lang::prelude::*;
use anchor_spl::token::{Token, TokenAccount};

use crate::constants::*;
use crate::error::PmError;
use crate::events::{Claimed, Refunded};
use crate::state::{Market, Position};
use crate::utils::pay;

#[derive(Accounts)]
pub struct Claim<'info> {
    pub market: Account<'info, Market>,
    #[account(
        mut,
        seeds = [b"position", market.key().as_ref(), user.key().as_ref()],
        bump = position.bump
    )]
    pub position: Account<'info, Position>,
    #[account(mut, address = market.vault)]
    pub vault: Account<'info, TokenAccount>,
    #[account(mut, token::mint = market.collateral_mint, token::authority = user)]
    pub user_token: Account<'info, TokenAccount>,
    pub user: Signer<'info>,
    pub token_program: Program<'info, Token>,
}

fn market_seeds(m: &Market) -> ([u8; 8], [u8; 1]) {
    (m.id.to_le_bytes(), [m.bump])
}

/// Winners withdraw their pro-rata share of the pot.
pub fn claim(ctx: Context<Claim>) -> Result<()> {
    let m = &ctx.accounts.market;
    require!(m.status == ST_FINALIZED, PmError::BadStatus);
    require!(
        m.outcome == OUT_YES || m.outcome == OUT_NO,
        PmError::NotInvalid
    );
    let pos = &mut ctx.accounts.position;
    require!(!pos.claimed, PmError::AlreadyClaimed);

    let s = if m.outcome == OUT_YES {
        pos.stake_yes
    } else {
        pos.stake_no
    };
    require!(s > 0, PmError::NothingToClaim);

    pos.claimed = true;
    let amount = (s as u128)
        .checked_mul(m.payout_pool as u128)
        .unwrap()
        .checked_div(m.winner_pool as u128)
        .unwrap() as u64;

    let (id_bytes, bump) = market_seeds(m);
    let seeds: &[&[u8]] = &[b"market", id_bytes.as_ref(), &bump];
    let market_ai = ctx.accounts.market.to_account_info();
    pay(
        &ctx.accounts.token_program,
        &ctx.accounts.vault,
        &ctx.accounts.user_token,
        &market_ai,
        seeds,
        amount,
    )?;
    emit!(Claimed {
        market: ctx.accounts.market.key(),
        user: ctx.accounts.user.key(),
        amount
    });
    Ok(())
}

/// Reclaim principal on a voided (Invalid) market.
pub fn refund(ctx: Context<Claim>) -> Result<()> {
    let m = &ctx.accounts.market;
    require!(m.status == ST_FINALIZED, PmError::BadStatus);
    require!(m.outcome == OUT_INVALID, PmError::NotInvalid);
    let pos = &mut ctx.accounts.position;
    require!(!pos.claimed, PmError::AlreadyClaimed);

    let s = pos.stake_yes.checked_add(pos.stake_no).unwrap();
    require!(s > 0, PmError::NothingToClaim);

    pos.claimed = true;
    let (id_bytes, bump) = market_seeds(m);
    let seeds: &[&[u8]] = &[b"market", id_bytes.as_ref(), &bump];
    let market_ai = ctx.accounts.market.to_account_info();
    pay(
        &ctx.accounts.token_program,
        &ctx.accounts.vault,
        &ctx.accounts.user_token,
        &market_ai,
        seeds,
        s,
    )?;
    emit!(Refunded {
        market: ctx.accounts.market.key(),
        user: ctx.accounts.user.key(),
        amount: s
    });
    Ok(())
}
