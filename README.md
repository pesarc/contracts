# StableArc · contracts

All on-chain code, public: EVM (Foundry) + SVM (Anchor). Consumed by the private
[`stablearc/app`](https://github.com/stablearc/app) monorepo via generated
ABIs/IDLs in `@stablearc/abi`.

```
evm/      Foundry — IntentMatcher, RealizedRateOracle, PredictionMarket,
          SettlementNetting, TokenizedEquity (RWA), hub hook + spoke
svm/      Anchor  — realized-rate-oracle, prediction-market, spoke-gateway
deploy/   deploy scripts + broadcast / IDL artifacts, per chain
```

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
