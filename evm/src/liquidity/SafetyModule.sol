// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {
    BadConfig,
    OnlyHook,
    OnlyReactiveCallbackProxy,
    OnlyAuthorized,
    ClaimPending,
    CooldownNotPassed,
    ClaimsPaused,
    NotEligible,
    ZeroPayout,
    ClaimsViewAlreadySet,
    ClaimsViewNotSet,
    NoPendingClaimsView,
    ClaimsViewNotReady
} from "../errors/SafetyModuleErrors.sol";

import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";

import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Read-only claim surface implemented by the hook.
interface IGoldgardClaimsView {
    function isEligible(address account, PoolId poolId) external view returns (bool);
    function previewClaim(address account, PoolId poolId) external view returns (uint256 payoutAssets);
}

/// @title Goldgard Safety Module
/// @notice ERC-4626 reserve that accumulates swap-funded insurance premiums and
///         pays LP claims after cooldown and eligibility checks succeed.
contract SafetyModule is ERC4626, Ownable2Step {
    using SafeERC20 for IERC20;

    uint64 public constant DEFAULT_COOLDOWN_SECONDS = 14 days;
    uint64 public constant MAX_COOLDOWN_SECONDS = 365 days;

    address public hook;
    IGoldgardClaimsView public claimsView;
    IGoldgardClaimsView public pendingClaimsView;

    bool public claimsPaused;
    uint64 public cooldownSeconds;
    uint64 public claimsViewChangeDelay;
    uint64 public pendingClaimsViewValidAt;

    event ClaimsPausedSet(bool paused);
    event CooldownSecondsSet(uint64 cooldownSeconds);
    event ClaimsViewDelaySet(uint64 delaySeconds);
    event ClaimsViewChangeScheduled(address indexed pending, uint64 validAt);
    event ClaimsViewChanged(address indexed claimsView);
    event ClaimPaid(address indexed lp, uint256 amount, uint256 reservePostBalance);
    event ClaimPaidForPool(address indexed lp, PoolId indexed poolId, uint256 amount, uint256 reservePostBalance);
    event EpochCheckpointed(
        uint64 indexed epochId, uint64 epochStartedAt, uint64 epochEndedAt, uint256 premiumIn, uint256 payoutOut
    );
    event ReactiveCallbackProxySet(address indexed proxy);
    event AuthorizedCallerSet(address indexed caller);

    mapping(address => mapping(PoolId => uint64)) public claimRequestedAt;

    address public reactiveCallbackProxy;
    address public authorizedCaller;
    uint64 public epochId;
    uint64 public epochStartedAt;
    uint256 public epochPremiumIn;
    uint256 public epochPayoutOut;

    constructor(address _owner, IERC20 _asset, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(_asset)
        Ownable(_owner)
    {
        cooldownSeconds = DEFAULT_COOLDOWN_SECONDS;
        claimsViewChangeDelay = 2 days;
        epochStartedAt = uint64(block.timestamp);
    }

    modifier onlyReactiveCallbackProxy() {
        if (msg.sender != reactiveCallbackProxy) revert OnlyReactiveCallbackProxy();
        _;
    }

    modifier onlyAuthorized() {
        if (msg.sender != authorizedCaller) revert OnlyAuthorized();
        _;
    }

    /// @notice Sets the hook allowed to deposit premiums into the reserve.
    function setHook(address _hook) external onlyOwner {
        hook = _hook;
    }

    /// @notice Sets the Sepolia Reactive callback proxy used for authorized control paths.
    function setReactiveCallbackProxy(address proxy) external onlyOwner {
        if (proxy == address(0)) revert BadConfig();
        if (reactiveCallbackProxy != address(0)) revert BadConfig();
        reactiveCallbackProxy = proxy;
        emit ReactiveCallbackProxySet(proxy);
    }

    /// @notice Sets the address allowed to trigger admin-like actions such as epoch checkpoints.
    function setAuthorizedCaller(address caller) external onlyOwner {
        if (caller == address(0)) revert BadConfig();
        authorizedCaller = caller;
        emit AuthorizedCallerSet(caller);
    }

    /// @notice Sets the initial claim view used to evaluate LP eligibility and payout amounts.
    function setClaimsView(IGoldgardClaimsView _claimsView) external onlyOwner {
        if (address(claimsView) != address(0)) revert ClaimsViewAlreadySet();
        claimsView = _claimsView;
        emit ClaimsViewChanged(address(_claimsView));
    }

    /// @notice Pauses or unpauses claim execution without affecting deposits.
    function setClaimsPaused(bool paused) external onlyOwner {
        claimsPaused = paused;
        emit ClaimsPausedSet(paused);
    }

    /// @notice Updates the waiting period between claim request and claim execution.
    function setCooldownSeconds(uint64 newCooldownSeconds) external onlyOwner {
        if (newCooldownSeconds > MAX_COOLDOWN_SECONDS) revert BadConfig();
        cooldownSeconds = newCooldownSeconds;
        emit CooldownSecondsSet(newCooldownSeconds);
    }

    /// @notice Sets the timelock required before a new claims view can be activated.
    function setClaimsViewChangeDelay(uint64 delaySeconds) external onlyOwner {
        if (delaySeconds > 30 days) revert BadConfig();
        claimsViewChangeDelay = delaySeconds;
        emit ClaimsViewDelaySet(delaySeconds);
    }

    /// @notice Schedules a new claims view behind a timelock.
    function scheduleClaimsViewChange(IGoldgardClaimsView _claimsView) external onlyOwner {
        if (address(claimsView) == address(0)) revert ClaimsViewNotSet();
        pendingClaimsView = _claimsView;
        pendingClaimsViewValidAt = uint64(block.timestamp) + claimsViewChangeDelay;
        emit ClaimsViewChangeScheduled(address(_claimsView), pendingClaimsViewValidAt);
    }

    /// @notice Cancels a previously scheduled claims view migration.
    function cancelClaimsViewChange() external onlyOwner {
        pendingClaimsView = IGoldgardClaimsView(address(0));
        pendingClaimsViewValidAt = 0;
    }

    /// @notice Finalizes a scheduled claims view migration once the delay has elapsed.
    function acceptClaimsViewChange() external {
        if (address(pendingClaimsView) == address(0)) revert NoPendingClaimsView();
        if (block.timestamp < pendingClaimsViewValidAt) revert ClaimsViewNotReady();
        claimsView = pendingClaimsView;
        pendingClaimsView = IGoldgardClaimsView(address(0));
        pendingClaimsViewValidAt = 0;
        emit ClaimsViewChanged(address(claimsView));
    }

    /// @notice Deposits hook-collected premiums into the ERC-4626 reserve.
    function depositPremium(uint256 amount) external returns (uint256 sharesMinted) {
        if (msg.sender != hook) revert OnlyHook();
        sharesMinted = deposit(amount, address(this));
        epochPremiumIn += amount;
    }

    /// @notice Starts the claim cooldown for a specific LP and pool.
    function requestClaim(PoolId poolId) external {
        if (claimRequestedAt[msg.sender][poolId] != 0) revert ClaimPending();
        claimRequestedAt[msg.sender][poolId] = uint64(block.timestamp);
    }

    /// @notice Pays an LP claim once cooldown and eligibility checks pass.
    /// @dev Payouts are capped by the reserve's available assets.
    function executeClaim(PoolId poolId) external returns (uint256 payoutAssets) {
        if (claimsPaused) revert ClaimsPaused();
        if (address(claimsView) == address(0)) revert ClaimsViewNotSet();
        uint64 t = claimRequestedAt[msg.sender][poolId];
        if (t == 0) revert ClaimPending();
        if (block.timestamp < uint256(t) + uint256(cooldownSeconds)) {
            revert CooldownNotPassed();
        }

        if (!claimsView.isEligible(msg.sender, poolId)) revert NotEligible();

        payoutAssets = claimsView.previewClaim(msg.sender, poolId);
        uint256 available = IERC20(asset()).balanceOf(address(this));
        if (payoutAssets > available) payoutAssets = available;
        if (payoutAssets == 0) revert ZeroPayout();

        claimRequestedAt[msg.sender][poolId] = 0;
        uint256 shares = previewWithdraw(payoutAssets);
        _withdraw(address(this), msg.sender, address(this), payoutAssets, shares);

        epochPayoutOut += payoutAssets;
        uint256 reservePostBalance = IERC20(asset()).balanceOf(address(this));
        emit ClaimPaid(msg.sender, payoutAssets, reservePostBalance);
        emit ClaimPaidForPool(msg.sender, poolId, payoutAssets, reservePostBalance);
    }

    /// @notice Closes the current accounting epoch and emits reserve inflow/outflow totals.
    function epochCheckpoint() external onlyAuthorized {
        uint64 end = uint64(block.timestamp);
        emit EpochCheckpointed(epochId, epochStartedAt, end, epochPremiumIn, epochPayoutOut);
        epochId += 1;
        epochStartedAt = end;
        epochPremiumIn = 0;
        epochPayoutOut = 0;
    }
}
