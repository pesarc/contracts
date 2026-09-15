use anchor_lang::prelude::*;
use anchor_spl::token::{self, Token, TokenAccount, Transfer};

use crate::constants::*;
use crate::error::PmError;
use crate::state::Market;
use crate::utils::record_proposal;

/// Attested path. Only the pinned attestor, who posts the bond into the vault.
#[derive(Accounts)]
pub struct Propose<'info> {
    #[account(mut)]
    pub market: Account<'info, Market>,
    #[account(mut, address = market.vault)]
    pub vault: Account<'info, TokenAccount>,
    #[account(mut, token::mint = market.collateral_mint, token::authority = attestor)]
    pub attestor_token: Account<'info, TokenAccount>,
    #[account(mut)]
    pub attestor: Signer<'info>,
    pub token_program: Program<'info, Token>,
}

pub fn handler(ctx: Context<Propose>, outcome: u8) -> Result<()> {
    let m = &mut ctx.accounts.market;
    require!(m.status == ST_TRADING, PmError::NotTrading);
    require!(m.source_kind == KIND_ATTESTED, PmError::WrongSourceKind);
    require!(
        ctx.accounts.attestor.key() == m.attestor,
        PmError::NotAttestor
    );
    require!(
        Clock::get()?.unix_timestamp >= m.resolve_time,
        PmError::TooEarly
    );
    require!(
        outcome == OUT_YES || outcome == OUT_NO || outcome == OUT_INVALID,
        PmError::BadParam
    );

    token::transfer(
        CpiContext::new(
            ctx.accounts.token_program.key(),
            Transfer {
                from: ctx.accounts.attestor_token.to_account_info(),
                to: ctx.accounts.vault.to_account_info(),
                authority: ctx.accounts.attestor.to_account_info(),
            },
        ),
        m.bond,
    )?;

    m.proposer = ctx.accounts.attestor.key();
    record_proposal(m, outcome)
}
