#!/usr/bin/env bash
# orders-tier.sh — Playwright tests for orders-dashboard (the web KDS).
#
# Like eshop-tier.sh, but the KDS dashboard uses a LOGIN (email/password →
# /users/authenticate, token in localStorage) instead of tabletToken — so this
# runner also logs in once and saves storageState (like ui-tier.sh does).
#
# Lifecycle: preflight → start Vite on $QA_ORDERS_PORT → wait → login + save
# storageState → run *.spec.ts → kill Vite (guaranteed cleanup).
#
# Usage: orders-tier.sh <playwright-spec-dir>
# Reads env:
#   QA_OUT_DIR              (REQUIRED)
#   ORDERS_REPO_QA         the orders-dashboard checkout to run from (REQUIRED)
#   QA_ORDERS_EMAIL/PASSWORD  KDS login (REQUIRED)
#   QA_ORDERS_PORT         default 3000
#   QA_ORDERS_API_URL      VITE_APP_API_URL the dashboard talks to
#   QA_PLAYWRIGHT_RUNTIME, QA_AGENT_ROOT
# Produces: $QA_OUT_DIR/orders-results.json, orders-state.json, screenshots/*
# Exits: 0 pass, 1 fail, 2 Vite startup, 3 login failed, 4 runtime, 5 preflight

set -uo pipefail

SPEC_DIR="${1:-}"
if [ -z "$SPEC_DIR" ] || [ ! -d "$SPEC_DIR" ]; then
  echo "usage: $0 <playwright-spec-dir>" >&2
  exit 64
fi

: "${QA_OUT_DIR:?must be set}"
: "${ORDERS_REPO_QA:?must be set to the orders-dashboard checkout}"
: "${QA_ORDERS_EMAIL:?must be set (KDS login email)}"
: "${QA_ORDERS_PASSWORD:?must be set (KDS login password)}"
QA_ORDERS_PORT="${QA_ORDERS_PORT:-3000}"
QA_ORDERS_URL="http://localhost:${QA_ORDERS_PORT}"
QA_ORDERS_API_URL="${QA_ORDERS_API_URL:-https://ss-dev.dserve.app/api/kds}"  # KdsController base
QA_ORDERS_STATE_FILE="$QA_OUT_DIR/orders-state.json"
QA_SHOT_DIR="$QA_OUT_DIR/screenshots"
mkdir -p "$QA_SHOT_DIR"

RUNTIME_DIR="${QA_PLAYWRIGHT_RUNTIME:-$HOME/dserve-qa-skill-data/playwright-runtime}"
if [ ! -d "$RUNTIME_DIR/node_modules/@playwright/test" ]; then
  echo "✗ Playwright runtime not found at $RUNTIME_DIR — run install-playwright.sh" >&2
  exit 4
fi

# Preflight.
if lsof -nP -iTCP:"$QA_ORDERS_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "✗ port $QA_ORDERS_PORT is in use — cannot start orders-dashboard" >&2
  exit 5
fi
[ -f "$ORDERS_REPO_QA/package.json" ] || { echo "✗ orders-dashboard not at $ORDERS_REPO_QA" >&2; exit 5; }
[ -d "$ORDERS_REPO_QA/node_modules" ] || { echo "✗ $ORDERS_REPO_QA/node_modules missing — run (cd $ORDERS_REPO_QA && npm install)" >&2; exit 5; }

# Start Vite.
echo "→ starting orders-dashboard (Vite) on :$QA_ORDERS_PORT (api=$QA_ORDERS_API_URL)" >&2
(
  cd "$ORDERS_REPO_QA"
  VITE_APP_API_URL="$QA_ORDERS_API_URL" \
    npm run dev -- --port "$QA_ORDERS_PORT" \
    > "$QA_OUT_DIR/orders-start.log" 2>&1 &
  echo $! > "$QA_OUT_DIR/orders.pid"
)
ORDERS_PID=$(cat "$QA_OUT_DIR/orders.pid")

cleanup() {
  if [ -n "${ORDERS_PID:-}" ] && kill -0 "$ORDERS_PID" 2>/dev/null; then
    echo "→ stopping orders-dashboard (pid $ORDERS_PID)" >&2
    kill -- "-$(ps -o pgid= "$ORDERS_PID" 2>/dev/null | tr -d ' ')" 2>/dev/null || \
      kill "$ORDERS_PID" 2>/dev/null || true
    sleep 1; kill -9 "$ORDERS_PID" 2>/dev/null || true
  fi
  rm -f "$QA_OUT_DIR/orders.pid"
}
trap cleanup EXIT INT TERM

# Wait for it to come up.
echo "→ waiting for orders-dashboard (60s)" >&2
deadline=$((SECONDS + 60))
until curl -s -o /dev/null -w "%{http_code}" "$QA_ORDERS_URL" | grep -qE "^(200|301|302|304)$"; do
  if [ "$SECONDS" -ge "$deadline" ] || ! kill -0 "$ORDERS_PID" 2>/dev/null; then
    echo "✗ orders-dashboard failed to start — see $QA_OUT_DIR/orders-start.log" >&2
    tail -40 "$QA_OUT_DIR/orders-start.log" >&2
    exit 2
  fi
  sleep 2
done
echo "✓ orders-dashboard up" >&2

# Login + save storageState.
LOGIN_SPEC="$RUNTIME_DIR/orders-login.spec.ts"
cp "$QA_AGENT_ROOT/templates/orders-login.ts.tmpl" "$LOGIN_SPEC"
echo "→ logging in to orders-dashboard" >&2
(
  cd "$RUNTIME_DIR"
  QA_ORDERS_URL="$QA_ORDERS_URL" \
  QA_ORDERS_EMAIL="$QA_ORDERS_EMAIL" \
  QA_ORDERS_PASSWORD="$QA_ORDERS_PASSWORD" \
  QA_ORDERS_STATE_FILE="$QA_ORDERS_STATE_FILE" \
  npx playwright test "$LOGIN_SPEC" --reporter=list \
    > "$QA_OUT_DIR/orders-login.log" 2>&1
) || { echo "✗ login failed — see $QA_OUT_DIR/orders-login.log" >&2; tail -40 "$QA_OUT_DIR/orders-login.log" >&2; exit 3; }
[ -s "$QA_ORDERS_STATE_FILE" ] || { echo "✗ storageState not saved" >&2; exit 3; }
echo "✓ logged in, state saved" >&2

# Run the AC specs.
echo "→ running orders-dashboard specs in $SPEC_DIR" >&2
(
  cd "$RUNTIME_DIR"
  PLAYWRIGHT_TEST_DIR="$SPEC_DIR" \
  QA_ORDERS_URL="$QA_ORDERS_URL" \
  QA_ORDERS_STATE_FILE="$QA_ORDERS_STATE_FILE" \
  QA_SCREENSHOT_DIR="$QA_SHOT_DIR" \
  PLAYWRIGHT_HTML_REPORT="$QA_OUT_DIR/orders-html" \
  npx playwright test \
    --reporter=json \
    --output="$QA_OUT_DIR/orders-artifacts" \
    > "$QA_OUT_DIR/orders-results.json" 2> "$QA_OUT_DIR/orders-test.log"
)
rc=$?
[ "$rc" -eq 0 ] && { echo "✓ orders-dashboard tests passed" >&2; exit 0; }
echo "✗ orders-dashboard tests failed (rc=$rc) — see $QA_OUT_DIR/orders-results.json" >&2
exit 1
