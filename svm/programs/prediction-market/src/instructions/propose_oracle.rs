use anchor_lang::prelude::*;
use anchor_lang::solana_program::{
    instruction::{AccountMeta, Instruction},
    program::{get_return_data, invoke},
};

use crate::constants::*;
use crate::error::PmError;
use crate::state::Market;
use crate::utils::{compare, record_proposal};

/// Anchor discriminator for RealizedRateOracle::consult — sha256("global:consult")[..8].
const CONSULT_DISCRIMINATOR: [u8; 8] = [65, 242, 246, 89, 73, 197, 128, 71];

/// Oracle path — permissionless once `resolve_time` has passed. Resolves the
/// market by CPI into the RealizedRateOracle's `consult`, reading the realized
/// TWAP from return data and comparing it to the pinned threshold. Deterministic
/// and trustless: no authority relays the number.
#[derive(Accounts)]
pub struct ProposeOracle<'info> {
    #[account(mut)]
    pub market: Account<'info, Market>,
    /// CHECK: pinned to the deployed RealizedRateOracle program id.
    #[account(address = ORACLE_PROGRAM_ID)]
    pub oracle_program: UncheckedAccount<'info>,
    /// CHECK: validated below against the PairState PDA derived from the market's
    /// pinned source pair.
    pub oracle_pair: UncheckedAccount<'info>,
}

pub fn handler(ctx: Context<ProposeOracle>) -> Result<()> {
    let m = &mut ctx.accounts.market;
    require!(m.status == ST_TRADING, PmError::NotTrading);
    require!(m.source_kind == KIND_ORACLE, PmError::WrongSourceKind);
    require!(
        Clock::get()?.unix_timestamp >= m.resolve_time,
        PmError::TooEarly
    );

    let token_in = m.token_in;
    let token_out = m.token_out;
    let window = m.twap_window;
    let threshold = m.threshold;
    let comparator = m.comparator;

    // The passed oracle_pair must be the PairState PDA for this market's pair.
    let (expected_pair, _bump) = Pubkey::find_program_address(
        &[b"pair", token_in.as_ref(), token_out.as_ref()],
        &ORACLE_PROGRAM_ID,
    );
    require_keys_eq!(
        ctx.accounts.oracle_pair.key(),
        expected_pair,
        PmError::BadOraclePair
    );

    // Build and invoke RealizedRateOracle::consult(token_in, token_out, window).
    // Anchor discriminator = sha256("global:consult")[..8]; args are borsh —
    // Pubkey is 32 raw bytes, u32 is 4 LE bytes.
    let mut data = Vec::with_capacity(8 + 32 + 32 + 4);
    data.extend_from_slice(&CONSULT_DISCRIMINATOR);
    data.extend_from_slice(token_in.as_ref());
    data.extend_from_slice(token_out.as_ref());
    data.extend_from_slice(&window.to_le_bytes());

    let ix = Instruction {
        program_id: ORACLE_PROGRAM_ID,
        accounts: vec![AccountMeta::new_readonly(
            ctx.accounts.oracle_pair.key(),
            false,
        )],
        data,
    };
    invoke(
        &ix,
        &[
            ctx.accounts.oracle_pair.to_account_info(),
            ctx.accounts.oracle_program.to_account_info(),
        ],
    )?;

    // consult returns rate_1e18 as borsh u128 (16 LE bytes) via return data.
    let (ret_program, ret) = get_return_data().ok_or(PmError::OracleCallFailed)?;
    require!(
        ret_program == ORACLE_PROGRAM_ID && ret.len() >= 16,
        PmError::OracleCallFailed
    );
    let rate = u128::from_le_bytes(ret[..16].try_into().unwrap());

    let outcome = compare(rate, threshold, comparator);
    record_proposal(m, outcome)
}
