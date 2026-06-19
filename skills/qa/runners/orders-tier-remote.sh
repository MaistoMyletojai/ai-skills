#!/usr/bin/env bash
# orders-tier-remote.sh — Playwright tests for orders-dashboard (KDS) against
# the DEPLOYED dev dashboard. Remote-mode sibling of orders-tier.sh: no local
# Vite start; logs in at $QA_ORDERS_DEV_URL and runs the specs there.
#
# IMPORTANT: dev reflects what is DEPLOYED. For an open, undeployed PR the
# change may not be live yet — treat an absent change as NEEDS_HUMAN, not FAIL.
#
# Usage: orders-tier-remote.sh <playwright-spec-dir>
# Reads env: QA_OUT_DIR, QA_ORDERS_DEV_URL, QA_ORDERS_EMAIL, QA_ORDERS_PASSWORD,
#            QA_PLAYWRIGHT_RUNTIME, QA_AGENT_ROOT
# Produces: $QA_OUT_DIR/orders-results.json, orders-state.json, screenshots/*
# Exits: 0 pass, 1 fail, 3 login failed, 4 runtime, 5 reachability/config

set -uo pipefail

SPEC_DIR="${1:-}"
if [ -z "$SPEC_DIR" ] || [ ! -d "$SPEC_DIR" ]; then
  echo "usage: $0 <playwright-spec-dir>" >&2
  exit 64
fi

: "${QA_OUT_DIR:?must be set}"
: "${QA_ORDERS_EMAIL:?must be set (KDS login email)}"
: "${QA_ORDERS_PASSWORD:?must be set (KDS login password)}"
: "${QA_ORDERS_DEV_URL:?must be set (deployed orders-dashboard dev URL)}"
QA_ORDERS_URL="${QA_ORDERS_DEV_URL%/}"
QA_ORDERS_STATE_FILE="$QA_OUT_DIR/orders-state.json"
QA_SHOT_DIR="$QA_OUT_DIR/screenshots"
mkdir -p "$QA_SHOT_DIR"

RUNTIME_DIR="${QA_PLAYWRIGHT_RUNTIME:-$HOME/dserve-qa-skill-data/playwright-runtime}"
if [ ! -d "$RUNTIME_DIR/node_modules/@playwright/test" ]; then
  echo "✗ Playwright runtime not found at $RUNTIME_DIR — run install-playwright.sh" >&2
  exit 4
fi

echo "→ remote orders-dashboard target: $QA_ORDERS_URL (no local Vite)" >&2
code=$(curl -s -o /dev/null -w "%{http_code}" "$QA_ORDERS_URL" || echo 000)
# Any HTTP response = reachable; only a connection failure fails.
if [ "$code" = "000" ] || [ -z "$code" ]; then
  echo "✗ dev orders-dashboard not reachable at $QA_ORDERS_URL (no response)" >&2; exit 5
fi
echo "✓ dev orders-dashboard responding (HTTP $code)" >&2

# Login + save storageState.
LOGIN_SPEC="$RUNTIME_DIR/orders-login.spec.ts"
cp "$QA_AGENT_ROOT/templates/orders-login.ts.tmpl" "$LOGIN_SPEC"
echo "→ logging in to dev orders-dashboard" >&2
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

echo "→ running orders-dashboard specs in $SPEC_DIR against dev" >&2
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
