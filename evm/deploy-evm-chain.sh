#!/usr/bin/env bash
# Deploy the full Pesarc settlement stack (oracle + matcher + cNGN/cGHS/cKES +
# prediction market + seeded corridor rates) to ONE EVM chain, in one broadcast.
# This is what makes send / swap / receive / pay REAL (not demo) on that chain.
#
# SAFE BY DEFAULT: simulates (no on-chain spend). To actually broadcast:
#     BROADCAST=1 bash deploy-evm-chain.sh arbitrum
#
# Usage:
#     bash deploy-evm-chain.sh <chain>            # dry run (simulate)
#     BROADCAST=1 bash deploy-evm-chain.sh <chain>
#     RPC_URL=https://my-paid-rpc … BROADCAST=1 bash deploy-evm-chain.sh base
#
#   <chain> in: arbitrum | base | optimism | polygon | celo | arc
#
# Needs ~/.foundry/bin on PATH and PRIVATE_KEY in evm/.env or contracts/.env
# (the deployer; needs the chain's GAS token — ETH on Arb/Base/OP, POL on
# Polygon, CELO on Celo, USDC on Arc). Nothing here prints the key.
#
# Corridor mid-rates (local per USD, x1000) — override on the day for accuracy:
#     RATE_NGN=1600000 RATE_GHS=15500 RATE_KES=155000
set -eu
cd "$(dirname "$0")"
export PATH="$HOME/.foundry/bin:$PATH"

CHAIN="${1:-}"
if [ -z "$CHAIN" ]; then echo "usage: bash deploy-evm-chain.sh <arbitrum|base|optimism|polygon|celo|arc>" >&2; exit 1; fi

# --- per-chain config: real USDC (USD leg), env prefix, foundry rpc alias -------
# USDC addresses are Circle's canonical native USDC on each chain. VERIFY against
# https://developers.circle.com/stablecoins/usdc-contract-addresses before broadcast.
case "$CHAIN" in
  arbitrum) USDC=0xaf88d065e77c8cC2239327C5EDb3A432268e5831; PREFIX=ARBITRUM; ALIAS=arbitrum ;;
  base)     USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; PREFIX=BASE;     ALIAS=base ;;
  optimism) USDC=0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; PREFIX=OPTIMISM; ALIAS=optimism ;;
  polygon)  USDC=0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359; PREFIX=POLYGON;  ALIAS=polygon ;;
  celo)     USDC=0xcebA9300f2b948710d2653dD7B07f33A8B32118C; PREFIX=CELO;     ALIAS=celo ;;
  arc)      USDC=0x3600000000000000000000000000000000000000; PREFIX=ARC;      ALIAS=arc ;;
  *) echo "ERROR: unknown chain '$CHAIN'" >&2; exit 1 ;;
esac
RPC="${RPC_URL:-$ALIAS}"   # a full URL via RPC_URL overrides the foundry alias
# --------------------------------------------------------------------------------

# normalise PRIVATE_KEY to 0x-prefixed (vm.envUint needs it); read from evm/.env
# or contracts/.env, whichever holds it; never echoed.
RAW_PK="$(grep -h '^PRIVATE_KEY=' .env ../.env 2>/dev/null | cut -d= -f2- | tr -d '"' | grep -E '.' | head -1)"
if [ -z "$RAW_PK" ]; then echo "ERROR: PRIVATE_KEY not found in .env or ../.env" >&2; exit 1; fi
export PRIVATE_KEY="$(printf '%s' "$RAW_PK" | sed 's/^0x//;s/^/0x/')"
export USDC_ADDRESS="$USDC" ENV_PREFIX="$PREFIX"
export RATE_NGN="${RATE_NGN:-1600000}" RATE_GHS="${RATE_GHS:-15500}" RATE_KES="${RATE_KES:-155000}"

echo "chain=$CHAIN  prefix=$PREFIX  usdc=$USDC  rpc=$RPC"
FLAGS="--rpc-url $RPC"
if [ "${BROADCAST:-0}" = "1" ]; then
  FLAGS="$FLAGS --broadcast --slow"; echo "### BROADCASTING to $CHAIN mainnet (real gas) ###"
else
  echo "### DRY RUN (simulation only). Pass BROADCAST=1 to deploy for real. ###"
fi

echo; echo "== Deploying Pesarc settlement stack to $CHAIN =="
forge script script/DeployArc.s.sol $FLAGS

echo
echo "Next steps after a real broadcast:"
echo "  1. Copy the printed NEXT_PUBLIC_${PREFIX}_* lines into the build env (BUILD_DOTENV)."
echo "  2. Fund the deployer/agent signer with a little USDC ($PREFIX) for test sends."
echo "  3. (Optional, gasless) deploy a paymaster funded in the chain's gas token."
