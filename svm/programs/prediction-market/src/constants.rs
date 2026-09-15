//! Program-wide constants and the small enums encoded as `u8` on-chain (kept as
//! constants so account layouts stay fixed-size and easy to reason about).

use anchor_lang::prelude::*;

/// Deployed SVM RealizedRateOracle (Goldgard/solana). Oracle-kind markets
/// resolve by CPI into this program's `consult`.
pub const ORACLE_PROGRAM_ID: Pubkey = pubkey!("4NUdEu7crxzR1AtHhaiMLk4q1ctTvhZLREq7Pbt9KNkK");

/// Max protocol fee, in basis points (10%).
pub const MAX_FEE_BPS: u16 = 1000;
/// Max market question length, in bytes.
pub const MAX_QUESTION_LEN: usize = 160;

// Source kind
pub const KIND_ORACLE: u8 = 0;
pub const KIND_ATTESTED: u8 = 1;

// Comparator
pub const CMP_GTE: u8 = 0; // YES iff value >= threshold
pub const CMP_LT: u8 = 1; // YES iff value <  threshold

// Outcome
pub const OUT_UNRESOLVED: u8 = 0;
pub const OUT_YES: u8 = 1;
pub const OUT_NO: u8 = 2;
pub const OUT_INVALID: u8 = 3;

// Status
pub const ST_TRADING: u8 = 0;
pub const ST_PROPOSED: u8 = 1;
pub const ST_DISPUTED: u8 = 2;
pub const ST_FINALIZED: u8 = 3;
