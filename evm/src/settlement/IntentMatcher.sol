// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {RealizedRateOracle} from "../oracle/RealizedRateOracle.sol";
import {
    BadAmount,
    BadRecipient,
    BadToken,
    NotMaker,
    NotSolver,
    IntentInactive,
    IntentExpired,
    NotExpired,
    NotOpposing,
    LimitNotMet,
    FillTooLarge,
    BadRing,
    DuplicateIntent
} from "../errors/IntentMatcherErrors.sol";

/// @title Pesarc Intent Matcher
/// @notice Local-currency-first settlement. Transfers enter as *intents* rather
///         than immediate swaps. When two opposing intents exist — a Ghanaian
///         sending to Nigeria and a Nigerian sending to Ghana — they settle
///         **directly against each other in local currency**: no pool, no
///         bridge, no USD. Only the residual imbalance ever needs a fallback.
///
///         Every match is also a **price print**: `IntentsMatched` records the
///         realized local-to-local rate from actual settled flow, which feeds
///         self-referential pricing — price discovery that no external feed
///         provider can deny or distort.
/// @dev    Non-custodial in spirit: escrow is per-intent and always refundable
///         to the maker. The solver can only pair intents; it can never move
///         funds anywhere the maker didn't specify, and can never settle worse
///         than the maker's own limit.
contract IntentMatcher is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice A maker's request: "swap `amountIn` of tokenIn for at least the
    ///         limit rate of tokenOut, delivered to `recipient`, before expiry".
    struct Intent {
        address maker;
        address recipient;
        address tokenIn;
        address tokenOut;
        /// @dev Original input amount (fixes the limit rate across partial fills).
        uint128 amountIn;
        /// @dev Minimum total output for `amountIn` — defines the limit rate.
        uint128 minAmountOut;
        /// @dev Input still unfilled.
        uint128 remainingIn;
        uint64 expiry;
        bool active;
    }

    event IntentSubmitted(
        uint256 indexed id,
        address indexed maker,
        address indexed tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint128 minAmountOut,
        uint64 expiry,
        bytes32 reference_
    );
    /// @notice A local-to-local settlement. `rate1e18` = tokenB per tokenA,
    ///         the realized price print for self-referential discovery.
    event IntentsMatched(
        uint256 indexed idA,
        uint256 indexed idB,
        address tokenA,
        address tokenB,
        uint128 fillA,
        uint128 fillB,
        uint256 rate1e18
    );
    /// @notice A closed cycle settled with no external liquidity at all.
    event RingMatched(uint256[] ids, uint128[] fills);
    event IntentCancelled(uint256 indexed id, uint128 refunded);
    event SolverSet(address indexed solver, bool allowed);
    event RateOracleSet(address indexed oracle);

    /// @dev Ring size cap — bounds gas and keeps solver search tractable.
    uint256 public constant MAX_RING = 8;

    uint256 public intentCount;
    mapping(uint256 => Intent) public intents;
    /// @notice Addresses allowed to pair intents. Solvers are untrusted with
    ///         funds — they can only propose pairings the limits already allow.
    mapping(address => bool) public isSolver;

    /// @notice Receives a price print for every settled leg. Optional: if
    ///         unset or reverting, settlement still succeeds — pricing must
    ///         never be able to block payments.
    RealizedRateOracle public rateOracle;

    constructor(address _owner) Ownable(_owner) {}

    function setRateOracle(RealizedRateOracle oracle) external onlyOwner {
        rateOracle = oracle;
        emit RateOracleSet(address(oracle));
    }

    modifier onlySolver() {
        if (!isSolver[msg.sender] && msg.sender != owner()) revert NotSolver();
        _;
    }

    function setSolver(address solver, bool allowed) external onlyOwner {
        isSolver[solver] = allowed;
        emit SolverSet(solver, allowed);
    }

    /* ---------------- makers ---------------- */

    /// @notice Escrows `amountIn` and opens an intent.
    /// @param minAmountOut Minimum total tokenOut for the full `amountIn` —
    ///        partial fills are held to the same rate, pro rata.
    function submitIntent(
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint128 minAmountOut,
        address recipient,
        uint64 expiry,
        bytes32 reference_
    ) external nonReentrant returns (uint256 id) {
        if (amountIn == 0 || minAmountOut == 0) revert BadAmount();
        if (recipient == address(0)) revert BadRecipient();
        if (tokenIn == tokenOut || tokenIn == address(0) || tokenOut == address(0)) {
            revert BadToken();
        }
        if (expiry <= block.timestamp) revert IntentExpired();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        id = ++intentCount;
        intents[id] = Intent({
            maker: msg.sender,
            recipient: recipient,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            remainingIn: amountIn,
            expiry: expiry,
            active: true
        });

        emit IntentSubmitted(id, msg.sender, tokenIn, tokenOut, amountIn, minAmountOut, expiry, reference_);
    }

    /// @notice Refunds the unfilled remainder. The maker may cancel any time;
    ///         anyone may cancel once expired (so escrow never sticks).
    function cancelIntent(uint256 id) external nonReentrant {
        Intent storage i = intents[id];
        if (!i.active) revert IntentInactive();
        if (msg.sender != i.maker && block.timestamp <= i.expiry) {
            revert NotMaker();
        }

        uint128 refund = i.remainingIn;
        i.active = false;
        i.remainingIn = 0;
        if (refund > 0) IERC20(i.tokenIn).safeTransfer(i.maker, refund);
        emit IntentCancelled(id, refund);
    }

    /* ---------------- solver ---------------- */

    /// @notice Settles two opposing intents directly against each other —
    ///         **local currency to local currency, zero USD, zero pool**.
    /// @param fillA Amount of A's tokenIn that A gives up (B receives).
    /// @param fillB Amount of B's tokenIn that B gives up (A receives).
    /// @dev The solver chooses the clearing rate by picking (fillA, fillB);
    ///      the contract enforces that BOTH makers' limit rates are satisfied,
    ///      so any rate inside the overlap is acceptable and no maker can be
    ///      settled worse than they asked for.
    function matchIntents(uint256 idA, uint256 idB, uint128 fillA, uint128 fillB) external onlySolver nonReentrant {
        uint256[] memory ids = new uint256[](2);
        uint128[] memory fills = new uint128[](2);
        (ids[0], ids[1]) = (idA, idB);
        (fills[0], fills[1]) = (fillA, fillB);
        _settleRing(ids, fills);

        Intent storage a = intents[idA];
        Intent storage b = intents[idB];
        emit IntentsMatched(idA, idB, a.tokenIn, b.tokenIn, fillA, fillB, (uint256(fillB) * 1e18) / fillA);
    }

    /// @notice Settles a **closed cycle** of intents with no external liquidity:
    ///         e.g. Ghana→Nigeria, Nigeria→Kenya, Kenya→Ghana all clear against
    ///         each other. Nobody needed a counterparty for their exact pair —
    ///         the ring closes it. Zero pools, zero bridges, zero USD.
    /// @param ids Intents in cycle order: `ids[i].tokenOut == ids[i+1].tokenIn`,
    ///        wrapping at the end.
    /// @param fills How much of its own tokenIn each intent gives up. Intent `i`
    ///        receives `fills[i+1]` (the next intent's escrow, which is exactly
    ///        the token `i` asked for).
    function matchRing(uint256[] calldata ids, uint128[] calldata fills) external onlySolver nonReentrant {
        _settleRing(ids, fills);
        emit RingMatched(ids, fills);
    }

    /// @dev The one settlement path. A 2-party match is just a ring of length 2.
    function _settleRing(uint256[] memory ids, uint128[] memory fills) internal {
        uint256 n = ids.length;
        if (n < 2 || n > MAX_RING || fills.length != n) revert BadRing();

        // Duplicates would let one escrow be spent twice.
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                if (ids[i] == ids[j]) revert DuplicateIntent();
            }
        }

        // Pass 1 — the cycle's shape. Reject a malformed ring before judging
        // any economics, so a bad topology never surfaces as a limit error.
        for (uint256 i = 0; i < n; i++) {
            Intent storage cur = intents[ids[i]];
            Intent storage next = intents[ids[(i + 1) % n]];

            if (!cur.active) revert IntentInactive();
            if (block.timestamp > cur.expiry) revert IntentExpired();
            // The cycle must chain: what I want is what the next one is giving.
            if (cur.tokenOut != next.tokenIn) revert NotOpposing();
            if (fills[i] == 0) revert BadAmount();
            if (fills[i] > cur.remainingIn) revert FillTooLarge();
        }

        // Pass 2 — every maker's own limit, pro rata to what they give.
        for (uint256 i = 0; i < n; i++) {
            Intent storage cur = intents[ids[i]];
            if (uint256(fills[(i + 1) % n]) * cur.amountIn < uint256(cur.minAmountOut) * fills[i]) {
                revert LimitNotMet();
            }
        }

        // Effects, then interactions.
        for (uint256 i = 0; i < n; i++) {
            Intent storage cur = intents[ids[i]];
            unchecked {
                cur.remainingIn -= fills[i];
            }
            if (cur.remainingIn == 0) cur.active = false;
        }

        for (uint256 i = 0; i < n; i++) {
            Intent storage cur = intents[ids[i]];
            // My escrow goes to whoever wanted my token — the previous link.
            Intent storage prev = intents[ids[(i + n - 1) % n]];
            IERC20(cur.tokenIn).safeTransfer(prev.recipient, fills[i]);
        }

        _recordPrints(ids, fills);
    }

    /// @dev Publishes each leg's realized rate (both directions) to the
    ///      self-referential oracle. Best-effort: pricing must never block a
    ///      payment, so a missing/failing oracle is ignored.
    function _recordPrints(uint256[] memory ids, uint128[] memory fills) internal {
        RealizedRateOracle oracle = rateOracle;
        if (address(oracle) == address(0)) return;

        uint256 n = ids.length;
        for (uint256 i = 0; i < n; i++) {
            Intent storage cur = intents[ids[i]];
            uint128 gave = fills[i];
            uint128 got = fills[(i + 1) % n];
            if (gave == 0 || got == 0) continue;

            try oracle.record(cur.tokenIn, cur.tokenOut, (uint256(got) * 1e18) / gave) {} catch {}
            try oracle.record(cur.tokenOut, cur.tokenIn, (uint256(gave) * 1e18) / got) {} catch {}
        }
    }

    /* ---------------- views ---------------- */

    /// @notice True when the two intents are opposing, live, and their limit
    ///         rates overlap — i.e. a match exists at some rate.
    function isMatchable(uint256 idA, uint256 idB) external view returns (bool) {
        Intent memory a = intents[idA];
        Intent memory b = intents[idB];
        if (!a.active || !b.active) return false;
        if (block.timestamp > a.expiry || block.timestamp > b.expiry) {
            return false;
        }
        if (a.tokenIn != b.tokenOut || a.tokenOut != b.tokenIn) return false;
        // A's floor: out/in >= minA/amtA. B's ceiling (in A's terms): the most
        // A can receive per unit given is amtB/minB. Overlap iff floor <= ceiling.
        return uint256(a.minAmountOut) * b.minAmountOut <= uint256(a.amountIn) * b.amountIn;
    }

    /// @notice The maker's limit rate (tokenOut per tokenIn, 1e18-scaled).
    function limitRate1e18(uint256 id) external view returns (uint256) {
        Intent memory i = intents[id];
        if (i.amountIn == 0) return 0;
        return (uint256(i.minAmountOut) * 1e18) / i.amountIn;
    }
}
