#!/usr/bin/env bash
# cross-system-tier.sh — runs Playwright specs that drive BOTH
# Dserve.Admin and the eshop in one process, to verify Admin→eshop
# propagation (or vice versa).
#
# Lifecycle:
#   1. Preflight: Playwright runtime, .NET 8, ports :5080 and :5173 free,
#      Admin csproj, eshop node_modules + connection-string env.
#   2. Start Admin on :5080 (background) and wait.
#   3. Log in to Admin via Playwright auth helper → save storageState.
#   4. Start Vite on :5173 (background) and wait.
#   5. Run cross-system specs (which open TWO browser contexts —
#      one Admin with storageState, one eshop with tabletToken).
#   6. Kill BOTH servers on exit.
#
# Usage: cross-system-tier.sh <playwright-spec-dir>
# Reads env: same superset as ui-tier.sh + eshop-tier.sh
# Produces:
#   $QA_OUT_DIR/cross-system-results.json
#   $QA_OUT_DIR/cross-system-*.log
#   $QA_OUT_DIR/screenshots/*           (highlighted, attached to Trello)
# Exits: 0 pass, 1 fail, 2-5 setup errors (see ui-tier.sh / eshop-tier.sh)

set -uo pipefail

SPEC_DIR="${1:-}"
if [ -z "$SPEC_DIR" ] || [ ! -d "$SPEC_DIR" ]; then
  echo "usage: $0 <playwright-spec-dir>" >&2
  exit 64
fi

: "${QA_OUT_DIR:?must be set}"
: "${QA_REPO_ROOT:?must be set to the dserve-backend QA worktree}"
: "${QA_ADMIN_EMAIL:?must be set}"
: "${QA_ADMIN_PASSWORD:?must be set}"
: "${WEB_REPO_QA:?must be set to the self-service-web QA worktree}"
: "${QA_TABLET_TOKEN:?must be set (from keychain via kc.sh autodev_qa_tablet_token)}"
QA_ADMIN_PORT="${QA_ADMIN_PORT:-5080}"
QA_ADMIN_URL="http://localhost:${QA_ADMIN_PORT}"
QA_ESHOP_PORT="${QA_ESHOP_PORT:-5173}"
QA_ESHOP_URL="http://localhost:${QA_ESHOP_PORT}"
QA_VITE_API_URL="${QA_VITE_API_URL:-https://ss-dev.dserve.app/api}"
QA_ADMIN_STATE_FILE="$QA_OUT_DIR/admin-state.json"
QA_SHOT_DIR="$QA_OUT_DIR/screenshots"
RUNTIME_DIR="${QA_PLAYWRIGHT_RUNTIME:-$HOME/dserve-qa-skill-data/playwright-runtime}"

mkdir -p "$QA_SHOT_DIR"

# ───────── Preflight ─────────
if [ ! -d "$RUNTIME_DIR/node_modules/@playwright/test" ]; then
  echo "✗ Playwright runtime not found at $RUNTIME_DIR" >&2
  exit 4
fi
if ! dotnet --list-runtimes 2>/dev/null | grep -qE "^Microsoft\.AspNetCore\.App 8\."; then
  echo "✗ Microsoft.AspNetCore.App 8.x not installed — required by Dserve.Admin" >&2
  exit 6
fi
for port in "$QA_ADMIN_PORT" "$QA_ESHOP_PORT"; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "✗ port $port already in use" >&2
    exit 5
  fi
done
ADMIN_PROJECT="$QA_REPO_ROOT/Dserve.Admin/Dserve.Admin.csproj"
[ -f "$ADMIN_PROJECT" ] || { echo "✗ Dserve.Admin missing at $ADMIN_PROJECT" >&2; exit 5; }
[ -f "$WEB_REPO_QA/package.json" ] || { echo "✗ self-service-web missing at $WEB_REPO_QA" >&2; exit 5; }
[ -d "$WEB_REPO_QA/node_modules" ] || { echo "✗ $WEB_REPO_QA/node_modules missing — run npm install" >&2; exit 5; }

# ───────── Source Admin env from launchSettings (connection string) ─────────
LAUNCH_JSON="$QA_REPO_ROOT/Dserve.Admin/Properties/launchSettings.json"
if [ -f "$LAUNCH_JSON" ]; then
  python3 - "$LAUNCH_JSON" > "$QA_OUT_DIR/admin-env.sh" <<'PYEOF'
import json, sys, shlex
profiles = (json.load(open(sys.argv[1])) or {}).get("profiles", {}) or {}
profile = profiles.get("Dserve.Admin") or next(
    (p for n, p in profiles.items() if n != "IIS Express"), None)
if profile:
    for k, v in (profile.get("environmentVariables") or {}).items():
        if k in ("ASPNETCORE_HOSTPORT", "ASPNETCORE_URLS"):
            continue
        print(f"export {k}={shlex.quote(str(v))}")
PYEOF
  . "$QA_OUT_DIR/admin-env.sh"
fi

# ───────── Track PIDs for cleanup ─────────
ADMIN_PID=""
ESHOP_PID=""

