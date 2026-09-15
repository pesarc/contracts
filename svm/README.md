# SVM (Anchor)

One Anchor workspace for every Solana program:
- `programs/realized-rate-oracle` (from Goldgard/solana)
- `programs/prediction-market` (from luberty/solana)
- `programs/spoke-gateway` (from luberty/solana)

Because they share a workspace, the prediction-market ↔ oracle CPI is local —
no cross-repo `.so` path. `anchor build` produces `target/deploy/*.so` +
`target/idl/*.json`; the IDLs are synced into `@pesarc/abi` in the app repo.
Program keypairs stay git-ignored.
