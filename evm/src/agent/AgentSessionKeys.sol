// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {
    NoSession,
    Expired,
    CapExceeded,
    WrongToken,
    TargetNotAllowed,
    BadParam,
    CallFailed
} from "../errors/AgentSessionKeysErrors.sol";

/// @title Pesarc Agent Session Keys
/// @notice Bounded authority for an AI agent. The owner (a user's smart wallet)
///         grants a **session key** that may act on their behalf only within
///         hard limits: a per-token **spend cap**, an **expiry**, and an
///         **allowlist** of contracts it may call. The agent never holds the
///         owner's full wallet — it holds a scoped key that this contract
///         enforces on-chain.
///
///         This is the trust spine of the "agentic" layer: the LLM decides
///         off-chain, but every money-moving action is checked here against
///         caps the user set. Spending is metered exactly (ERC-20 amounts, via
///         the owner's pre-approval to this contract); non-payment actions
///         (e.g. resolve/quote) go through an allowlisted `execute`.
/// @dev    Money rules: SafeERC20, ReentrancyGuard, Ownable2Step, CEI. The owner
///         must `approve` this contract for the tokens an agent may spend.
contract AgentSessionKeys is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Session {
        address token; // the ERC-20 the key may spend (the local stable)
        uint128 cap; // max cumulative amount spendable
        uint128 spent; // cumulative spent so far
        uint64 expiry; // unix time after which the key is dead
        bool active;
    }

    /// @notice agent key => its session.
    mapping(address => Session) public sessions;
    /// @notice agent key => target contract => allowed to `execute` against it.
    mapping(address => mapping(address => bool)) public allowedTarget;

    event SessionGranted(address indexed key, address token, uint128 cap, uint64 expiry);
    event SessionRevoked(address indexed key);
    event TargetAllowed(address indexed key, address indexed target, bool allowed);
    event AgentSpent(address indexed key, address indexed to, uint256 amount, uint128 remaining);
    event AgentExecuted(address indexed key, address indexed target, bytes4 selector);

    constructor(address _owner) Ownable(_owner) {}

    // ------------------------------------------------------------- admin (owner)

    /// @notice Grant or re-grant a session key with a fresh cap + expiry.
    function grantSession(address key, address token, uint128 cap, uint64 expiry) external onlyOwner {
        if (key == address(0) || token == address(0)) revert BadParam();
        if (expiry <= block.timestamp || cap == 0) revert BadParam();
        sessions[key] = Session({token: token, cap: cap, spent: 0, expiry: expiry, active: true});
        emit SessionGranted(key, token, cap, expiry);
    }

    /// @notice Kill a session key immediately.
    function revokeSession(address key) external onlyOwner {
        sessions[key].active = false;
        emit SessionRevoked(key);
    }

    /// @notice Allow/disallow a session key to `execute` against a target contract.
    function setAllowedTarget(address key, address target, bool ok) external onlyOwner {
        allowedTarget[key][target] = ok;
        emit TargetAllowed(key, target, ok);
    }

    // ------------------------------------------------------------- agent actions

    /// @notice Agent (msg.sender = its session key) spends `amount` of the
    ///         session token from the owner to `to`, within the cap. Uses the
    ///         owner's approval to this contract; metered exactly.
    function pay(address to, uint256 amount) external nonReentrant {
        Session storage s = _live(msg.sender);
        if (to == address(0) || amount == 0) revert BadParam();
        uint256 next = uint256(s.spent) + amount;
        if (next > s.cap) revert CapExceeded();

        s.spent = uint128(next); // effects before interaction (CEI)
        IERC20(s.token).safeTransferFrom(owner(), to, amount);
        emit AgentSpent(msg.sender, to, amount, s.cap - s.spent);
    }

    /// @notice Agent calls an allowlisted target with arbitrary calldata (no value
    ///         moved by this path — for resolve/quote/hedge-open style actions).
    ///         The call executes from THIS contract's context; grant target
    ///         permissions narrowly.
    function execute(address target, bytes calldata data) external nonReentrant returns (bytes memory out) {
        Session storage s = _live(msg.sender);
        if (!allowedTarget[msg.sender][target]) revert TargetNotAllowed();
        // Defense-in-depth: `execute` must never call the metered token. This
        // contract holds the owner's ERC-20 approval, so an allowlisted token
        // target could `transferFrom(owner, …)` and bypass the spend cap. All
        // token movement must go through `pay`, which meters against the cap.
        if (target == s.token) revert TargetNotAllowed();
        bool ok;
        (ok, out) = target.call(data);
        if (!ok) revert CallFailed();
        bytes4 selector = data.length >= 4 ? bytes4(data[:4]) : bytes4(0);
        emit AgentExecuted(msg.sender, target, selector);
    }

    // ------------------------------------------------------------------- views

    /// @notice Remaining spendable amount for a key (0 if dead/expired).
    function remaining(address key) external view returns (uint256) {
        Session memory s = sessions[key];
        if (!s.active || block.timestamp >= s.expiry) return 0;
        return s.cap - s.spent;
    }

    // ------------------------------------------------------------------ internal

    function _live(address key) internal view returns (Session storage s) {
        s = sessions[key];
        if (!s.active) revert NoSession();
        if (block.timestamp >= s.expiry) revert Expired();
    }
}
