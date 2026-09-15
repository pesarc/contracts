use anchor_lang::prelude::*;

use crate::events::RecorderSet;
use crate::state::{Config, Recorder};

/// Allow or disallow an address to record realized rates (typically the
/// IntentMatcher / settlement program). Toggles a stored flag rather than
/// creating/closing accounts.
#[derive(Accounts)]
#[instruction(recorder: Pubkey)]
pub struct SetRecorder<'info> {
    #[account(seeds = [b"config"], bump = config.bump, has_one = authority)]
    pub config: Account<'info, Config>,
    #[account(
        init_if_needed,
        payer = authority,
        space = 8 + Recorder::INIT_SPACE,
        seeds = [b"recorder", recorder.as_ref()],
        bump
    )]
    pub recorder_acct: Account<'info, Recorder>,
    #[account(mut)]
    pub authority: Signer<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(ctx: Context<SetRecorder>, recorder: Pubkey, allowed: bool) -> Result<()> {
    let r = &mut ctx.accounts.recorder_acct;
    r.recorder = recorder;
    r.allowed = allowed;
    r.bump = ctx.bumps.recorder_acct;
    emit!(RecorderSet { recorder, allowed });
    Ok(())
}
