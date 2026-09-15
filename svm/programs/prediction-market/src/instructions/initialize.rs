use anchor_lang::prelude::*;

use crate::constants::*;
use crate::error::PmError;
use crate::state::Config;

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(init, payer = authority, space = 8 + Config::INIT_SPACE, seeds = [b"config"], bump)]
    pub config: Account<'info, Config>,
    #[account(mut)]
    pub authority: Signer<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(ctx: Context<Initialize>, treasury: Pubkey, protocol_fee_bps: u16) -> Result<()> {
    require!(protocol_fee_bps <= MAX_FEE_BPS, PmError::BadParam);
    let c = &mut ctx.accounts.config;
    c.authority = ctx.accounts.authority.key();
    c.treasury = treasury;
    c.protocol_fee_bps = protocol_fee_bps;
    c.market_count = 0;
    c.bump = ctx.bumps.config;
    Ok(())
}
