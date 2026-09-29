# Pesarc on Solana (SVM) — devnet live, mainnet cutover plan

Pesarc's Solana side is the **spoke** in the hub-and-spoke model: a user burns
native USDC on Solana over CCTP V2, and the transfer lands on the **Arbitrum
hub** (`HubBridgeReceiver`), credited as hub USD or auto-converted to a local
stable. Three Anchor programs:

| Program | Program ID | Role |
|---|---|---|
| `realized_rate_oracle` | `4NUdEu7crxzR1AtHhaiMLk4q1ctTvhZLREq7Pbt9KNkK` | Realized-rate TWAP (resolution spine) |
| `prediction_market` | `2aMC2CKjqwxmLrS6dv98c6pVYEKogRXxEuz3NZpzv8CZ` | FX/macro market (stake/claim) |
| `spoke_gateway` | `Gi1uEn2LbSm8xM9LXpyZ5ZSbiqhLsqQ7ntgM33pbT2Ki` | Non-custodial CCTP V2 send → hub |

## Devnet — LIVE

All three are deployed on **devnet** with the deployer
(`GdpfUUSqFjjWxnkdHrprcFax2cpHNss3rEfNjKWp25H9`) as upgrade authority, upgraded to
current source, and the singletons initialized:

- `realized_rate_oracle` — config PDA initialized, deployer authorized as recorder.
- `prediction_market` — config PDA initialized (treasury = deployer, 1% fee).
- `spoke_gateway` — pinned to devnet CCTP V2 + devnet USDC, routing to the Arb
  **Sepolia** hub (`0xe715…Fa1a`).

Re-run the idempotent bootstrap any time:

```bash
NODE_PATH=/Users/Apple/Code/pesarc/app/node_modules \
  node contracts/svm/scripts/bootstrap-devnet.cjs
```

### Wire the frontend to devnet

Add to the build env (`BUILD_DOTENV`). `NEXT_PUBLIC_SVM_REALIZED_ORACLE` is the
only gap today (it defaults empty):

```
NEXT_PUBLIC_SVM_CLUSTER=devnet
NEXT_PUBLIC_SVM_REALIZED_ORACLE=4NUdEu7crxzR1AtHhaiMLk4q1ctTvhZLREq7Pbt9KNkK
NEXT_PUBLIC_SVM_PREDICTION_MARKET=2aMC2CKjqwxmLrS6dv98c6pVYEKogRXxEuz3NZpzv8CZ
# Gasless (optional): a relayer co-signs + submits so users pay 0 SOL.
NEXT_PUBLIC_SVM_FEE_PAYER=<relayer pubkey>
SVM_FEE_PAYER_SECRET=<relayer secret key JSON array, server-only>
```

For gasless: `solana-keygen new -o relayer.json`, fund it with a little devnet
SOL (`solana airdrop 2 <pubkey> --url devnet`), put its pubkey in
`NEXT_PUBLIC_SVM_FEE_PAYER` and the secret array in `SVM_FEE_PAYER_SECRET`
(read only by `/api/svm/sponsor`, never `NEXT_PUBLIC_`).

## Mainnet-beta — cutover plan (gated on the Arbitrum-mainnet hub)

Solana is a spoke, so **mainnet Solana settlement requires the Pesarc hub on
Arbitrum mainnet first** — the `spoke_gateway` can only route to a hub that
exists. Order matters:

1. **Deploy the Arbitrum-mainnet hub.** Deploy the settlement stack
   (`deploy-evm-chain.sh arbitrum`) AND the `HubBridgeReceiver` on Arbitrum
   mainnet. Record its address.
2. **Update `spoke_gateway` constants** (`programs/spoke-gateway/src/lib.rs`) for
   mainnet, then rebuild:
   - `HUB_RECEIVER_EVM` → the Arbitrum-mainnet `HubBridgeReceiver` (20 bytes).
   - `USDC_MINT` → Solana mainnet USDC `EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v`.
   - `HUB_DOMAIN` stays `3` (Arbitrum is CCTP domain 3 on mainnet too).
   - CCTP V2 program IDs — the source notes they are the same on mainnet-beta;
     verify against Circle's docs before broadcast.
3. **Deploy to mainnet-beta.** Add a `[programs.mainnet]` block to `Anchor.toml`
   (the program keypairs in `target/deploy/*-keypair.json` give the same IDs
   across clusters — reuse them), fund the deployer with mainnet SOL (~5–9 SOL
   for a fresh deploy of all three; less if only the gateway is new), then:
   ```bash
   anchor deploy --provider.cluster mainnet
   NODE_PATH=…/app/node_modules SVM_RPC_URL=https://api.mainnet-beta.solana.com \
     node contracts/svm/scripts/bootstrap-devnet.cjs   # inits the singletons
   ```
   Use a paid mainnet RPC (Helius/Triton) — the public endpoint rate-limits deploys.
4. **Fund a mainnet fee-payer relayer** (real SOL) for gasless, set
   `NEXT_PUBLIC_SVM_FEE_PAYER` + `SVM_FEE_PAYER_SECRET`.
5. **Flip the frontend:** `NEXT_PUBLIC_SVM_CLUSTER=mainnet-beta` + the mainnet
   program ids (same as devnet if keypairs reused) + oracle + fee payer.

Until step 1 is done, keep Solana on **devnet** in production and label it as
such — it is a real, non-custodial, working flow, just not mainnet value yet.
