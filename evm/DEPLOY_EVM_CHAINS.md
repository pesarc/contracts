# Deploy the Pesarc settlement stack to an EVM chain (make it REAL, not demo)

This turns Send / Swap / Receive / Pay from demo plumbing into **real on-chain
settlement** on a given EVM chain. One command deploys the whole stack and seeds
the corridor rates; you paste the printed env lines into the build; the frontend
picks the chain up automatically.

## What gets deployed (per chain, one broadcast)

`script/DeployArc.s.sol` is chain-agnostic. On the target chain it deploys:

- **RealizedRateOracle** — realized-rate TWAP source.
- **IntentMatcher** — the netting/settlement core (send + swap run through this).
- **cNGN / cGHS / cKES** — 18-dec local stables (TestStable until real issuers land).
- **PredictionMarket** — FX/macro market (also the flag that marks the chain "live").
- **Seeded USDC↔cXXX rates** (both directions) for all three corridors, so quotes
  and settlement work from block one instead of waiting for a first realized fill.

The **USD leg is the chain's real Circle USDC** (native predeploy on Arc; the
canonical USDC ERC-20 elsewhere).

## Prerequisites

- `~/.foundry/bin` on PATH (`forge`, `cast`).
- `PRIVATE_KEY` in `contracts/evm/.env` or `contracts/.env` (the deployer). It
  needs the chain's **gas token**: ETH on Arbitrum/Base/Optimism, POL on Polygon,
  CELO on Celo, USDC on Arc. It never gets printed.
- A little of that gas token in the deployer wallet on the target chain.

## Deploy

Safe by default — simulates with no spend. Run from `contracts/evm`:

```bash
bash deploy-evm-chain.sh arbitrum          # dry run (simulate)
BROADCAST=1 bash deploy-evm-chain.sh arbitrum   # real broadcast
```

Chains: `arbitrum` · `base` · `optimism` · `polygon` · `celo` · `arc`.

Set live mid-rates on the day (local per USD, ×1000) — defaults are sane:

```bash
RATE_NGN=1600000 RATE_GHS=15500 RATE_KES=155000 \
  BROADCAST=1 bash deploy-evm-chain.sh base
```

Use a reliable (paid) RPC for the broadcast so a tx doesn't drop mid-run:

```bash
RPC_URL=https://arb-mainnet.g.alchemy.com/v2/<key> \
  BROADCAST=1 bash deploy-evm-chain.sh arbitrum
```

### USDC addresses used (verify before broadcast)

Circle's canonical native USDC, from
<https://developers.circle.com/stablecoins/usdc-contract-addresses>:

| Chain    | Prefix     | USDC |
|----------|------------|------|
| Arbitrum | `ARBITRUM` | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| Base     | `BASE`     | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Optimism | `OPTIMISM` | `0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85` |
| Polygon  | `POLYGON`  | `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` |
| Celo     | `CELO`     | `0xcebA9300f2b948710d2653dD7B07f33A8B32118C` |
| Arc      | `ARC`      | `0x3600000000000000000000000000000000000000` (native) |

## Wire the frontend (this is what flips demo → live)

The script prints a block like:

```
NEXT_PUBLIC_ARBITRUM_INTENT_MATCHER=0x…
NEXT_PUBLIC_ARBITRUM_REALIZED_ORACLE=0x…
NEXT_PUBLIC_ARBITRUM_PREDICTION_MARKET=0x…
NEXT_PUBLIC_ARBITRUM_TOKEN_NGN=0x…
NEXT_PUBLIC_ARBITRUM_TOKEN_GHS=0x…
NEXT_PUBLIC_ARBITRUM_TOKEN_KES=0x…
NEXT_PUBLIC_ARBITRUM_TOKEN_USD=0x…
```

The chain registry (`app/packages/sdk/src/chain/registry.ts`) already reads these
exact slots. A chain shows as **live** in the network selector once its
`NEXT_PUBLIC_<PREFIX>_PREDICTION_MARKET` is set (`configuredChains()` gates on it).

1. Add every printed line to **`BUILD_DOTENV`** (the CI build secret) — these are
   `NEXT_PUBLIC_*`, so they are baked into the client bundle at build time, not
   read at runtime on the droplet.
2. Push to `main` with a fresh commit (a rerun reuses the Docker cache and won't
   re-bake env). The next image build makes the chain live in prod.
3. Fund the deployer / agent signer with a little USDC on the chain for test sends.

## Gasless (optional, per chain)

`DeployArc` does not deploy the ERC-4337 paymaster. On Arc the paymaster is funded
in USDC (the gas token); on other chains it would be funded in that chain's native
gas token. Deploy `script/DeployPaymaster.s.sol` per chain when you want sponsored
gas there, and set `NEXT_PUBLIC_INHOUSE_PAYMASTER_ADDRESS`. Without it, sends still
work — the user just pays their own gas in the native token.

## Add a new corridor later (without redeploying)

`script/DeployCorridor.s.sol` seeds one more USDC↔cXXX pair onto an existing oracle:

```bash
ORACLE_ADDRESS=0x… USDC_ADDRESS=0x… CORRIDOR_TOKEN=0x… RATE_PER_USD_MILLI=3800000 \
  BROADCAST=1 forge script script/DeployCorridor.s.sol --rpc-url arbitrum --broadcast --slow
```
