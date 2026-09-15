use anchor_lang::prelude::*;
use anchor_spl::token::{self, Token, TokenAccount, Transfer};

use crate::constants::*;
use crate::error::PmError;
use crate::events::Staked;
use crate::state::{Market, Position};

#[derive(Accounts)]
pub struct Stake<'info> {
    #[account(mut)]
    pub market: Account<'info, Market>,
    #[account(
        init_if_needed,
        payer = user,
        space = 8 + Position::INIT_SPACE,
        seeds = [b"position", market.key().as_ref(), user.key().as_ref()],
        bump
    )]
    pub position: Account<'info, Position>,
    #[account(mut, address = market.vault)]
    pub vault: Account<'info, TokenAccount>,
    #[account(mut, token::mint = market.collateral_mint, token::authority = user)]
    pub user_token: Account<'info, TokenAccount>,
    #[account(mut)]
    pub user: Signer<'info>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

pub fn handler(ctx: Context<Stake>, is_yes: bool, amount: u64) -> Result<()> {
    let m = &mut ctx.accounts.market;
    require!(m.status == ST_TRADING, PmError::NotTrading);
    require!(
        Clock::get()?.unix_timestamp < m.close_time,
        PmError::TradingClosed
    );
    require!(amount > 0, PmError::BadParam);

    token::transfer(
        CpiContext::new(
            ctx.accounts.token_program.key(),
            Transfer {
                from: ctx.accounts.user_token.to_account_info(),
                to: ctx.accounts.vault.to_account_info(),
                authority: ctx.accounts.user.to_account_info(),
            },
        ),
        amount,
    )?;

    let pos = &mut ctx.accounts.position;
    if is_yes {
        m.pool_yes = m.pool_yes.checked_add(amount).unwrap();
        pos.stake_yes = pos.stake_yes.checked_add(amount).unwrap();
    } else {
        m.pool_no = m.pool_no.checked_add(amount).unwrap();
        pos.stake_no = pos.stake_no.checked_add(amount).unwrap();
    }
    pos.bump = ctx.bumps.position;

    emit!(Staked {
        market: m.key(),
        user: ctx.accounts.user.key(),
        is_yes,
        amount
    });
    Ok(())
}
