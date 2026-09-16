// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafetyModule, IGoldgardClaimsView} from "../src/liquidity/SafetyModule.sol";
import {TestStable} from "../src/tokens/TestStable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {
    BadConfig,
    OnlyHook,
    ClaimPending,
    CooldownNotPassed,
    ClaimsPaused,
    NotEligible,
    ClaimsViewNotSet,
    ClaimsViewAlreadySet,
    ClaimsViewNotReady,
    OnlyAuthorized
} from "../src/errors/SafetyModuleErrors.sol";

/// @dev Test stand-in for the hook's claims view (eligibility + payout preview).
contract StubClaimsView is IGoldgardClaimsView {
    bool public eligible = true;
    uint256 public payout;

    function setEligible(bool e) external {
        eligible = e;
    }

    function setPayout(uint256 p) external {
        payout = p;
    }

    function isEligible(address, PoolId) external view returns (bool) {
        return eligible;
    }

    function previewClaim(address, PoolId) external view returns (uint256) {
        return payout;
    }
}

contract SafetyModuleTest is Test {
    SafetyModule sm;
    TestStable asset;
    StubClaimsView view_;

    address owner = address(0xA11CE);
    address hook = address(0xC0FFEE);
    address auth = address(0xA07);
    address lp = address(0xB0B);

    PoolId constant POOL = PoolId.wrap(bytes32(uint256(1)));

    function setUp() public {
        asset = new TestStable("cNGN", "cNGN");
        sm = new SafetyModule(owner, IERC20(address(asset)), "Safety cNGN", "sfcNGN");
        view_ = new StubClaimsView();
        vm.prank(owner);
        sm.setHook(hook);
    }

    function _fundReserve(uint256 amount) internal {
        // The hook holds premium tokens and approves the vault, then deposits.
        asset.mint(hook, amount);
        vm.startPrank(hook);
        asset.approve(address(sm), amount);
        sm.depositPremium(amount);
        vm.stopPrank();
    }

    function test_DepositPremium_OnlyHook() public {
        asset.mint(lp, 1e18);
        vm.startPrank(lp);
        asset.approve(address(sm), 1e18);
        vm.expectRevert(OnlyHook.selector);
        sm.depositPremium(1e18);
        vm.stopPrank();
    }

    function test_DepositPremium_FundsReserveAndEpoch() public {
        _fundReserve(100_000e18);
        assertEq(asset.balanceOf(address(sm)), 100_000e18);
        assertEq(sm.epochPremiumIn(), 100_000e18);
    }

    function test_RequestClaim_RevertsWhenPending() public {
        vm.prank(lp);
        sm.requestClaim(POOL);
        vm.prank(lp);
        vm.expectRevert(ClaimPending.selector);
        sm.requestClaim(POOL);
    }

    function test_ExecuteClaim_HappyPath() public {
        _fundReserve(100_000e18);
        vm.prank(owner);
        sm.setClaimsView(view_);
        view_.setPayout(30_000e18);

        vm.prank(lp);
        sm.requestClaim(POOL);

        // Before cooldown → reverts.
        vm.prank(lp);
        vm.expectRevert(CooldownNotPassed.selector);
        sm.executeClaim(POOL);

        vm.warp(block.timestamp + sm.cooldownSeconds() + 1);

        vm.prank(lp);
        uint256 paid = sm.executeClaim(POOL);
        assertEq(paid, 30_000e18);
        assertEq(asset.balanceOf(lp), 30_000e18);
        assertEq(sm.epochPayoutOut(), 30_000e18);
    }

    function test_ExecuteClaim_NotEligible() public {
        _fundReserve(100_000e18);
        vm.prank(owner);
        sm.setClaimsView(view_);
        view_.setPayout(10_000e18);
        view_.setEligible(false);

        vm.prank(lp);
        sm.requestClaim(POOL);
        vm.warp(block.timestamp + sm.cooldownSeconds() + 1);

        vm.prank(lp);
        vm.expectRevert(NotEligible.selector);
        sm.executeClaim(POOL);
    }

    function test_ExecuteClaim_RevertsWhenPausedOrNoView() public {
        _fundReserve(1e18);
        // No claims view yet.
        vm.prank(lp);
        sm.requestClaim(POOL);
        vm.warp(block.timestamp + sm.cooldownSeconds() + 1);
        vm.prank(lp);
        vm.expectRevert(ClaimsViewNotSet.selector);
        sm.executeClaim(POOL);

        // Paused.
        vm.startPrank(owner);
        sm.setClaimsView(view_);
        sm.setClaimsPaused(true);
        vm.stopPrank();
        vm.prank(lp);
        vm.expectRevert(ClaimsPaused.selector);
        sm.executeClaim(POOL);
    }

    function test_OwnerSetters_AccessAndBounds() public {
        vm.prank(lp);
        vm.expectRevert(); // not owner
        sm.setCooldownSeconds(1 days);

        vm.startPrank(owner);
        vm.expectRevert(BadConfig.selector);
        sm.setCooldownSeconds(366 days); // > MAX_COOLDOWN_SECONDS
        sm.setCooldownSeconds(7 days);
        assertEq(sm.cooldownSeconds(), 7 days);

        vm.expectRevert(BadConfig.selector);
        sm.setClaimsViewChangeDelay(31 days); // > 30 days
        vm.stopPrank();
    }

    function test_SetClaimsView_OnlyOnce() public {
        vm.startPrank(owner);
        sm.setClaimsView(view_);
        vm.expectRevert(ClaimsViewAlreadySet.selector);
        sm.setClaimsView(view_);
        vm.stopPrank();
    }

    function test_ScheduleClaimsView_Timelock() public {
        StubClaimsView next = new StubClaimsView();
        vm.startPrank(owner);
        sm.setClaimsView(view_);
        sm.scheduleClaimsViewChange(next);
        vm.stopPrank();

        // Too early.
        vm.expectRevert(ClaimsViewNotReady.selector);
        sm.acceptClaimsViewChange();

        vm.warp(block.timestamp + sm.claimsViewChangeDelay() + 1);
        sm.acceptClaimsViewChange();
        assertEq(address(sm.claimsView()), address(next));
    }

    function test_EpochCheckpoint_OnlyAuthorized() public {
        vm.prank(lp);
        vm.expectRevert(OnlyAuthorized.selector);
        sm.epochCheckpoint();

        vm.prank(owner);
        sm.setAuthorizedCaller(auth);
        _fundReserve(5_000e18);

        vm.prank(auth);
        sm.epochCheckpoint();
        assertEq(sm.epochId(), 1);
        assertEq(sm.epochPremiumIn(), 0);
    }
}
