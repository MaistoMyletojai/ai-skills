#!/usr/bin/env bash
# ui-tier-remote.sh — Playwright Admin tests against the DEPLOYED dev server.
#
# Remote-mode sibling of ui-tier.sh: it does NOT build or start Dserve.Admin
# locally. It logs in to $QA_ADMIN_DEV_URL and runs the specs there. Use when
# the repos aren't cloned locally.
#
# IMPORTANT: the dev server reflects what is DEPLOYED (usually master). For an
# open, undeployed PR the feature under test may not be present yet — treat an
# absent feature as NEEDS_HUMAN ("PR not deployed to dev"), not FAIL.
#
# Usage: ui-tier-remote.sh <playwright-spec-dir>
# Reads env: QA_OUT_DIR, QA_ADMIN_DEV_URL, QA_ADMIN_EMAIL, QA_ADMIN_PASSWORD,
#            QA_PLAYWRIGHT_RUNTIME, QA_AGENT_ROOT
# Produces: $QA_OUT_DIR/ui-results.json, admin-state.json, screenshots/*
# Exits: 0 pass, 1 fail, 3 login failed, 4 Playwright/runtime missing, 5 config

set -uo pipefail

SPEC_DIR="${1:-}"
if [ -z "$SPEC_DIR" ] || [ ! -d "$SPEC_DIR" ]; then
  echo "usage: $0 <playwright-spec-dir>" >&2
  exit 64
fi

: "${QA_OUT_DIR:?must be set}"
: "${QA_ADMIN_EMAIL:?must be set}"
: "${QA_ADMIN_PASSWORD:?must be set}"
: "${QA_ADMIN_DEV_URL:?must be set (the deployed Blazor Admin dev URL, e.g. https://admin-dev.dserve.app)}"
QA_ADMIN_URL="${QA_ADMIN_DEV_URL%/}"
QA_ADMIN_STATE_FILE="$QA_OUT_DIR/admin-state.json"
QA_SHOT_DIR="$QA_OUT_DIR/screenshots"
mkdir -p "$QA_SHOT_DIR"

RUNTIME_DIR="${QA_PLAYWRIGHT_RUNTIME:-$HOME/dserve-qa-skill-data/playwright-runtime}"
if [ ! -d "$RUNTIME_DIR/node_modules/@playwright/test" ]; then
  echo "✗ Playwright runtime not found at $RUNTIME_DIR — run install-playwright.sh" >&2
  exit 4
fi
command -v npx >/dev/null || { echo "✗ npx not found — install Node" >&2; exit 4; }

echo "→ remote Admin target: $QA_ADMIN_URL (no local server started)" >&2

# Reachability check (don't start anything — just confirm dev is up).
code=$(curl -s -o /dev/null -w "%{http_code}" "$QA_ADMIN_URL/login" || echo 000)
# Any HTTP response means the server is reachable (a 404/redirect at a path is
# fine — Playwright navigates the real routes). Only a connection failure fails.
if [ "$code" = "000" ] || [ -z "$code" ]; then
  echo "✗ dev Admin not reachable at $QA_ADMIN_URL/login (no response)" >&2; exit 5
fi
echo "✓ dev Admin responding (HTTP $code)" >&2

# Login against the dev server → save storageState.
LOGIN_SPEC="$RUNTIME_DIR/admin-login.spec.ts"
cp "$QA_AGENT_ROOT/templates/admin-login.ts.tmpl" "$LOGIN_SPEC"
echo "→ logging in to dev Admin" >&2
(
  cd "$RUNTIME_DIR"
  QA_ADMIN_URL="$QA_ADMIN_URL" \
  QA_ADMIN_EMAIL="$QA_ADMIN_EMAIL" \
  QA_ADMIN_PASSWORD="$QA_ADMIN_PASSWORD" \
  QA_ADMIN_STATE_FILE="$QA_ADMIN_STATE_FILE" \
  npx playwright test "$LOGIN_SPEC" --reporter=list \
    > "$QA_OUT_DIR/login.log" 2>&1
) || { echo "✗ login failed — see $QA_OUT_DIR/login.log" >&2; tail -40 "$QA_OUT_DIR/login.log" >&2; exit 3; }
[ -s "$QA_ADMIN_STATE_FILE" ] || { echo "✗ storageState not saved" >&2; exit 3; }
echo "✓ logged in, state saved" >&2

# Run the AC specs against dev.
echo "→ running UI specs in $SPEC_DIR against dev" >&2
(
  cd "$RUNTIME_DIR"
  PLAYWRIGHT_TEST_DIR="$SPEC_DIR" \
  QA_ADMIN_URL="$QA_ADMIN_URL" \
  QA_ADMIN_STATE_FILE="$QA_ADMIN_STATE_FILE" \
  QA_SCREENSHOT_DIR="$QA_SHOT_DIR" \
  PLAYWRIGHT_HTML_REPORT="$QA_OUT_DIR/playwright-html" \
  npx playwright test \
    --reporter=json \
    --output="$QA_OUT_DIR/playwright-artifacts" \
    > "$QA_OUT_DIR/ui-results.json" 2> "$QA_OUT_DIR/ui-test.log"
)
ui_rc=$?
[ "$ui_rc" -eq 0 ] && { echo "✓ UI tests passed" >&2; exit 0; }
echo "✗ UI tests failed (rc=$ui_rc) — see $QA_OUT_DIR/ui-results.json" >&2
exit 1
