#!/usr/bin/env bash
# Arc submission deploy — Option A (small-amount live). Deploys the in-house
# paymaster (gasless) and seeds the NGN/GHS/KES corridor rates on the oracle.
#
# SAFE BY DEFAULT: this SIMULATES (no on-chain spend). To actually broadcast:
#     BROADCAST=1 bash deploy-arc-submission.sh
#
# Run from contracts/evm. Needs ~/.foundry/bin on PATH and PRIVATE_KEY in .env
# (the Arc deployer / oracle owner, 0xd441…01F1). Nothing here prints the key.
set -eu
cd "$(dirname "$0")"
export PATH="$HOME/.foundry/bin:$PATH"

# --- config you may adjust on the day -------------------------------------------
PAYMASTER_SIGNER=0xb440319eE67d10Ffce6F413e4B889D06F20BE675   # INHOUSE_PAYMASTER_PK address
PM_STAKE=300000000000000000       # 0.3 USDC reputation bond (recoverable)
PM_DEPOSIT=1000000000000000000    # 1.0 USDC sponsored-gas budget (recoverable)
ORACLE_ADDRESS=0x48484e904EA964a649D0c73666bA1E91d3Ca2349
USDC_ADDRESS=0x3600000000000000000000000000000000000000
# local-per-USD x1000 — set to the live mid-market rate on the day
RATE_NGN=1600000   # NGN 1600/USD
RATE_GHS=15500     # GHS 15.5/USD
RATE_KES=155000    # KES 155/USD
NGN=0xE76E4f347667d973a1B968733bE41738f2AE202C
GHS=0xb3387B3cCAd4ef68e0c348735daA1C306D17C004
KES=0x6616D69AcbB9fe9Ef630171C069CC069a0d8464f
RPC=https://rpc.mainnet.arc.io
# --------------------------------------------------------------------------------

# normalise PRIVATE_KEY to 0x-prefixed (vm.envUint needs it); read from evm/.env
# or contracts/.env, whichever holds it; never echoed.
RAW_PK="$(grep -h '^PRIVATE_KEY=' .env ../.env 2>/dev/null | cut -d= -f2- | tr -d '"' | grep -E '.' | head -1)"
if [ -z "$RAW_PK" ]; then echo "ERROR: PRIVATE_KEY not found in .env or ../.env" >&2; exit 1; fi
export PRIVATE_KEY="$(printf '%s' "$RAW_PK" | sed 's/^0x//;s/^/0x/')"
export ORACLE_ADDRESS USDC_ADDRESS PAYMASTER_SIGNER PM_STAKE PM_DEPOSIT

FLAGS="--rpc-url arc"
if [ "${BROADCAST:-0}" = "1" ]; then FLAGS="$FLAGS --broadcast --slow"; echo "### BROADCASTING to Arc mainnet (real funds) ###"; else echo "### DRY RUN (simulation only). Pass BROADCAST=1 to deploy for real. ###"; fi

echo; echo "== 1/4  Paymaster =="
forge script script/DeployPaymaster.s.sol $FLAGS

echo; echo "== 2/4  Corridor: Nigeria (cNGN) =="
CORRIDOR_TOKEN=$NGN RATE_PER_USD_MILLI=$RATE_NGN forge script script/DeployCorridor.s.sol $FLAGS

echo; echo "== 3/4  Corridor: Ghana (cGHS) =="
CORRIDOR_TOKEN=$GHS RATE_PER_USD_MILLI=$RATE_GHS forge script script/DeployCorridor.s.sol $FLAGS

echo; echo "== 4/4  Corridor: Kenya (cKES) =="
CORRIDOR_TOKEN=$KES RATE_PER_USD_MILLI=$RATE_KES forge script script/DeployCorridor.s.sol $FLAGS

if [ "${BROADCAST:-0}" = "1" ]; then
  echo; echo "== verify =="
  echo "NOTE: copy the 'VerifyingPaymaster:' address printed in step 1/4 into"
  echo "      NEXT_PUBLIC_INHOUSE_PAYMASTER_ADDRESS (build env). Expected at nonce 23:"
  echo "      0x7f457EA8dC5d775543Be40f68Ff01992c5dC5f85"
  echo -n "paymaster (0x7f457…) deployed: "; [ "$(cast code 0x7f457EA8dC5d775543Be40f68Ff01992c5dC5f85 --rpc-url $RPC | wc -c)" -gt 3 ] && echo yes || echo NO
  for p in "NGN $NGN" "GHS $GHS" "KES $KES"; do set -- $p; echo "USD->$1 seeded: $(cast call $ORACLE_ADDRESS 'hasData(address,address)(bool)' $USDC_ADDRESS $2 --rpc-url $RPC)"; done
  echo; echo "Next: fund your Privy smart wallet with ~1 USDC for tiny sends, and the"
  echo "agent signer 0x6eC22b2906Eb9164626A5Df9F46Ad86756025cb3 with ~0.3 USDC:"
  echo "  cast send <ADDR> --value <wei> --rpc-url arc --private-key \"\$PRIVATE_KEY\""
fi
