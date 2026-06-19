#!/usr/bin/env bash
# eshop-tier-remote.sh — Playwright eshop tests against the DEPLOYED dev eshop.
#
# Remote-mode sibling of eshop-tier.sh: it does NOT start a local Vite server.
# It runs the specs against $QA_ESHOP_DEV_URL (e.g. https://ss-dev.dserve.app)
# using the tabletToken query-param auth. Use when the repo isn't cloned.
#
# IMPORTANT: dev reflects what is DEPLOYED. For an open, undeployed PR the
# change may not be live yet — treat an absent change as NEEDS_HUMAN, not FAIL.
#
# Usage: eshop-tier-remote.sh <playwright-spec-dir>
# Reads env: QA_OUT_DIR, QA_ESHOP_DEV_URL, QA_TABLET_TOKEN,
#            QA_PLAYWRIGHT_RUNTIME, QA_AGENT_ROOT
# Produces: $QA_OUT_DIR/eshop-results.json, screenshots/*
# Exits: 0 pass, 1 fail, 4 runtime missing, 5 config/reachability

set -uo pipefail

SPEC_DIR="${1:-}"
if [ -z "$SPEC_DIR" ] || [ ! -d "$SPEC_DIR" ]; then
  echo "usage: $0 <playwright-spec-dir>" >&2
  exit 64
fi

: "${QA_OUT_DIR:?must be set}"
: "${QA_TABLET_TOKEN:?must be set (eshop tabletToken JWT)}"
: "${QA_ESHOP_DEV_URL:?must be set (deployed eshop dev URL, e.g. https://ss-dev.dserve.app)}"
QA_ESHOP_URL="${QA_ESHOP_DEV_URL%/}"
QA_SHOT_DIR="$QA_OUT_DIR/screenshots"
mkdir -p "$QA_SHOT_DIR"

RUNTIME_DIR="${QA_PLAYWRIGHT_RUNTIME:-$HOME/dserve-qa-skill-data/playwright-runtime}"
if [ ! -d "$RUNTIME_DIR/node_modules/@playwright/test" ]; then
  echo "✗ Playwright runtime not found at $RUNTIME_DIR — run install-playwright.sh" >&2
  exit 4
fi

echo "→ remote eshop target: $QA_ESHOP_URL (no local Vite started)" >&2
code=$(curl -s -o /dev/null -w "%{http_code}" "$QA_ESHOP_URL" || echo 000)
# Any HTTP response = reachable (the eshop root may 404 without a tabletToken;
# Playwright loads ?tabletToken=… routes). Only a connection failure fails.
if [ "$code" = "000" ] || [ -z "$code" ]; then
  echo "✗ dev eshop not reachable at $QA_ESHOP_URL (no response)" >&2; exit 5
fi
echo "✓ dev eshop responding (HTTP $code)" >&2

echo "→ running eshop specs in $SPEC_DIR against dev" >&2
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
rc=$?
[ "$rc" -eq 0 ] && { echo "✓ eshop tests passed" >&2; exit 0; }
echo "✗ eshop tests failed (rc=$rc) — see $QA_OUT_DIR/eshop-results.json" >&2
exit 1
