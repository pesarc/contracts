// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {NotRecorder, BadRate, NoData} from "../errors/RealizedRateOracleErrors.sol";

/// @title Pesarc Realized-Rate Oracle
/// @notice Self-referential price discovery. Records the rate of every
///         settlement that actually clears on our own rail and exposes a
///         time-weighted average per directional pair.
///
///         This is the answer to the dependency that outlives settlement: the
///         price comes from **our own realized local-to-local flow**, not from a
///         USD-referenced feed. No external provider can deny it, no
///         jurisdiction can compel it, and moving it costs real capital because
///         every print is a trade someone actually made at their own limit.
/// @dev    Fed by the IntentMatcher on each match. Directional: `record(A, B, r)`
///         means "r of B per 1 A (1e18-scaled)". The matcher records both
///         directions, so `consult` is accurate either way (TWAP of an inverse
///         is not the inverse of a TWAP).
contract RealizedRateOracle is Ownable2Step {
    event RateRecorded(address indexed tokenIn, address indexed tokenOut, uint256 rate1e18, uint64 timestamp);
    event RecorderSet(address indexed recorder, bool allowed);

    uint8 internal constant CARDINALITY = 32;

    struct Observation {
        uint64 timestamp;
        /// @dev Cumulative Σ(rate × seconds) up to `timestamp`.
        uint256 cumulative;
    }

    struct PairState {
        uint64 lastUpdate;
        uint256 lastRate1e18;
        uint256 cumulative;
        uint8 index;
        uint8 cardinality;
    }

    /// @notice Addresses allowed to record prints (the IntentMatcher).
    mapping(address => bool) public isRecorder;
    mapping(bytes32 => PairState) public pairState;
    mapping(bytes32 => Observation[CARDINALITY]) internal observations;

    constructor(address _owner) Ownable(_owner) {}

    function setRecorder(address recorder, bool allowed) external onlyOwner {
        isRecorder[recorder] = allowed;
        emit RecorderSet(recorder, allowed);
    }

    /// @notice Canonical key for a *directional* pair.
    function pairKey(address tokenIn, address tokenOut) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenIn, tokenOut));
    }

    /// @notice Records a realized settlement rate: `rate1e18` of tokenOut per tokenIn.
    function record(address tokenIn, address tokenOut, uint256 rate1e18) external {
        if (!isRecorder[msg.sender]) revert NotRecorder();
        if (rate1e18 == 0) revert BadRate();

        bytes32 key = pairKey(tokenIn, tokenOut);
        PairState storage s = pairState[key];
        uint64 t = uint64(block.timestamp);

        if (s.lastUpdate == 0) {
            // First print for this pair — seed the series.
            s.lastUpdate = t;
            s.lastRate1e18 = rate1e18;
            s.cumulative = 0;
            observations[key][0] = Observation({timestamp: t, cumulative: 0});
            s.index = 1;
            s.cardinality = 1;
            emit RateRecorded(tokenIn, tokenOut, rate1e18, t);
            return;
        }

        // Accrue the previous rate over the elapsed interval, then start the
        // new one. Same-second prints just replace the running rate.
        uint64 elapsed = t - s.lastUpdate;
        if (elapsed > 0) {
            s.cumulative += s.lastRate1e18 * elapsed;
            s.lastUpdate = t;

            uint8 i = s.index;
            observations[key][i] = Observation({timestamp: t, cumulative: s.cumulative});
            unchecked {
                i++;
            }
            if (i == CARDINALITY) i = 0;
            s.index = i;
            if (s.cardinality < CARDINALITY) s.cardinality++;
        }
        s.lastRate1e18 = rate1e18;

        emit RateRecorded(tokenIn, tokenOut, rate1e18, t);
    }

    /// @notice Most recent realized rate (spot print) for a directional pair.
    function latestRate1e18(address tokenIn, address tokenOut) external view returns (uint256) {
        PairState memory s = pairState[pairKey(tokenIn, tokenOut)];
        if (s.lastUpdate == 0) revert NoData();
        return s.lastRate1e18;
    }

    /// @notice Time-weighted average realized rate over the trailing `window`
    ///         seconds. Falls back to the full available history when the
    ///         window reaches past our oldest observation.
    function consult(address tokenIn, address tokenOut, uint32 window) external view returns (uint256 twap1e18) {
        bytes32 key = pairKey(tokenIn, tokenOut);
        PairState memory s = pairState[key];
        if (s.lastUpdate == 0) revert NoData();

        uint64 t = uint64(block.timestamp);
        // Cumulative up to *now*, including the still-running interval.
        uint256 cumulativeNow = s.cumulative + s.lastRate1e18 * (t - s.lastUpdate);

        uint64 target = window >= t ? 0 : t - uint64(window);
        (uint64 obsTs, uint256 obsCum) = _observationAtOrBefore(key, target, s);

        uint64 dt = t - obsTs;
        // Only one instant of history (or a zero-length window): report spot.
        if (dt == 0) return s.lastRate1e18;
        return (cumulativeNow - obsCum) / dt;
    }

    /// @notice True once a pair has any realized print.
    function hasData(address tokenIn, address tokenOut) external view returns (bool) {
        return pairState[pairKey(tokenIn, tokenOut)].lastUpdate != 0;
    }

    /// @dev Walks the ring buffer backwards for the newest observation at or
    ///      before `target`; falls back to the oldest we still retain.
    function _observationAtOrBefore(bytes32 key, uint64 target, PairState memory s)
        internal
        view
        returns (uint64 ts, uint256 cumulative)
    {
        uint8 idx = s.index;
        ts = 0;
        cumulative = 0;
        bool found;

        for (uint8 k = 0; k < s.cardinality; k++) {
            if (idx == 0) idx = CARDINALITY;
            unchecked {
                idx--;
            }
            Observation memory o = observations[key][idx];
            if (o.timestamp == 0) break;
            // Remember the oldest we've seen as the fallback.
            ts = o.timestamp;
            cumulative = o.cumulative;
            if (o.timestamp <= target) {
                found = true;
                break;
            }
        }
        // If nothing is old enough, `ts/cumulative` hold the oldest retained
        // observation — i.e. average over all the history we have.
        found; // silence unused-var lint; fallback is intentional
    }
}
