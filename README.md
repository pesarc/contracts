# Pesarc · contracts

All on-chain code, public: EVM (Foundry) + SVM (Anchor). Consumed by the private
[`pesarc/app`](https://github.com/pesarc/app) monorepo via generated
ABIs/IDLs in `@pesarc/abi`.

```
evm/src/  Foundry, organised by domain:
  prediction-market/  PredictionMarket.sol
  liquidity/          IntentMatcher.sol (local-currency P2P settlement)
  agent/              AgentSessionKeys.sol (bounded agent authority)
  oracle/             RealizedRateOracle.sol (self-referential price feed)
  interfaces/         shared interfaces (IRealizedRateOracle)
  errors/             file-level custom errors, one file per domain
  mocks/              TestStable.sol (testnet faucet ERC-20)
svm/      Anchor — one program per folder, each split into
          error.rs / events.rs / state.rs / constants.rs / instructions/:
  prediction-market/  realized-rate-oracle/  spoke-gateway/
deploy/   deploy scripts + broadcast / IDL artifacts, per chain
```

Errors and interfaces live outside the contract bodies (file-level), so the
contracts read as logic and the selectors stay stable across refactors. The
Uniswap-v4 hook / liquidity-pool contracts live in the separate hook repo.

## Standards
Solidity `0.8.26`, `via_ir`, SafeERC20, ReentrancyGuard, Ownable2Step, CEI,
`uint128` caps on user amounts; the reserve-backing invariant is sacred (on-chain
supply ≤ real backing). Anchor `1.1.2` / Rust `1.89`; pin trusted program IDs as
constants; box heavy account contexts under the 4KB BPF stack; program keypairs
are git-ignored. New behavior needs a test (`forge test`, LiteSVM). Branch `dev`
→ PR → `main`.

## Build
```bash
cd evm && forge test
cd svm && anchor build && cargo test
```
