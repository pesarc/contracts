use anchor_lang::prelude::*;
use anchor_spl::token::{Token, TokenAccount};

use crate::constants::*;
use crate::error::PmError;
use crate::state::{Config, Market};
use crate::utils::{pay, settle_outcome};

/// Arbiter ruling on a disputed market. Settles the outcome and the bonds:
/// whoever was right takes both, the wrong side forfeits.
// Accounts are boxed to keep the generated `try_accounts` stack frame under the
// 4KB BPF limit (six deserialized accounts otherwise overflow it).
#[derive(Accounts)]
pub struct ResolveDispute<'info> {
    #[account(seeds = [b"config"], bump = config.bump, has_one = authority)]
    pub config: Box<Account<'info, Config>>,
    #[account(mut)]
    pub market: Box<Account<'info, Market>>,
    #[account(mut, address = market.vault)]
    pub vault: Box<Account<'info, TokenAccount>>,
    #[account(mut, token::mint = market.collateral_mint)]
    pub treasury_token: Box<Account<'info, TokenAccount>>,
    #[account(mut, token::mint = market.collateral_mint)]
    pub proposer_token: Box<Account<'info, TokenAccount>>,
    #[account(mut, token::mint = market.collateral_mint)]
    pub disputer_token: Box<Account<'info, TokenAccount>>,
    pub authority: Signer<'info>,
    pub token_program: Program<'info, Token>,
}

pub fn handler(ctx: Context<ResolveDispute>, final_outcome: u8) -> Result<()> {
    let m = &mut ctx.accounts.market;
    require!(m.status == ST_DISPUTED, PmError::BadStatus);
    require!(
        final_outcome == OUT_YES || final_outcome == OUT_NO || final_outcome == OUT_INVALID,
        PmError::BadParam
    );

    let proposer = m.proposer;
    let bond = m.bond;
    let proposer_right = final_outcome == m.proposed;
    let fee = settle_outcome(m, final_outcome);

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

    if proposer != Pubkey::default() {
        // Attested: 2 * bond in escrow -> winner of the dispute.
        let dest = if proposer_right {
            &ctx.accounts.proposer_token
        } else {
            &ctx.accounts.disputer_token
        };
        pay(
            &ctx.accounts.token_program,
            &ctx.accounts.vault,
            dest,
            &market_ai,
            seeds,
            bond.checked_mul(2).unwrap(),
        )?;
    } else if proposer_right {
        // Oracle upheld -> disputer forfeits to the treasury.
        pay(
            &ctx.accounts.token_program,
            &ctx.accounts.vault,
            &ctx.accounts.treasury_token,
            &market_ai,
            seeds,
            bond,
        )?;
    } else {
        // Oracle overturned -> disputer refunded.
        pay(
            &ctx.accounts.token_program,
            &ctx.accounts.vault,
            &ctx.accounts.disputer_token,
            &market_ai,
            seeds,
            bond,
        )?;
    }
    Ok(())
}
