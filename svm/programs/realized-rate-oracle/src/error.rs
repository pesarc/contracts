use anchor_lang::prelude::*;

#[error_code]
pub enum OracleError {
    #[msg("caller is not an allowed recorder")]
    NotRecorder,
    #[msg("rate must be non-zero")]
    BadRate,
    #[msg("no data recorded for this pair")]
    NoData,
}
