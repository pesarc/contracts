use anchor_lang::prelude::*;
use anchor_spl::token::{Mint, Token, TokenAccount};

use crate::constants::*;
use crate::error::PmError;
use crate::state::{Config, Market};

#[derive(Accounts)]
pub struct CreateMarket<'info> {
    #[account(mut, seeds = [b"config"], bump = config.bump, has_one = authority)]
    pub config: Account<'info, Config>,
    #[account(
        init,
        payer = authority,
        space = 8 + Market::INIT_SPACE,
        seeds = [b"market", config.market_count.to_le_bytes().as_ref()],
        bump
    )]
    pub market: Account<'info, Market>,
    pub collateral_mint: Account<'info, Mint>,
    #[account(
        init,
        payer = authority,
        seeds = [b"vault", market.key().as_ref()],
        bump,
        token::mint = collateral_mint,
        token::authority = market
    )]
    pub vault: Account<'info, TokenAccount>,
    #[account(mut)]
    pub authority: Signer<'info>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
    pub rent: Sysvar<'info, Rent>,
}

#[allow(clippy::too_many_arguments)]
pub fn handler(
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
    require!(
        question.as_bytes().len() <= MAX_QUESTION_LEN,
        PmError::BadParam
    );
    let now = Clock::get()?.unix_timestamp;
    require!(
        close_time > now && resolve_time >= close_time,
        PmError::BadParam
    );
    require!(comparator <= CMP_LT, PmError::BadParam);

    if source_kind == KIND_ORACLE {
        require!(
            token_in != Pubkey::default() && token_out != Pubkey::default(),
            PmError::BadParam
        );
        require!(twap_window > 0 && threshold > 0, PmError::BadParam);
    } else if source_kind == KIND_ATTESTED {
        require!(
            attestor != Pubkey::default() && bond > 0 && dispute_window > 0,
            PmError::BadParam
        );
    } else {
        return err!(PmError::BadParam);
    }

    let cfg = &mut ctx.accounts.config;
    let m = &mut ctx.accounts.market;
    m.id = cfg.market_count;
    m.collateral_mint = ctx.accounts.collateral_mint.key();
    m.close_time = close_time;
    m.resolve_time = resolve_time;
    m.dispute_window = dispute_window;
    m.dispute_until = 0;
    m.attestor = attestor;
    m.pool_yes = 0;
    m.pool_no = 0;
    m.winner_pool = 0;
    m.payout_pool = 0;
    m.bond = bond;
    m.proposer = Pubkey::default();
    m.disputer = Pubkey::default();
    m.proposed = OUT_UNRESOLVED;
    m.outcome = OUT_UNRESOLVED;
    m.status = ST_TRADING;
    m.source_kind = source_kind;
    m.comparator = comparator;
    m.threshold = threshold;
    m.token_in = token_in;
    m.token_out = token_out;
    m.twap_window = twap_window;
    m.feed_ref = feed_ref;
    m.fee_bps_cache = cfg.protocol_fee_bps;
    m.question = question;
    m.vault = ctx.accounts.vault.key();
    m.bump = ctx.bumps.market;

    cfg.market_count = cfg.market_count.checked_add(1).unwrap();
    Ok(())
}
