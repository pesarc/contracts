// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IStrategyAdapter} from "./IStrategyAdapter.sol";

/// @title CorridorVault
/// @notice A multi-strategy ERC-4626 vault. LPs deposit the asset (USDC) and
///         receive shares; the frontend stays "deposit / earn". Underneath, idle
///         inventory is put to work two ways:
///           1. Settlement: the protocol's `operator` (solver) borrows inventory
///              to be a counterparty for transfer intents with no natural match,
///              and repays with the captured FX spread (works on Arc — no DEX).
///           2. Strategies: idle asset is allocated to yield adapters (Aave,
///              Morpho, DEX LP) on chains where those live.
///         The vault keeps a 10% performance fee via a per-share high-water mark:
///         fees crystallize only on net new profit, so a loss must be recovered
///         before fees resume — no separate loss carry needed.
/// @dev    Trust model (v1): `operator` must repay borrowed settlement inventory,
///         and `owner` approves every strategy adapter. A hard cap (`maxDeployBps`)
///         bounds how much of TVL can be deployed at once, always leaving a
///         withdrawal buffer. Audit before mainnet.
contract CorridorVault is ERC4626, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant PRICE_UNIT = 1e18;
    uint256 public constant MAX_PERFORMANCE_FEE_BPS = 2_000;
    uint256 public constant MAX_STRATEGIES = 10;

    address public operator;
    address public feeRecipient;
    uint256 public performanceFeeBps;
    /// @notice Max share of TVL deployable at once (settlement + strategies).
    uint256 public maxDeployBps;

    /// @notice Principal out with the operator as settlement inventory.
    uint256 public deployed;
    /// @notice Per-share high-water mark (asset value of PRICE_UNIT shares).
    uint256 public highWaterMark;

    mapping(address => bool) public isStrategy;
    address[] public strategies;

    event OperatorSet(address indexed operator);
    event FeeRecipientSet(address indexed feeRecipient);
    event PerformanceFeeSet(uint256 bps);
    event MaxDeploySet(uint256 bps);
    event Borrowed(uint256 amount, uint256 deployed);
    event Repaid(uint256 principal, uint256 profit);
    event LossReported(uint256 principal, uint256 loss);
    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    event Allocated(address indexed strategy, uint256 amount);
    event Deallocated(address indexed strategy, uint256 amount);
    event FeesHarvested(uint256 feeShares, uint256 newHighWaterMark);

    error NotOperator();
    error ZeroAddress();
    error ZeroAmount();
    error FeeTooHigh();
    error BpsTooHigh();
    error BufferBreached();
    error ExceedsDeployed();
    error BadStrategy();
    error TooManyStrategies();
    error StrategyInUse();

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    constructor(IERC20 asset_, string memory name_, string memory symbol_, address initialOwner, address feeRecipient_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
        Ownable(initialOwner)
    {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        feeRecipient = feeRecipient_;
        performanceFeeBps = 1_000; // 10%
        maxDeployBps = 8_000; // keep >=20% idle for withdrawals
    }

    /* ---------------- admin ---------------- */

    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        operator = operator_;
        emit OperatorSet(operator_);
    }

    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        feeRecipient = feeRecipient_;
        emit FeeRecipientSet(feeRecipient_);
    }

    function setPerformanceFeeBps(uint256 bps) external onlyOwner {
        if (bps > MAX_PERFORMANCE_FEE_BPS) revert FeeTooHigh();
        _harvest();
        performanceFeeBps = bps;
        emit PerformanceFeeSet(bps);
    }

    function setMaxDeployBps(uint256 bps) external onlyOwner {
        if (bps > BPS) revert BpsTooHigh();
        maxDeployBps = bps;
        emit MaxDeploySet(bps);
    }

    function addStrategy(address strategy) external onlyOwner {
        if (strategy == address(0)) revert ZeroAddress();
        if (isStrategy[strategy]) revert BadStrategy();
        if (strategies.length >= MAX_STRATEGIES) revert TooManyStrategies();
        if (IStrategyAdapter(strategy).asset() != asset()) revert BadStrategy();
        isStrategy[strategy] = true;
        strategies.push(strategy);
        emit StrategyAdded(strategy);
    }

    function removeStrategy(address strategy) external onlyOwner {
        if (!isStrategy[strategy]) revert BadStrategy();
        if (IStrategyAdapter(strategy).totalAssets() != 0) revert StrategyInUse();
        isStrategy[strategy] = false;
        uint256 n = strategies.length;
        for (uint256 i; i < n; ++i) {
            if (strategies[i] == strategy) {
                strategies[i] = strategies[n - 1];
                strategies.pop();
                break;
            }
        }
        emit StrategyRemoved(strategy);
    }

    function strategyCount() external view returns (uint256) {
        return strategies.length;
    }

    /* ---------------- accounting ---------------- */

    /// @notice Idle asset + settlement inventory out + value held in strategies.
    function totalAssets() public view override returns (uint256) {
        uint256 sum = IERC20(asset()).balanceOf(address(this)) + deployed;
        uint256 n = strategies.length;
        for (uint256 i; i < n; ++i) {
            sum += IStrategyAdapter(strategies[i]).totalAssets();
        }
        return sum;
    }

    function idle() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner_), idle());
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        return Math.min(super.maxRedeem(owner_), _convertToShares(idle(), Math.Rounding.Floor));
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // Crystallize fees before shares are issued or redeemed, so depositors never
    // pay a fee on yield earned before they joined.
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        _harvest();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        _harvest();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner_) public override nonReentrant returns (uint256) {
        _harvest();
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_) public override nonReentrant returns (uint256) {
        _harvest();
        return super.redeem(shares, receiver, owner_);
    }

    /* ---------------- performance fee (high-water mark) ---------------- */

    /// @notice Crystallize the performance fee on net new profit. Permissionless
    ///         (it can only ever mint fee shares to the fee recipient).
    function harvestFees() external nonReentrant {
        _harvest();
    }

    function _harvest() internal {
        uint256 supply = totalSupply();
        if (supply == 0) return;
        uint256 price = convertToAssets(PRICE_UNIT);
        uint256 hwm = highWaterMark;
        if (hwm == 0) {
            highWaterMark = price;
            return;
        }
        if (price <= hwm) return;
        uint256 gainPerShare = price - hwm;
        uint256 totalGain = gainPerShare.mulDiv(supply, PRICE_UNIT);
        uint256 feeAssets = (totalGain * performanceFeeBps) / BPS;
        uint256 feeShares;
        if (feeAssets > 0) {
            feeShares = _convertToShares(feeAssets, Math.Rounding.Floor);
            if (feeShares > 0) _mint(feeRecipient, feeShares);
        }
        highWaterMark = convertToAssets(PRICE_UNIT);
        emit FeesHarvested(feeShares, highWaterMark);
    }

    /* ---------------- deploy buffer ---------------- */

    function _requireBuffer(uint256 amount) internal view {
        uint256 minIdle = (totalAssets() * (BPS - maxDeployBps)) / BPS;
        if (idle() < amount + minIdle) revert BufferBreached();
    }

    /* ---------------- operator: settlement inventory ---------------- */

    function borrow(uint256 amount) external onlyOperator nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _requireBuffer(amount);
        deployed += amount;
        IERC20(asset()).safeTransfer(operator, amount);
        emit Borrowed(amount, deployed);
    }

    /// @notice Repay borrowed principal plus realized `profit`. Operator must have
    ///         approved `principal + profit`. Fees accrue via the high-water mark.
    function repay(uint256 principal, uint256 profit) external onlyOperator nonReentrant {
        if (principal == 0 && profit == 0) revert ZeroAmount();
        if (principal > deployed) revert ExceedsDeployed();
        IERC20(asset()).safeTransferFrom(operator, address(this), principal + profit);
        deployed -= principal;
        emit Repaid(principal, profit);
    }

    /// @notice Report a settlement loss: repay `principal - loss`. The share price
    ///         drops below the high-water mark, so future profit isn't fee-charged
    ///         until it recovers.
    function reportLoss(uint256 principal, uint256 loss) external onlyOperator nonReentrant {
        if (principal == 0) revert ZeroAmount();
        if (principal > deployed) revert ExceedsDeployed();
        if (loss > principal) revert ZeroAmount();
        IERC20(asset()).safeTransferFrom(operator, address(this), principal - loss);
        deployed -= principal;
        emit LossReported(principal, loss);
    }

    /* ---------------- strategies ---------------- */

    /// @notice Move idle asset into an approved strategy adapter.
    function allocate(address strategy, uint256 amount) external onlyOperator nonReentrant {
        if (!isStrategy[strategy]) revert BadStrategy();
        if (amount == 0) revert ZeroAmount();
        _requireBuffer(amount);
        IERC20(asset()).forceApprove(strategy, amount);
        IStrategyAdapter(strategy).deposit(amount);
        emit Allocated(strategy, amount);
    }

    /// @notice Pull asset back from a strategy adapter into idle.
    function deallocate(address strategy, uint256 amount) external onlyOperator nonReentrant {
        if (!isStrategy[strategy]) revert BadStrategy();
        if (amount == 0) revert ZeroAmount();
        IStrategyAdapter(strategy).withdraw(amount);
        emit Deallocated(strategy, amount);
    }
}
