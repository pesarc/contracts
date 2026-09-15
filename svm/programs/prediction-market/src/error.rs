use anchor_lang::prelude::*;

#[error_code]
pub enum PmError {
    #[msg("bad parameter")]
    BadParam,
    #[msg("market is not trading")]
    NotTrading,
    #[msg("trading has closed")]
    TradingClosed,
    #[msg("too early")]
    TooEarly,
    #[msg("not the attestor")]
    NotAttestor,
    #[msg("wrong source kind")]
    WrongSourceKind,
    #[msg("disputes disabled")]
    DisputesDisabled,
    #[msg("dispute window closed")]
    WindowClosed,
    #[msg("dispute window still open")]
    WindowOpen,
    #[msg("bad status")]
    BadStatus,
    #[msg("already claimed")]
    AlreadyClaimed,
    #[msg("nothing to claim")]
    NothingToClaim,
    #[msg("market not invalid")]
    NotInvalid,
    #[msg("oracle pair account does not match the market's source")]
    BadOraclePair,
    #[msg("oracle consult CPI returned no / malformed data")]
    OracleCallFailed,
}
