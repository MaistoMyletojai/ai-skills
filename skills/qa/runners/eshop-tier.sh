#!/usr/bin/env bash
# eshop-tier.sh — runs Playwright UI tests for self-service-web (the eshop).
#
# Lifecycle:
#   1. Preflight: Playwright runtime installed, port free, repo present,
#      node_modules present.
#   2. Start Vite dev server (`npm run dev -- --port $QA_ESHOP_PORT`) with
#      VITE_APP_API_URL pointed at ss-dev.dserve.app (overrideable).
#   3. Poll until http://localhost:$QA_ESHOP_PORT responds.
#   4. Run all *.spec.ts in the supplied directory with JSON reporter.
#   5. Kill the Vite server + cleanup.
#
# Usage: eshop-tier.sh <playwright-spec-dir>
# Reads env:
#   QA_OUT_DIR              — per-ticket output dir (REQUIRED)
#   WEB_REPO_QA             — self-service-web checkout to run from (REQUIRED)
#   QA_TABLET_TOKEN         — JWT for eshop auth (REQUIRED, from keychain)
#   QA_ESHOP_PORT           — default 5173
#   QA_VITE_API_URL         — default https://ss-dev.dserve.app/api
#   QA_PLAYWRIGHT_RUNTIME   — default ~/dserve-qa-skill-data/playwright-runtime
# Produces:
#   $QA_OUT_DIR/eshop-results.json   — Playwright JSON reporter
#   $QA_OUT_DIR/eshop-start.log      — Vite stdout
#   $QA_OUT_DIR/eshop-test.log       — Playwright stderr
#   $QA_OUT_DIR/screenshots/*        — highlighted per-AC screenshots
# Exits:
#   0 — all UI tests passed
#   1 — one or more failed
#   2 — Vite failed to start
#   4 — Playwright runtime not installed
#   5 — preflight error (port, repo, node_modules)

set -uo pipefail

SPEC_DIR="${1:-}"
if [ -z "$SPEC_DIR" ] || [ ! -d "$SPEC_DIR" ]; then
  echo "usage: $0 <playwright-spec-dir>" >&2
  exit 64
fi

: "${QA_OUT_DIR:?must be set}"
: "${WEB_REPO_QA:?must be set to the self-service-web QA worktree}"
: "${QA_TABLET_TOKEN:?must be set (load from keychain via kc.sh autodev_qa_tablet_token)}"
QA_ESHOP_PORT="${QA_ESHOP_PORT:-5173}"
QA_ESHOP_URL="http://localhost:${QA_ESHOP_PORT}"
QA_VITE_API_URL="${QA_VITE_API_URL:-https://ss-dev.dserve.app/api}"

mkdir -p "$QA_OUT_DIR/screenshots"

# 0. Playwright runtime check.
RUNTIME_DIR="${QA_PLAYWRIGHT_RUNTIME:-$HOME/dserve-qa-skill-data/playwright-runtime}"
if [ ! -d "$RUNTIME_DIR/node_modules/@playwright/test" ]; then
  echo "✗ Playwright runtime not found at $RUNTIME_DIR" >&2
  echo "  Run: $QA_AGENT_ROOT/runners/install-playwright.sh" >&2
  exit 4
fi

# 1. Port check.
if lsof -nP -iTCP:"$QA_ESHOP_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "✗ port $QA_ESHOP_PORT is in use — cannot start QA's Vite dev server" >&2
  echo "  another process is listening; aborting to avoid colliding with dev work" >&2
  exit 5
fi

# 2. Repo + node_modules present.
if [ ! -f "$WEB_REPO_QA/package.json" ]; then
  echo "✗ self-service-web not found at $WEB_REPO_QA" >&2
  exit 5
fi
if [ ! -d "$WEB_REPO_QA/node_modules" ]; then
  echo "✗ $WEB_REPO_QA/node_modules missing" >&2
  echo "  Run: (cd $WEB_REPO_QA && npm install --prefer-offline)" >&2
  exit 5
fi

# 3. Start Vite dev server.
echo "→ starting Vite dev server on :$QA_ESHOP_PORT (api=$QA_VITE_API_URL)" >&2
(
  cd "$WEB_REPO_QA"
  VITE_APP_API_URL="$QA_VITE_API_URL" \
    npm run dev -- --port "$QA_ESHOP_PORT" \
    > "$QA_OUT_DIR/eshop-start.log" 2>&1 &
  echo $! > "$QA_OUT_DIR/eshop.pid"
)
ESHOP_PID=$(cat "$QA_OUT_DIR/eshop.pid")

cleanup() {
  if [ -n "${ESHOP_PID:-}" ] && kill -0 "$ESHOP_PID" 2>/dev/null; then
    echo "→ stopping Vite (pid $ESHOP_PID)" >&2
    # Vite forks worker processes; nuke the process group.
    kill -- "-$(ps -o pgid= "$ESHOP_PID" | tr -d ' ')" 2>/dev/null || \
      kill "$ESHOP_PID" 2>/dev/null || true
    sleep 1
    kill -9 "$ESHOP_PID" 2>/dev/null || true
  fi
  rm -f "$QA_OUT_DIR/eshop.pid"
}
trap cleanup EXIT INT TERM

# 4. Wait for Vite to respond.
echo "→ waiting for eshop to come up (60s timeout)" >&2
deadline=$((SECONDS + 60))
until curl -s -o /dev/null -w "%{http_code}" "$QA_ESHOP_URL" | grep -qE "^(200|301|302|304)$"; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "✗ Vite failed to start within 60s — see $QA_OUT_DIR/eshop-start.log" >&2
    tail -40 "$QA_OUT_DIR/eshop-start.log" >&2
    exit 2
  fi
  if ! kill -0 "$ESHOP_PID" 2>/dev/null; then
    echo "✗ Vite process died — see $QA_OUT_DIR/eshop-start.log" >&2
    tail -40 "$QA_OUT_DIR/eshop-start.log" >&2
    exit 2
  fi
  sleep 2
done
echo "✓ Vite up" >&2

# 5. Run AC specs.
# PLAYWRIGHT_TEST_DIR points the runtime's config at the per-ticket spec dir
# (same env-driven trick as ui-tier.sh).
QA_SHOT_DIR="$QA_OUT_DIR/screenshots"
mkdir -p "$QA_SHOT_DIR"

echo "→ running eshop specs in $SPEC_DIR" >&2
(
  cd "$RUNTIME_DIR"
  PLAYWRIGHT_TEST_DIR="$SPEC_DIR" \
  QA_ESHOP_URL="$QA_ESHOP_URL" \
  QA_TABLET_TOKEN="$QA_TABLET_TOKEN" \
  QA_SCREENSHOT_DIR="$QA_SHOT_DIR" \
  PLAYWRIGHT_HTML_REPORT="$QA_OUT_DIR/eshop-html" \
  npx playwright test \
    --reporter=json \
    --output="$QA_OUT_DIR/eshop-artifacts" \
    > "$QA_OUT_DIR/eshop-results.json" 2> "$QA_OUT_DIR/eshop-test.log"
)
ui_rc=$?

if [ "$ui_rc" -eq 0 ]; then
  echo "✓ eshop tests passed" >&2
  exit 0
fi
echo "✗ eshop tests failed (rc=$ui_rc) — see $QA_OUT_DIR/eshop-results.json" >&2
exit 1
