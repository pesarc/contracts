//! Pure resolution/settlement helpers shared across instructions.

use anchor_lang::prelude::*;
use anchor_spl::token::{self, Token, TokenAccount, Transfer};

use crate::constants::*;
use crate::events::*;
use crate::state::Market;

/// Map a realized value against the pinned threshold + comparator to YES/NO.
pub fn compare(value: u128, threshold: u128, cmp: u8) -> u8 {
    if cmp == CMP_GTE {
        if value >= threshold {
            OUT_YES
        } else {
            OUT_NO
        }
    } else if value < threshold {
        OUT_YES
    } else {
        OUT_NO
    }
}

/// Record a proposed outcome and open the dispute window.
pub fn record_proposal(m: &mut Account<Market>, outcome: u8) -> Result<()> {
    m.proposed = outcome;
    m.status = ST_PROPOSED;
    let now = Clock::get()?.unix_timestamp;
    m.dispute_until = now.checked_add(m.dispute_window).unwrap();
    emit!(Proposed {
        market: m.key(),
        outcome,
        dispute_until: m.dispute_until
    });
    Ok(())
}

/// Lock the outcome and snapshot the parimutuel split; returns the protocol fee
/// (taken only from the losing pool) the caller must sweep to the treasury. An
/// empty winning side voids to Invalid (refund path), no fee.
pub fn settle_outcome(m: &mut Account<Market>, outcome: u8) -> u64 {
    m.status = ST_FINALIZED;
    if outcome == OUT_INVALID {
        m.outcome = OUT_INVALID;
        emit!(Resolved {
            market: m.key(),
            outcome: OUT_INVALID,
            winner_pool: 0,
            payout_pool: 0
        });
        return 0;
    }
    let (winner, loser) = if outcome == OUT_YES {
        (m.pool_yes, m.pool_no)
    } else {
        (m.pool_no, m.pool_yes)
    };
    if winner == 0 {
        m.outcome = OUT_INVALID;
        emit!(Resolved {
            market: m.key(),
            outcome: OUT_INVALID,
            winner_pool: 0,
            payout_pool: 0
        });
        return 0;
    }
    let fee_bps = m.fee_bps_cache as u128;
    let fee = ((loser as u128) * fee_bps / 10_000u128) as u64;
    let payout = (winner as u128 + (loser as u128 - fee as u128)) as u64;
    m.outcome = outcome;
    m.winner_pool = winner;
    m.payout_pool = payout;
    emit!(Resolved {
        market: m.key(),
        outcome,
        winner_pool: winner,
        payout_pool: payout
    });
    fee
}

/// Move `amount` out of the market-owned vault, signed by the market PDA.
pub fn pay<'info>(
    token_program: &Program<'info, Token>,
    vault: &Account<'info, TokenAccount>,
    dest: &Account<'info, TokenAccount>,
    market: &AccountInfo<'info>,
    seeds: &[&[u8]],
    amount: u64,
) -> Result<()> {
    token::transfer(
        CpiContext::new_with_signer(
            token_program.key(),
            Transfer {
                from: vault.to_account_info(),
                to: dest.to_account_info(),
                authority: market.clone(),
            },
            &[seeds],
        ),
        amount,
    )
}
