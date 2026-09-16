// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {IRealizedRateOracle} from "../interfaces/IRealizedRateOracle.sol";
import {
    BadParam,
    NotTrading,
    TradingClosed,
    TooEarly,
    NotAttestor,
    WrongSourceKind,
    DisputesDisabled,
    WindowClosed,
    WindowOpen,
    BadStatus,
    NoOracleData,
    AlreadyClaimed,
    NothingToClaim,
    NotInvalid
} from "../errors/PredictionMarketErrors.sol";

/// @title Pesarc Prediction & Hedge Market
/// @notice Binary, **parimutuel** markets settled in a local-currency stablecoin
///         (the collateral is cNGN / cKES — not USDC — which is the whole edge:
///         the position, the payout, and the thing being hedged are all the same
///         currency, so there is no dollar in the path).
///
///         Two ways a market resolves, pinned at creation and never changed:
///           - **Oracle** — FX/macro questions ("USD/NGN monthly close ≥ 1600?")
///             resolve deterministically from Pesarc's own
///             {RealizedRateOracle} TWAP. This doubles as a *hedge*: it settles
///             the naira slide from the rail's own realized flow, no external
///             feed to deny or compel.
///           - **Attested** — real-world macro data with no on-chain feed
///             (petrol pump price, CPI) is proposed by a bonded attestor and
///             held open for a dispute window (UMA-style) before it finalizes.
///
///         Parimutuel means no order book and no counterparty risk: each side
///         pools its stakes, and the winning side splits the whole pot (net of a
///         protocol fee taken only from the losing pool). If a side is empty, or
///         the market is voided, everyone is refunded their principal.
/// @dev    Money math follows the house rules: SafeERC20 everywhere,
///         checks-effects-interactions on every external transfer, ReentrancyGuard
///         on the value-moving paths, Ownable2Step admin, uint128 caps on staked
///         pools. Market creation is owner/curator-gated (licence-first posture).
contract PredictionMarket is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ----------------------------------------------------------------- types

    enum SourceKind {
        Oracle,
        Attested
    }

    /// @dev How the pinned threshold is compared to the realized value to get YES.
    enum Comparator {
        GreaterOrEqual, // YES iff value >= threshold  ("close ≥ 1600")
        LessThan // YES iff value <  threshold  ("inflation stays under 20%")
    }

    enum Outcome {
        Unresolved,
        Yes,
        No,
        Invalid
    }

    enum Status {
        Trading, // staking open
        Proposed, // an outcome is proposed, dispute window running
        Disputed, // escalated to the arbiter
        Finalized // outcome locked, claims open
    }

    /// @notice Immutable resolution spec, pinned when the market is created.
    struct Source {
        SourceKind kind;
        address tokenIn; // Oracle: directional pair base (e.g. USD stable)
        address tokenOut; // Oracle: directional pair quote (e.g. cNGN)
        uint32 twapWindow; // Oracle: TWAP window, seconds
        Comparator comparator;
        uint256 threshold; // Oracle: rate1e18 · Attested: agreed integer units
        bytes32 feedRef; // attribution, e.g. keccak256("NBS-CPI") / "NMDPRA-PMS"
    }

    struct Market {
        string question;
        address collateral;
        uint64 closeTime; // staking closes
        uint64 resolveTime; // earliest an outcome may be proposed
        uint64 disputeWindow; // seconds a proposal stays open to challenge
        uint64 disputeUntil; // set when an outcome is proposed
        address attestor; // Attested: the only address that may propose
        uint128 poolYes;
        uint128 poolNo;
        uint256 winnerPool; // snapshot at finalize
        uint256 payoutPool; // snapshot at finalize (winnerPool + net loser pool)
        uint256 bond; // proposal / dispute bond, in collateral units
        address proposer; // who proposed (and, if Attested, posted the bond)
        address disputer; // who challenged (posted an equal bond)
        Outcome proposed;
        Outcome outcome;
        Status status;
        Source source;
    }

    // ----------------------------------------------------------------- state

    IRealizedRateOracle public oracle;
    address public treasury;
    uint16 public protocolFeeBps; // fee on the losing pool, <= MAX_FEE_BPS
    uint16 public constant MAX_FEE_BPS = 1000; // 10%

    uint256 public marketCount;
    mapping(uint256 => Market) internal _markets;
    mapping(uint256 => mapping(address => uint256)) public stakeYes;
    mapping(uint256 => mapping(address => uint256)) public stakeNo;
    mapping(uint256 => mapping(address => bool)) public claimed;

    // ---------------------------------------------------------------- events

    event MarketCreated(uint256 indexed id, address indexed collateral, SourceKind kind, string question);
    event Staked(uint256 indexed id, address indexed user, bool isYes, uint256 amount);
    event Proposed(uint256 indexed id, address indexed proposer, Outcome outcome, uint64 disputeUntil);
    event Disputed(uint256 indexed id, address indexed disputer);
    event Resolved(uint256 indexed id, Outcome outcome, uint256 winnerPool, uint256 payoutPool);
    event Claimed(uint256 indexed id, address indexed user, uint256 amount);
    event Refunded(uint256 indexed id, address indexed user, uint256 amount);
    event FeeConfigured(address treasury, uint16 protocolFeeBps);
    event OracleSet(address oracle);

    // ----------------------------------------------------------- constructor

    constructor(address _owner, address _oracle, address _treasury, uint16 _protocolFeeBps) Ownable(_owner) {
        if (_protocolFeeBps > MAX_FEE_BPS) revert BadParam();
        oracle = IRealizedRateOracle(_oracle);
        treasury = _treasury;
        protocolFeeBps = _protocolFeeBps;
        emit OracleSet(_oracle);
        emit FeeConfigured(_treasury, _protocolFeeBps);
    }

    // ------------------------------------------------------------------ admin

    function setOracle(address _oracle) external onlyOwner {
        oracle = IRealizedRateOracle(_oracle);
        emit OracleSet(_oracle);
    }

    function setFeeConfig(address _treasury, uint16 _protocolFeeBps) external onlyOwner {
        if (_protocolFeeBps > MAX_FEE_BPS) revert BadParam();
        treasury = _treasury;
        protocolFeeBps = _protocolFeeBps;
        emit FeeConfigured(_treasury, _protocolFeeBps);
    }

    /// @notice Curate a new market. Owner-gated on purpose: markets ship under a
    ///         licence, not permissionlessly.
    function createMarket(
        string calldata question,
        address collateral,
        uint64 closeTime,
        uint64 resolveTime,
        uint64 disputeWindow,
        address attestor,
        uint256 bond,
        Source calldata source
    ) external onlyOwner returns (uint256 id) {
        if (collateral == address(0)) revert BadParam();
        if (closeTime <= block.timestamp || resolveTime < closeTime) {
            revert BadParam();
        }
        if (uint8(source.comparator) > uint8(Comparator.LessThan)) {
            revert BadParam();
        }

        if (source.kind == SourceKind.Oracle) {
            if (source.tokenIn == address(0) || source.tokenOut == address(0)) {
                revert BadParam();
            }
            if (source.twapWindow == 0 || source.threshold == 0) {
                revert BadParam();
            }
        } else {
            // Attested: a bonded attestor is the whole trust model.
            if (attestor == address(0) || bond == 0 || disputeWindow == 0) {
                revert BadParam();
            }
        }

        id = marketCount++;
        Market storage m = _markets[id];
        m.question = question;
        m.collateral = collateral;
        m.closeTime = closeTime;
        m.resolveTime = resolveTime;
        m.disputeWindow = disputeWindow;
        m.attestor = attestor;
        m.bond = bond;
        m.proposed = Outcome.Unresolved;
        m.outcome = Outcome.Unresolved;
        m.status = Status.Trading;
        m.source = source;

        emit MarketCreated(id, collateral, source.kind, question);
    }

    // ------------------------------------------------------------- staking

    /// @notice Stake `amount` of the market's collateral on YES or NO. A user may
    ///         stake either side, or both; each side is tracked independently.
    function stake(uint256 id, bool isYes, uint128 amount) external nonReentrant {
        Market storage m = _markets[id];
        if (m.collateral == address(0)) revert BadParam();
        if (m.status != Status.Trading) revert NotTrading();
        if (block.timestamp >= m.closeTime) revert TradingClosed();
        if (amount == 0) revert BadParam();

        if (isYes) {
            m.poolYes += amount; // reverts on uint128 overflow
            stakeYes[id][msg.sender] += amount;
        } else {
            m.poolNo += amount;
            stakeNo[id][msg.sender] += amount;
        }

        IERC20(m.collateral).safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(id, msg.sender, isYes, amount);
    }

    // ---------------------------------------------------------- resolution

    /// @notice Resolve an Oracle market from the RealizedRateOracle TWAP. Anyone
    ///         may call once `resolveTime` has passed — the answer is deterministic.
    function proposeFromOracle(uint256 id) external nonReentrant {
        Market storage m = _markets[id];
        if (m.status != Status.Trading) revert NotTrading();
        if (m.source.kind != SourceKind.Oracle) revert WrongSourceKind();
        if (block.timestamp < m.resolveTime) revert TooEarly();
        if (!oracle.hasData(m.source.tokenIn, m.source.tokenOut)) {
            revert NoOracleData();
        }

        uint256 rate = oracle.consult(m.source.tokenIn, m.source.tokenOut, m.source.twapWindow);
        Outcome o = _compare(rate, m.source.threshold, m.source.comparator);
        _recordProposal(id, m, o, address(0));
    }

    /// @notice Propose the outcome of an Attested market. Only the pinned attestor,
    ///         who must post the bond; the market then opens for disputes.
    function propose(uint256 id, Outcome outcome_) external nonReentrant {
        Market storage m = _markets[id];
        if (m.status != Status.Trading) revert NotTrading();
        if (m.source.kind != SourceKind.Attested) revert WrongSourceKind();
        if (msg.sender != m.attestor) revert NotAttestor();
        if (block.timestamp < m.resolveTime) revert TooEarly();
        if (outcome_ != Outcome.Yes && outcome_ != Outcome.No && outcome_ != Outcome.Invalid) {
            revert BadParam();
        }

        m.proposer = msg.sender;
        IERC20(m.collateral).safeTransferFrom(msg.sender, address(this), m.bond);
        _recordProposal(id, m, outcome_, msg.sender);
    }

    /// @notice Challenge a proposed outcome inside the dispute window by matching
    ///         the bond. Escalates to the arbiter. Only where a bond is configured.
    function dispute(uint256 id) external nonReentrant {
        Market storage m = _markets[id];
        if (m.status != Status.Proposed) revert BadStatus();
        if (m.bond == 0) revert DisputesDisabled();
        if (block.timestamp >= m.disputeUntil) revert WindowClosed();

        m.disputer = msg.sender;
        m.status = Status.Disputed;
        IERC20(m.collateral).safeTransferFrom(msg.sender, address(this), m.bond);
        emit Disputed(id, msg.sender);
    }

    /// @notice Lock in a proposed outcome once its dispute window has passed with
    ///         no challenge. Returns the proposer's bond (they were right).
    function finalize(uint256 id) external nonReentrant {
        Market storage m = _markets[id];
        if (m.status != Status.Proposed) revert BadStatus();
        if (block.timestamp < m.disputeUntil) revert WindowOpen();

        address proposer = m.proposer;
        uint256 bond = m.bond;
        address collateral = m.collateral;

        _settleOutcome(id, m, m.proposed);

        // Proposer bond back (Attested only; Oracle proposals post no bond).
        if (proposer != address(0) && bond > 0) {
            IERC20(collateral).safeTransfer(proposer, bond);
        }
    }

    /// @notice Arbiter ruling on a disputed market. Settles the outcome and the
    ///         two bonds: the party who was right takes both, the wrong one forfeits.
    function resolveDispute(uint256 id, Outcome finalOutcome) external onlyOwner nonReentrant {
        Market storage m = _markets[id];
        if (m.status != Status.Disputed) revert BadStatus();
        if (finalOutcome != Outcome.Yes && finalOutcome != Outcome.No && finalOutcome != Outcome.Invalid) {
            revert BadParam();
        }

        address proposer = m.proposer; // address(0) for oracle-proposed markets
        address disputer = m.disputer;
        uint256 bond = m.bond;
        address collateral = m.collateral;
        bool proposerRight = (finalOutcome == m.proposed);

        _settleOutcome(id, m, finalOutcome);

        // Bond settlement. Oracle markets have no proposer bond in escrow —
        // only the disputer's. Attested markets hold both.
        if (proposer != address(0)) {
            // Attested: 2 * bond in escrow.
            address winner = proposerRight ? proposer : disputer;
            IERC20(collateral).safeTransfer(winner, bond * 2);
        } else {
            // Oracle: only the disputer's bond in escrow.
            if (proposerRight) {
                // Oracle upheld — disputer forfeits to the treasury.
                if (treasury != address(0)) {
                    IERC20(collateral).safeTransfer(treasury, bond);
                }
            } else {
                // Oracle overturned — disputer refunded.
                IERC20(collateral).safeTransfer(disputer, bond);
            }
        }
    }

    // -------------------------------------------------------------- payouts

    /// @notice Winners withdraw their pro-rata share of the pot. O(1) per user.
    function claim(uint256 id) external nonReentrant {
        Market storage m = _markets[id];
        if (m.status != Status.Finalized) revert BadStatus();
        if (m.outcome != Outcome.Yes && m.outcome != Outcome.No) {
            revert NotInvalid();
        }
        if (claimed[id][msg.sender]) revert AlreadyClaimed();

        uint256 s = m.outcome == Outcome.Yes ? stakeYes[id][msg.sender] : stakeNo[id][msg.sender];
        if (s == 0) revert NothingToClaim();

        claimed[id][msg.sender] = true;
        uint256 amount = (s * m.payoutPool) / m.winnerPool;
        IERC20(m.collateral).safeTransfer(msg.sender, amount);
        emit Claimed(id, msg.sender, amount);
    }

    /// @notice Reclaim principal on a voided (Invalid) market — nobody wins, both
    ///         sides get their stake back.
    function refund(uint256 id) external nonReentrant {
        Market storage m = _markets[id];
        if (m.status != Status.Finalized) revert BadStatus();
        if (m.outcome != Outcome.Invalid) revert NotInvalid();
        if (claimed[id][msg.sender]) revert AlreadyClaimed();

        uint256 s = stakeYes[id][msg.sender] + stakeNo[id][msg.sender];
        if (s == 0) revert NothingToClaim();

        claimed[id][msg.sender] = true;
        IERC20(m.collateral).safeTransfer(msg.sender, s);
        emit Refunded(id, msg.sender, s);
    }

    // ----------------------------------------------------------------- views

    function getMarket(uint256 id) external view returns (Market memory) {
        return _markets[id];
    }

    /// @notice Implied YES probability, 1e18-scaled, from the current pools —
    ///         the "price" the UI shows (parimutuel odds). 0.5e18 before any stake.
    function impliedYes1e18(uint256 id) external view returns (uint256) {
        Market storage m = _markets[id];
        uint256 total = uint256(m.poolYes) + uint256(m.poolNo);
        if (total == 0) return 0.5e18;
        return (uint256(m.poolYes) * 1e18) / total;
    }

    // ------------------------------------------------------------- internal

    function _compare(uint256 value, uint256 threshold, Comparator c) internal pure returns (Outcome) {
        if (c == Comparator.GreaterOrEqual) {
            return value >= threshold ? Outcome.Yes : Outcome.No;
        }
        return value < threshold ? Outcome.Yes : Outcome.No;
    }

    function _recordProposal(uint256 id, Market storage m, Outcome o, address proposer) internal {
        m.proposed = o;
        m.status = Status.Proposed;
        uint64 until = uint64(block.timestamp) + m.disputeWindow;
        m.disputeUntil = until;
        emit Proposed(id, proposer, o, until);
    }

    /// @dev Locks the outcome and snapshots the parimutuel split. If the winning
    ///      side is empty, the market voids to Invalid (refund path), no fee taken.
    function _settleOutcome(uint256 id, Market storage m, Outcome o) internal {
        m.status = Status.Finalized;

        if (o == Outcome.Invalid) {
            m.outcome = Outcome.Invalid;
            emit Resolved(id, Outcome.Invalid, 0, 0);
            return;
        }

        uint256 winner = o == Outcome.Yes ? m.poolYes : m.poolNo;
        uint256 loser = o == Outcome.Yes ? m.poolNo : m.poolYes;

        if (winner == 0) {
            // No winners to pay — void so everyone reclaims principal.
            m.outcome = Outcome.Invalid;
            emit Resolved(id, Outcome.Invalid, 0, 0);
            return;
        }

        uint256 fee = (loser * protocolFeeBps) / 10_000;
        uint256 payout = winner + (loser - fee);

        m.outcome = o;
        m.winnerPool = winner;
        m.payoutPool = payout;

        if (fee > 0 && treasury != address(0)) {
            IERC20(m.collateral).safeTransfer(treasury, fee);
        }
        emit Resolved(id, o, winner, payout);
    }
}
