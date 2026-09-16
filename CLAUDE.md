# Pesarc contracts — architecture guide

On-chain code for the Pesarc settlement network: EVM (Foundry) + SVM (Anchor).
Consumed by the private `pesarc/app` monorepo via hand-maintained ABIs/IDLs in
`@pesarc/abi`.

## Repository structure (industry-standard, domain-first)

Contracts are grouped by **domain**, with cross-cutting concerns (interfaces,
errors, test tokens) in their own folders — the layout auditors and Foundry
users expect.

```
evm/
  src/
    prediction-market/  PredictionMarket.sol        — parimutuel hedge markets
    settlement/         IntentMatcher.sol            — local-currency P2P settlement
    liquidity/          GoldgardHook.sol (v4 hook), HedgeReserve, SafetyModule,
                        RewardDistributor, OracleAdapter
                        libraries/  BaseHook, Transient
                        interfaces/ IChainlinkAggregatorV3
    agent/              AgentSessionKeys.sol          — bounded agent authority
    oracle/             RealizedRateOracle.sol        — self-referential TWAP feed
    interfaces/         shared interfaces (IRealizedRateOracle)
    errors/             file-level custom errors, one file per contract
    tokens/             TestStable.sol (testnet local-currency stables)
  test/                 Foundry tests, one *.t.sol per contract
  script/               deploy scripts
  lib/                  vendored deps: forge-std, openzeppelin-contracts,
                        v4-core, solmate
svm/
  programs/<program>/   Anchor program per folder, each split into
                        error.rs / events.rs / state.rs / constants.rs /
                        instructions/<one file per instruction> / lib.rs
    prediction-market/  realized-rate-oracle/  spoke-gateway/
deploy/                 deploy manifests / IDL artifacts, per chain
```

### Size (source only, excludes `lib/`)

| Area | LoC | Notes |
|---|---|---|
| EVM src total | ~2,785 | across 23 files |
| · liquidity (v4 hub) | ~1,602 | GoldgardHook is the bulk (~900) |
| · prediction-market | ~444 | |
| · settlement | ~305 | |
| · oracle | ~165 | |
| · agent | ~131 | |
| · errors / interfaces / tokens | ~138 | |
| EVM tests | ~880 | 41 tests, 6 suites, all passing |
| SVM programs | ~2,796 | 3 Anchor programs + LiteSVM tests |

## Architectural patterns

- **Parimutuel prediction market** — no order book, no counterparty risk. Each
  side pools stakes; the winning side splits the pot, fee only on the losing
  pool. Empty-side or void → full refund.
- **Self-referential oracle** — `RealizedRateOracle` derives a TWAP from our own
  settled flow (fed by `IntentMatcher` as `recorder`), not an external USD feed.
  Markets can resolve from it (`Source.Oracle`) or from a bonded attestor with a
  dispute window (`Source.Attested`, UMA-style).
- **Uniswap-v4 hook hub** — `GoldgardHook` runs liquidity provision with hedge
  offset (`HedgeReserve`), an ERC-4626 insurance vault (`SafetyModule`), and
  ERC-6909 rewards (`RewardDistributor`). `OracleAdapter` fuses pool TWAP with a
  Chainlink-style feed and guards against spot/oracle deviation.
- **Bounded agent authority** — `AgentSessionKeys` gives an AI agent a scoped key
  with a spend cap, expiry, and target allowlist; `execute` can never touch the
  metered token (no cap bypass).
- **File-level custom errors** — every contract's errors live in
  `errors/<Contract>Errors.sol` and are imported, keeping bodies logic-only and
  selectors stable across refactors.

## Upgradeability pattern — **immutable, non-upgradeable**

There are **no proxies** (no UUPS/Transparent, no `Initializable`, no `__gap`,
no `delegatecall` upgrade path). Contracts deploy with a constructor and are
immutable code. This is deliberate:

- **Admin, not code, is mutable.** Owner-tunable parameters go through
  `Ownable2Step` setters (fees, oracle address, cooldowns, deviation caps,
  claims view behind a timelock). This covers the parameters that legitimately
  change without making logic mutable.
- **Migration = redeploy + repoint.** A logic change ships as a new deployment;
  the app repoints its address env and (where relevant) balances/positions are
  migrated. There is no storage-layout risk and no proxy admin to compromise.

**Trade-off / when to revisit:** immutability maximizes auditability and removes
proxy attack surface, at the cost of not being able to hot-patch a live
contract. If beta needs in-place upgrades of the market or hub, the standard
move is **UUPS (ERC-1967) with `Ownable2Step` + a timelock on `upgradeToAndCall`**,
which keeps the same admin model. Until that's an explicit requirement, we stay
immutable.

## House standards

Solidity `0.8.26`, `via_ir`, optimizer 200. `SafeERC20`, `ReentrancyGuard`,
`Ownable2Step`, checks-effects-interactions on every external transfer,
`uint128` caps on user amounts. The reserve-backing invariant (on-chain supply ≤
real backing) is sacred. Anchor `1.1.2` / Rust `1.89`; pin trusted program IDs
as constants; program keypairs are git-ignored. New behaviour needs a test
(`forge test`, LiteSVM). CI runs `forge fmt --check`, `forge build`, `forge test`
(+ `cargo fmt`/`cargo test`). Branch `dev` → PR → `main`.

## Build

```bash
cd evm && forge test
cd svm && anchor build && cargo test
```
