// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @title CorridorVault
/// @notice An ERC-4626 vault that supplies settlement liquidity. Users (LPs)
///         deposit the asset (USDC) and receive shares. The protocol's authorized
///         `operator` (the solver) borrows idle inventory to act as a counterparty
///         for users whose transfer intents have no natural match, and repays with
///         the captured FX spread. That spread is the yield; the vault keeps a 10%
///         performance fee (with loss-carryforward so fees only apply to net new
///         profit). Frontend stays "deposit / earn"; this is the real on-chain LP
///         underneath.
/// @dev    Trust model (v1): the operator is a trusted protocol role that must
///         voluntarily repay borrowed inventory; risk is bounded by `maxDeployBps`
///         (a hard cap on how much of TVL can be out at once) which also preserves
///         a withdrawal buffer. A future version replaces the trust with an atomic
///         on-chain settlement path (IntentMatcher) so funds never leave custody
///         unbacked. Deposits/withdrawals are standard ERC-4626.
contract CorridorVault is ERC4626, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 internal constant BPS = 10_000;
    /// @notice Performance fee ceiling (20%), so the owner can never set it higher.
    uint256 public constant MAX_PERFORMANCE_FEE_BPS = 2_000;

    /// @notice The solver allowed to borrow/repay settlement inventory.
    address public operator;
    /// @notice Where performance-fee shares are minted.
    address public feeRecipient;
    /// @notice Performance fee on net profit, in bps (default 10%).
    uint256 public performanceFeeBps;
    /// @notice Max share of total assets that may be deployed at once, in bps.
    uint256 public maxDeployBps;

    /// @notice Principal currently out with the operator as settlement inventory.
    uint256 public deployed;
    /// @notice Unrecouped losses; profit first repays this before any fee applies.
    uint256 public lossCarry;

    event OperatorSet(address indexed operator);
    event FeeRecipientSet(address indexed feeRecipient);
    event PerformanceFeeSet(uint256 bps);
    event MaxDeploySet(uint256 bps);
    event Borrowed(uint256 amount, uint256 deployed);
    event Repaid(uint256 principal, uint256 profit, uint256 feeShares);
    event LossReported(uint256 principal, uint256 loss);

    error NotOperator();
    error ZeroAddress();
    error ZeroAmount();
    error FeeTooHigh();
    error BpsTooHigh();
    error ExceedsDeployCap();
    error ExceedsDeployed();

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
        maxDeployBps = 8_000; // keep a 20% idle buffer for withdrawals
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
        performanceFeeBps = bps;
        emit PerformanceFeeSet(bps);
    }

    function setMaxDeployBps(uint256 bps) external onlyOwner {
        if (bps > BPS) revert BpsTooHigh();
        maxDeployBps = bps;
        emit MaxDeploySet(bps);
    }

    /* ---------------- accounting ---------------- */

    /// @notice Idle asset in the vault plus principal out with the operator.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + deployed;
    }

    /// @notice Idle asset available for withdrawals right now.
    function idle() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    // Withdrawals can only draw on idle balance (deployed inventory isn't liquid).
    function maxWithdraw(address owner_) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner_), idle());
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        uint256 shares = super.maxRedeem(owner_);
        uint256 idleShares = _convertToShares(idle(), Math.Rounding.Floor);
        return Math.min(shares, idleShares);
    }

    // Stronger inflation-attack protection than the default (USDC has 6 decimals).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /* ---------------- operator (settlement inventory) ---------------- */

    /// @notice Borrow idle inventory to act as a settlement counterparty. Bounded
    ///         by `maxDeployBps` so a withdrawal buffer always remains.
    function borrow(uint256 amount) external onlyOperator nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 cap = (totalAssets() * maxDeployBps) / BPS;
        if (deployed + amount > cap) revert ExceedsDeployCap();
        deployed += amount;
        IERC20(asset()).safeTransfer(operator, amount);
        emit Borrowed(amount, deployed);
    }

    /// @notice Repay borrowed principal plus realized `profit`. The operator must
    ///         have approved `principal + profit` to this vault. Net profit (after
    ///         clearing any loss carry) is charged the performance fee, minted as
    ///         shares to the fee recipient.
    function repay(uint256 principal, uint256 profit) external onlyOperator nonReentrant {
        if (principal == 0 && profit == 0) revert ZeroAmount();
        if (principal > deployed) revert ExceedsDeployed();
        IERC20(asset()).safeTransferFrom(operator, address(this), principal + profit);
        deployed -= principal;

        uint256 feeShares;
        if (profit > 0) {
            uint256 net = profit;
            if (lossCarry >= net) {
                lossCarry -= net;
                net = 0;
            } else if (lossCarry > 0) {
                net -= lossCarry;
                lossCarry = 0;
            }
            if (net > 0 && performanceFeeBps > 0) {
                uint256 feeAssets = (net * performanceFeeBps) / BPS;
                // Convert with the profit already in totalAssets; exclude the fee
                // itself from the base so dilution is exact.
                feeShares = feeAssets.mulDiv(
                    totalSupply() + 10 ** _decimalsOffset(),
                    totalAssets() - feeAssets + 1,
                    Math.Rounding.Floor
                );
                if (feeShares > 0) _mint(feeRecipient, feeShares);
            }
        }
        emit Repaid(principal, profit, feeShares);
    }

    /// @notice Report a settlement loss: repay `principal - loss`, and carry the
    ///         loss forward so future profit isn't fee-charged until it recovers.
    function reportLoss(uint256 principal, uint256 loss) external onlyOperator nonReentrant {
        if (principal == 0) revert ZeroAmount();
        if (principal > deployed) revert ExceedsDeployed();
        if (loss > principal) revert ZeroAmount();
        IERC20(asset()).safeTransferFrom(operator, address(this), principal - loss);
        deployed -= principal;
        lossCarry += loss;
        emit LossReported(principal, loss);
    }
}
