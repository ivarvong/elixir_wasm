#!/usr/bin/env bash
#
# One-command deploy for pyex.ivar.workers.dev — keeps the wasm's TWO homes in sync:
#   R2 (browsers fetch /pyex.wasm at runtime)  and  worker/pyex.wasm (bundled module
#   binding for /api/run — workerd forbids runtime WebAssembly.compile).
#
#   ./deploy.sh [path/to/pyex.wasm]     # default: ../../../pyex/wasm/pyex.wasm
#
# Ends by validating PRODUCTION: /api/health, the mobile-UX rig, and the lru example.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WASM="${1:-$HERE/../../../pyex/wasm/pyex.wasm}"
[ -f "$WASM" ] || { echo "no wasm at $WASM — build one with \`mix wasm.build\` in pyex"; exit 1; }

# content-addressed cache-buster: same bytes -> same URL -> immutable cache stays valid
V="$(shasum -a 256 "$WASM" | cut -c1-12)"
echo "==> deploying pyex.wasm $V ($(du -h "$WASM" | cut -f1))"

cp "$WASM" "$HERE/worker/pyex.wasm"
(cd "$HERE/worker" && npx wrangler r2 object put pyex-wasm/pyex.wasm --file "$WASM" --remote)
(cd "$HERE/app" && VITE_WASM_V="$V" npm run build)
(cd "$HERE/worker" && npx wrangler deploy)

echo "==> validating production"
curl -sf https://pyex.ivar.workers.dev/api/health | grep -q '"ok":true' && echo "api/health: ok"
(cd "$HERE/app" && PYEX_URL=https://pyex.ivar.workers.dev/ npm run check:mobile)
(cd "$HERE/app" && PYEX_URL=https://pyex.ivar.workers.dev/ node scripts/lru-check.mjs)
echo "==> deployed + validated: https://pyex.ivar.workers.dev"
