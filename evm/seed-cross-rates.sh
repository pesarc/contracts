#!/usr/bin/env bash
# Seed ALL 12 directional corridor rates (USD/NGN/GHS/KES) on a chain's
# RealizedRateOracle, with per-call RETRY so an RPC timeout can't leave a gap.
# Idempotent — safe to re-run. DeployArc already seeds the USD<->local pairs;
# this adds the cross pairs (NGN<->GHS, etc.) so cross-currency swaps settle.
#
# Usage (addresses come from your DeployArc output):
#   ORACLE=0x.. NGN=0x.. GHS=0x.. KES=0x.. bash seed-cross-rates.sh arc
# Optional day-of mid-rates (local per USD, x1000; must match DeployArc):
#   RATE_NGN=1600000 RATE_GHS=15500 RATE_KES=155000 ORACLE=.. NGN=.. GHS=.. KES=.. bash seed-cross-rates.sh arc
#
# PRIVATE_KEY (a recorder on the oracle; the deployer is one) is read from
# evm/.env or ../.env and never printed.
set -eu
cd "$(dirname "$0")"
export PATH="$HOME/.foundry/bin:$PATH"

CHAIN="${1:-}"
if [ -z "$CHAIN" ]; then echo "usage: ORACLE=.. NGN=.. GHS=.. KES=.. bash seed-cross-rates.sh <arbitrum|base|optimism|polygon|celo|arc>" >&2; exit 1; fi
case "$CHAIN" in
  arbitrum) USDC=0xaf88d065e77c8cC2239327C5EDb3A432268e5831; ALIAS=arbitrum ;;
  base)     USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; ALIAS=base ;;
  optimism) USDC=0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; ALIAS=optimism ;;
  polygon)  USDC=0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359; ALIAS=polygon ;;
  celo)     USDC=0xcebA9300f2b948710d2653dD7B07f33A8B32118C; ALIAS=celo ;;
  arc)      USDC=0x3600000000000000000000000000000000000000; ALIAS=arc ;;
  *) echo "ERROR: unknown chain '$CHAIN'" >&2; exit 1 ;;
esac
RPC="${RPC_URL:-$ALIAS}"

: "${ORACLE:?set ORACLE=<RealizedRateOracle address> (from the DeployArc output)}"
: "${NGN:?set NGN=<cNGN token address>}"
: "${GHS:?set GHS=<cGHS token address>}"
: "${KES:?set KES=<cKES token address>}"
export USD="$USDC" NGN GHS KES ORACLE RPC
export RATE_NGN="${RATE_NGN:-1600000}" RATE_GHS="${RATE_GHS:-15500}" RATE_KES="${RATE_KES:-155000}"

RAW_PK="$(grep -h '^PRIVATE_KEY=' .env ../.env 2>/dev/null | cut -d= -f2- | tr -d '"' | grep -E '.' | head -1)"
if [ -z "$RAW_PK" ]; then echo "ERROR: PRIVATE_KEY not found in .env or ../.env" >&2; exit 1; fi
export PRIVATE_KEY="$(printf '%s' "$RAW_PK" | sed 's/^0x//;s/^/0x/')"

echo "chain=$CHAIN  oracle=$ORACLE  rpc=$RPC"
echo "seeding 12 directional rates (NGN=$RATE_NGN GHS=$RATE_GHS KES=$RATE_KES per USD x1000)…"

python3 - <<'PY'
import os, subprocess, time
per = {"USD": 1000.0, "NGN": float(os.environ["RATE_NGN"]), "GHS": float(os.environ["RATE_GHS"]), "KES": float(os.environ["RATE_KES"])}
addr = {"USD": os.environ["USD"], "NGN": os.environ["NGN"], "GHS": os.environ["GHS"], "KES": os.environ["KES"]}
ORACLE, RPC, PK = os.environ["ORACLE"], os.environ["RPC"], os.environ["PRIVATE_KEY"]
ok = fail = 0
for a in per:
    for b in per:
        if a == b:
            continue
        rate = int((per[b] / per[a]) * 10**18)  # tokenOut per tokenIn, 1e18
        for attempt in range(1, 4):
            r = subprocess.run(
                ["cast", "send", ORACLE, "record(address,address,uint256)", addr[a], addr[b], str(rate),
                 "--rpc-url", RPC, "--private-key", PK],
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
            )
            if r.returncode == 0:
                print(f"  ok   {a}->{b}")
                ok += 1
                break
            print(f"  retry {a}->{b} (attempt {attempt}) {r.stderr.strip().splitlines()[-1] if r.stderr.strip() else ''}")
            time.sleep(3)
        else:
            print(f"  FAIL {a}->{b} after 3 attempts")
            fail += 1
print(f"\n{ok} recorded, {fail} failed")
raise SystemExit(1 if fail else 0)
PY
