#!/usr/bin/env bash
# Assert every src/**/*.sol basename appears in README.md and a Mermaid graph fence exists.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
README="$ROOT/README.md"
SRC="$ROOT/src"

if [[ ! -f "$README" ]]; then
  echo "FAIL: README.md missing at $README" >&2
  exit 1
fi

missing=0
count=0
while IFS= read -r sol; do
  base="$(basename "$sol")"
  count=$((count + 1))
  if ! grep -Fq "$base" "$README"; then
    echo "FAIL: README.md does not mention $base (from $sol)" >&2
    missing=$((missing + 1))
  else
    echo "OK: $base"
  fi
done < <(find "$SRC" -name '*.sol' | sort)

if ! grep -Eq '^```mermaid' "$README"; then
  echo "FAIL: README.md has no Mermaid fenced block (\`\`\`mermaid)" >&2
  missing=$((missing + 1))
else
  echo "OK: Mermaid graph fence present"
fi

# Core modules must have a purpose sentence and a function table header nearby.
for core in ZenoIndexVault Vault NavCalculation SwapExecutor AccessMaster VaultMath UniswapV4Adapter; do
  if ! grep -Eq "### .*${core}\\.sol" "$README"; then
    echo "FAIL: missing section heading for ${core}.sol" >&2
    missing=$((missing + 1))
    continue
  fi
  if ! awk -v c="$core" '
    $0 ~ ("### .*" c "\\.sol") { insec=1; next }
    insec && /^### / { exit }
    insec && /\*\*What it does:\*\*/ { purpose=1 }
    insec && /^\| Function \|/ { table=1 }
    END { exit !(purpose && table) }
  ' "$README"; then
    echo "FAIL: ${core}.sol section missing purpose and/or function table" >&2
    missing=$((missing + 1))
  else
    echo "OK: ${core}.sol has purpose + function table"
  fi
done

# Dependency callouts must match real imports/calls in core modules (not just names).
section_has() {
  local core="$1"
  shift
  local hay
  hay="$(awk -v c="$core" '
    $0 ~ ("### .*" c "\\.sol") { insec=1; next }
    insec && /^### / { exit }
    insec { print }
  ' "$README")"
  local n
  for n in "$@"; do
    if ! grep -Fq "$n" <<<"$hay"; then
      echo "FAIL: ${core}.sol section missing dependency callout: $n" >&2
      return 1
    fi
  done
  return 0
}

if ! section_has NavCalculation "IZenoIndexVault.usdcToken" "getAsset" "ERC20Minimal.balanceOf" "IPriceOracle.quoteUsdc" "USDC legs valued 1:1"; then
  missing=$((missing + 1))
elif grep -Fq "non-USDC legs valued 1:1" "$README"; then
  echo "FAIL: NavCalculation.sumNav callout still inverts USDC vs non-USDC valuation" >&2
  missing=$((missing + 1))
else
  echo "OK: NavCalculation.sumNav deps match src (USDC 1:1, non-USDC via quoteUsdc)"
fi

if section_has ZenoIndexVault "Clones.clone" "IVault(clone).init" "ISwapModAdmin" "Constants.MAX_ASSETS"; then
  echo "OK: ZenoIndexVault deps match createVault/setSwapRouter path"
else
  missing=$((missing + 1))
fi

if section_has Vault "VaultMath.computeSharesToMint" "ShareToken.mint" "NavCalculation.sumNav" "ISwapExecutorLike.executeSwap" "ReentrancyGuard"; then
  echo "OK: Vault deps match deposit/NAV/swap path"
else
  missing=$((missing + 1))
fi

if section_has SwapExecutor "ISwapRouter(router).swap"; then
  echo "OK: SwapExecutor deps match executeSwap → ISwapRouter"
else
  missing=$((missing + 1))
fi

if section_has AccessMaster "AccessControl" "setSuperAdmin" "addOperator" "removeOperator" "OPERATOR_ROLE"; then
  echo "OK: AccessMaster deps match OpenZeppelin AccessControl usage"
else
  missing=$((missing + 1))
fi

if section_has VaultMath "Constants.BPS_DENOM" "Constants.PRICE_SCALE"; then
  echo "OK: VaultMath deps match Constants usage"
else
  missing=$((missing + 1))
fi

if section_has UniswapV4Adapter "IPoolManager" "poolManager.unlock" "poolManager.swap" "TickMath"; then
  echo "OK: UniswapV4Adapter deps match v4-core path"
else
  missing=$((missing + 1))
fi

echo "Checked $count src Solidity files against README.md"
if [[ "$missing" -ne 0 ]]; then
  echo "FAIL: $missing check(s) failed" >&2
  exit 1
fi
echo "PASS: README documents all src files and includes Mermaid graph"
