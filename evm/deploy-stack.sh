#!/usr/bin/env bash
# One command to deploy the whole Pesarc stack on a chain: the settlement +
# market stack (oracle, IntentMatcher, PredictionMarket, cNGN/cGHS/cKES, seeded
# corridor rates) AND the Earn CorridorVault — plus the Aave strategy adapter on
# chains that have Aave V3.
#
# Usage:
#   RPC=<rpc-url> PK=<deployer-key> USDC=<usdc-address> ENV_PREFIX=<ARC|BASE|...> \
#     ./deploy-stack.sh
#
# Optional (adds the Aave strategy — Base/Arbitrum/Optimism/Polygon/Ethereum):
#   AAVE_POOL=<pool> AAVE_ATOKEN=<aToken for USDC>
#
# Skips:
#   SKIP_STACK=1   only deploy the vault (stack already live)
#   SKIP_VAULT=1   only deploy the stack
#
# Mainnet: pass the mainnet RPC. You run mainnet broadcasts; testnet is fine to
# run directly.
set -euo pipefail

: "${RPC:?set RPC}"; : "${PK:?set PK (deployer private key)}"; : "${USDC:?set USDC address}"
ENV_PREFIX="${ENV_PREFIX:-ARC}"
OPERATOR="${VAULT_OPERATOR:-}"
FEE="${FEE_RECIPIENT:-}"

echo "== Deploying to $RPC (prefix $ENV_PREFIX) =="

if [ "${SKIP_STACK:-0}" != "1" ]; then
  echo "-- 1/3 settlement + market stack (DeployArc) --"
  ENV_PREFIX="$ENV_PREFIX" USDC_ADDRESS="$USDC" \
    forge script script/DeployArc.s.sol --rpc-url "$RPC" --private-key "$PK" --broadcast
fi

if [ "${SKIP_VAULT:-0}" != "1" ]; then
  echo "-- 2/3 Earn CorridorVault --"
  VAULT_ASSET="$USDC" ${OPERATOR:+VAULT_OPERATOR=$OPERATOR} ${FEE:+FEE_RECIPIENT=$FEE} \
    forge script script/DeployCorridorVault.s.sol --rpc-url "$RPC" --private-key "$PK" --broadcast
fi

if [ -n "${AAVE_POOL:-}" ] && [ -n "${AAVE_ATOKEN:-}" ] && [ -n "${VAULT_ADDRESS:-}" ]; then
  echo "-- 3/3 Aave V3 strategy adapter --"
  VAULT_ASSET="$USDC" AAVE_POOL="$AAVE_POOL" AAVE_ATOKEN="$AAVE_ATOKEN" VAULT_ADDRESS="$VAULT_ADDRESS" \
    forge script script/DeployAaveAdapter.s.sol --rpc-url "$RPC" --private-key "$PK" --broadcast
  echo "   Then, as the vault owner: vault.addStrategy(<adapter>)"
else
  echo "-- 3/3 Aave adapter skipped (set AAVE_POOL + AAVE_ATOKEN + VAULT_ADDRESS to add it) --"
fi

echo "== Done. Addresses are printed above and in broadcast/*/run-latest.json =="
