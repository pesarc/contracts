//! Realized-rate accrual + TWAP, mirroring the EVM RealizedRateOracle.

use crate::constants::CARDINALITY;
use crate::state::{Observation, PairState};

/// Accrue the previous rate over the elapsed interval, push an observation, then
/// start the new rate. Same-second prints just replace the running rate. Seeds
/// the series on the first print.
pub fn record_rate(pair: &mut PairState, now: i64, rate_1e18: u128) {
    if pair.last_update == 0 {
        pair.last_update = now;
        pair.last_rate_1e18 = rate_1e18;
        pair.cumulative = 0;
        pair.observations[0] = Observation {
            timestamp: now,
            cumulative: 0,
        };
        pair.index = 1;
        pair.cardinality = 1;
        return;
    }

    let elapsed = (now - pair.last_update) as u128;
    if elapsed > 0 {
        pair.cumulative = pair
            .cumulative
            .saturating_add(pair.last_rate_1e18.saturating_mul(elapsed));
        pair.last_update = now;

        let i = pair.index as usize;
        pair.observations[i] = Observation {
            timestamp: now,
            cumulative: pair.cumulative,
        };
        let next = (i + 1) % CARDINALITY;
        pair.index = next as u8;
        if (pair.cardinality as usize) < CARDINALITY {
            pair.cardinality += 1;
        }
    }
    pair.last_rate_1e18 = rate_1e18;
}

/// Time-weighted average realized rate over the trailing `window` seconds. Falls
/// back to the full available history when the window reaches past the oldest
/// retained observation.
pub fn twap(pair: &PairState, now: i64, window: u32) -> u128 {
    // Cumulative up to *now*, including the still-running interval.
    let running = pair
        .last_rate_1e18
        .saturating_mul((now - pair.last_update).max(0) as u128);
    let cumulative_now = pair.cumulative.saturating_add(running);

    let window_i = window as i64;
    let target = if window_i >= now { 0 } else { now - window_i };
    let (obs_ts, obs_cum) = observation_at_or_before(pair, target);

    let dt = now - obs_ts;
    if dt <= 0 {
        return pair.last_rate_1e18;
    }
    (cumulative_now - obs_cum) / (dt as u128)
}

/// Walk the ring buffer backwards for the newest observation at or before
/// `target`; falls back to the oldest retained observation.
fn observation_at_or_before(pair: &PairState, target: i64) -> (i64, u128) {
    let mut idx = pair.index as usize;
    let mut ts = 0i64;
    let mut cumulative = 0u128;

    for _ in 0..(pair.cardinality as usize) {
        idx = if idx == 0 { CARDINALITY - 1 } else { idx - 1 };
        let o = pair.observations[idx];
        if o.timestamp == 0 {
            break;
        }
        // Remember the oldest seen as the fallback.
        ts = o.timestamp;
        cumulative = o.cumulative;
        if o.timestamp <= target {
            break;
        }
    }
    (ts, cumulative)
}