cleanup() {
  if [ -n "${ESHOP_PID:-}" ] && kill -0 "$ESHOP_PID" 2>/dev/null; then
    echo "→ stopping Vite (pid $ESHOP_PID)" >&2
    kill -- "-$(ps -o pgid= "$ESHOP_PID" 2>/dev/null | tr -d ' ')" 2>/dev/null || \
      kill "$ESHOP_PID" 2>/dev/null || true
    sleep 1; kill -9 "$ESHOP_PID" 2>/dev/null || true
  fi
  if [ -n "${ADMIN_PID:-}" ] && kill -0 "$ADMIN_PID" 2>/dev/null; then
    echo "→ stopping Admin (pid $ADMIN_PID)" >&2
    kill "$ADMIN_PID" 2>/dev/null || true
    sleep 2; kill -9 "$ADMIN_PID" 2>/dev/null || true
  fi
  rm -f "$QA_OUT_DIR/admin.pid" "$QA_OUT_DIR/eshop.pid"
}
trap cleanup EXIT INT TERM

# ───────── Start Admin ─────────
echo "→ starting Dserve.Admin on :$QA_ADMIN_PORT" >&2
(
  cd "$QA_REPO_ROOT"
  ASPNETCORE_HOSTPORT="$QA_ADMIN_PORT" \
  ASPNETCORE_URLS="http://localhost:$QA_ADMIN_PORT" \
  ASPNETCORE_ENVIRONMENT="Development" \
  DOTNET_ROLL_FORWARD="LatestPatch" \
  dotnet run --project "$ADMIN_PROJECT" --no-launch-profile \
    > "$QA_OUT_DIR/admin-start.log" 2>&1 &
  echo $! > "$QA_OUT_DIR/admin.pid"
)
ADMIN_PID=$(cat "$QA_OUT_DIR/admin.pid")
echo "→ waiting for Admin (120s)" >&2
deadline=$((SECONDS + 120))
until curl -s -o /dev/null -w "%{http_code}" "$QA_ADMIN_URL/login" | grep -qE "^(200|302|303|307|308)$"; do
  if [ "$SECONDS" -ge "$deadline" ] || ! kill -0 "$ADMIN_PID" 2>/dev/null; then
    echo "✗ Admin failed to start — see $QA_OUT_DIR/admin-start.log" >&2
    tail -40 "$QA_OUT_DIR/admin-start.log" >&2
    exit 2
  fi
  sleep 2
done
echo "✓ Admin up" >&2

# ───────── Login + save storageState ─────────
LOGIN_SPEC="$RUNTIME_DIR/admin-login.spec.ts"
cp "$QA_AGENT_ROOT/templates/admin-login.ts.tmpl" "$LOGIN_SPEC"
echo "→ logging in to Admin" >&2
(
  cd "$RUNTIME_DIR"
  QA_ADMIN_URL="$QA_ADMIN_URL" \
  QA_ADMIN_EMAIL="$QA_ADMIN_EMAIL" \
  QA_ADMIN_PASSWORD="$QA_ADMIN_PASSWORD" \
  QA_ADMIN_STATE_FILE="$QA_ADMIN_STATE_FILE" \
  npx playwright test "$LOGIN_SPEC" --reporter=list \
    > "$QA_OUT_DIR/login.log" 2>&1
) || { echo "✗ Admin login failed — see $QA_OUT_DIR/login.log" >&2; exit 3; }
[ -s "$QA_ADMIN_STATE_FILE" ] || { echo "✗ storageState not saved" >&2; exit 3; }
echo "✓ logged in" >&2

# ───────── Start Vite ─────────
echo "→ starting Vite dev server on :$QA_ESHOP_PORT (api=$QA_VITE_API_URL)" >&2
(
  cd "$WEB_REPO_QA"
  VITE_APP_API_URL="$QA_VITE_API_URL" \
    npm run dev -- --port "$QA_ESHOP_PORT" \
    > "$QA_OUT_DIR/eshop-start.log" 2>&1 &
  echo $! > "$QA_OUT_DIR/eshop.pid"
)
ESHOP_PID=$(cat "$QA_OUT_DIR/eshop.pid")
echo "→ waiting for Vite (60s)" >&2
deadline=$((SECONDS + 60))
until curl -s -o /dev/null -w "%{http_code}" "$QA_ESHOP_URL" | grep -qE "^(200|301|302|304)$"; do
  if [ "$SECONDS" -ge "$deadline" ] || ! kill -0 "$ESHOP_PID" 2>/dev/null; then
    echo "✗ Vite failed to start — see $QA_OUT_DIR/eshop-start.log" >&2
    tail -40 "$QA_OUT_DIR/eshop-start.log" >&2
    exit 2
  fi
  sleep 2
done
echo "✓ Vite up" >&2

# ───────── Run cross-system specs ─────────
echo "→ running cross-system specs in $SPEC_DIR" >&2
(
  cd "$RUNTIME_DIR"
  PLAYWRIGHT_TEST_DIR="$SPEC_DIR" \
  QA_ADMIN_URL="$QA_ADMIN_URL" \
  QA_ADMIN_STATE_FILE="$QA_ADMIN_STATE_FILE" \
  QA_ESHOP_URL="$QA_ESHOP_URL" \
  QA_TABLET_TOKEN="$QA_TABLET_TOKEN" \
  QA_SCREENSHOT_DIR="$QA_SHOT_DIR" \
  PLAYWRIGHT_HTML_REPORT="$QA_OUT_DIR/cross-system-html" \
  npx playwright test \
    --reporter=json \
    --output="$QA_OUT_DIR/cross-system-artifacts" \
    > "$QA_OUT_DIR/cross-system-results.json" 2> "$QA_OUT_DIR/cross-system-test.log"
)
rc=$?

if [ "$rc" -eq 0 ]; then
  echo "✓ cross-system tests passed" >&2
  exit 0
fi
echo "✗ cross-system tests failed (rc=$rc) — see $QA_OUT_DIR/cross-system-results.json" >&2
exit 1
