use anchor_lang::prelude::*;
use anchor_spl::token::{self, Token, TokenAccount, Transfer};

use crate::constants::*;
use crate::error::PmError;
use crate::events::Disputed;
use crate::state::Market;

/// Challenge a proposed outcome inside the window by matching the bond.
#[derive(Accounts)]
pub struct Dispute<'info> {
    #[account(mut)]
    pub market: Account<'info, Market>,
    #[account(mut, address = market.vault)]
    pub vault: Account<'info, TokenAccount>,
    #[account(mut, token::mint = market.collateral_mint, token::authority = disputer)]
    pub disputer_token: Account<'info, TokenAccount>,
    #[account(mut)]
    pub disputer: Signer<'info>,
    pub token_program: Program<'info, Token>,
}

pub fn handler(ctx: Context<Dispute>) -> Result<()> {
    let m = &mut ctx.accounts.market;
    require!(m.status == ST_PROPOSED, PmError::BadStatus);
    require!(m.bond > 0, PmError::DisputesDisabled);
    require!(
        Clock::get()?.unix_timestamp < m.dispute_until,
        PmError::WindowClosed
    );

    token::transfer(
        CpiContext::new(
            ctx.accounts.token_program.key(),
            Transfer {
                from: ctx.accounts.disputer_token.to_account_info(),
                to: ctx.accounts.vault.to_account_info(),
                authority: ctx.accounts.disputer.to_account_info(),
            },
        ),
        m.bond,
    )?;

    m.disputer = ctx.accounts.disputer.key();
    m.status = ST_DISPUTED;
    emit!(Disputed {
        market: m.key(),
        disputer: ctx.accounts.disputer.key()
    });
    Ok(())
}
