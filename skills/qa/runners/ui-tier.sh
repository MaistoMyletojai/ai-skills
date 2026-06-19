#!/usr/bin/env bash
# ui-tier.sh — runs Playwright UI tests for Dserve.Admin for one ticket.
#
# Lifecycle:
#   1. Verify port $QA_ADMIN_PORT is free (fail fast if dev is on :5030
#      but accidentally configured to use ours).
#   2. Start Dserve.Admin via `dotnet run` on $QA_ADMIN_PORT, in background.
#   3. Poll until the app responds (or timeout).
#   4. Run the login helper spec once → writes $QA_ADMIN_STATE_FILE.
#   5. Run all *.spec.ts in the supplied directory with JSON reporter.
#   6. Kill the Admin app + cleanup.
#
# Usage: ui-tier.sh <playwright-spec-dir>
# Reads env: QA_REPO_ROOT, QA_OUT_DIR, QA_ADMIN_PORT (def 5080),
#            QA_ADMIN_EMAIL, QA_ADMIN_PASSWORD, BOT_GIT_NAME/EMAIL (from rig)
# Produces:
#   $QA_OUT_DIR/ui-results.json   — Playwright JSON reporter output
#   $QA_OUT_DIR/admin-start.log   — dotnet run stdout
#   $QA_OUT_DIR/admin-state.json  — Playwright storageState (auth cookies)
#   $QA_OUT_DIR/screenshots/*     — failure screenshots (if any)
# Exits:
#   0 — all UI tests passed
#   1 — one or more UI tests failed
#   2 — Admin app failed to start
#   3 — login failed
#   4 — Playwright not installed
#   >4 — runner error

set -uo pipefail

SPEC_DIR="${1:-}"
if [ -z "$SPEC_DIR" ] || [ ! -d "$SPEC_DIR" ]; then
  echo "usage: $0 <playwright-spec-dir>" >&2
  exit 64
fi

: "${QA_REPO_ROOT:?must be set to the dserve-backend QA worktree}"
: "${QA_OUT_DIR:?must be set}"
: "${QA_ADMIN_EMAIL:?must be set}"
: "${QA_ADMIN_PASSWORD:?must be set}"
QA_ADMIN_PORT="${QA_ADMIN_PORT:-5080}"
QA_ADMIN_URL="http://localhost:${QA_ADMIN_PORT}"
QA_ADMIN_STATE_FILE="$QA_OUT_DIR/admin-state.json"

mkdir -p "$QA_OUT_DIR/screenshots"

# 0. Verify Playwright is installed (in $QA_REPO_ROOT/qa-agent/playwright or globally)
if ! command -v npx >/dev/null; then
  echo "✗ npx not found — install Node first" >&2
  exit 4
fi

# Determine where to run playwright from. Prefer the qa-agent's own
# playwright install at ~/dserve-qa-skill-data/playwright-runtime/
# (created by the deploy script). Falls back to repo root.
RUNTIME_DIR="${QA_PLAYWRIGHT_RUNTIME:-$HOME/dserve-qa-skill-data/playwright-runtime}"
if [ ! -d "$RUNTIME_DIR/node_modules/@playwright/test" ]; then
  echo "✗ Playwright runtime not found at $RUNTIME_DIR" >&2
  echo "  Run: $QA_AGENT_ROOT/runners/install-playwright.sh" >&2
  exit 4
fi

# 1. Port check.
if lsof -nP -iTCP:"$QA_ADMIN_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "✗ port $QA_ADMIN_PORT is in use — cannot start QA's Admin instance" >&2
  echo "  another process is listening; aborting to avoid colliding with dev work" >&2
  exit 5
fi

ADMIN_PROJECT="$QA_REPO_ROOT/Dserve.Admin/Dserve.Admin.csproj"
if [ ! -f "$ADMIN_PROJECT" ]; then
  echo "✗ Dserve.Admin not found at $ADMIN_PROJECT" >&2
  exit 5
fi

# 1b. Verify .NET 8 ASP.NET Core shared framework is installed.
#     Dserve.Admin targets net8.0; without the 8.x shared framework the
#     app fails to start with a cryptic FrameworkMissingException. Fail
#     fast with a clear install hint instead.
if ! dotnet --list-runtimes 2>/dev/null | grep -qE "^Microsoft\.AspNetCore\.App 8\."; then
  echo "✗ Microsoft.AspNetCore.App 8.x not installed — required by Dserve.Admin" >&2
  echo "  Installed runtimes:" >&2
  dotnet --list-runtimes 2>/dev/null | sed 's/^/    /' >&2
  echo "  Fix:" >&2
  echo "    brew install dotnet@8" >&2
  echo "    brew link --overwrite dotnet@8     # --force is not enough if .NET 10 is also installed" >&2
  echo "  Alternative if brew is uncooperative — Microsoft installer:" >&2
  echo "    https://dotnet.microsoft.com/download/dotnet/8.0 (pick the macOS Arm64 or x64 .pkg)" >&2
  exit 6
fi

# 1c. Source the dev profile's environmentVariables from launchSettings.
#     `dotnet run --no-launch-profile` strips these on purpose so we can
#     override the port, but Dserve.Admin/Startup.cs:79 needs the SQL
#     connection string that launchSettings provides — without sourcing
#     it explicitly, the app crashes on boot.
#
#     We skip HOSTPORT/URLS keys so our QA-port overrides win.
LAUNCH_JSON="$QA_REPO_ROOT/Dserve.Admin/Properties/launchSettings.json"
ENV_FROM_LAUNCHSETTINGS="$QA_OUT_DIR/admin-env.sh"
if [ -f "$LAUNCH_JSON" ]; then
  echo "→ extracting dev env from $LAUNCH_JSON" >&2
  python3 - "$LAUNCH_JSON" > "$ENV_FROM_LAUNCHSETTINGS" <<'PYEOF'
import json, sys, shlex
with open(sys.argv[1]) as f:
    profiles = (json.load(f) or {}).get("profiles", {}) or {}
# Prefer a profile named "Dserve.Admin"; fall back to the first non-IIS one.
profile = profiles.get("Dserve.Admin")
if profile is None:
    for n, p in profiles.items():
        if n != "IIS Express":
            profile = p
            break
if profile:
    for k, v in (profile.get("environmentVariables") or {}).items():
        if k in ("ASPNETCORE_HOSTPORT", "ASPNETCORE_URLS"):
            continue  # we override these
        print(f"export {k}={shlex.quote(str(v))}")
PYEOF
  # shellcheck disable=SC1090
  . "$ENV_FROM_LAUNCHSETTINGS"
else
  echo "⚠  $LAUNCH_JSON not found — Admin may crash for missing connection string" >&2
fi

# 2. Start Admin app.
echo "→ starting Dserve.Admin on :$QA_ADMIN_PORT" >&2
(
  cd "$QA_REPO_ROOT"
  # DOTNET_ROLL_FORWARD=LatestPatch (not Disable) — projects ship a
  # runtimeconfig pinned to the BUILT-against version (often 8.0.0),
  # but the host runtime is the latest installed patch (e.g. 8.0.25).
  # `Disable` rejects even patch deltas; `LatestPatch` keeps us on net8
  # but tolerates the common 8.0.0→8.0.x gap.
  ASPNETCORE_HOSTPORT="$QA_ADMIN_PORT" \
  ASPNETCORE_URLS="http://localhost:$QA_ADMIN_PORT" \
  ASPNETCORE_ENVIRONMENT="Development" \
  DOTNET_ROLL_FORWARD="LatestPatch" \
  dotnet run --project "$ADMIN_PROJECT" --no-launch-profile \
    > "$QA_OUT_DIR/admin-start.log" 2>&1 &
  echo $! > "$QA_OUT_DIR/admin.pid"
)
ADMIN_PID=$(cat "$QA_OUT_DIR/admin.pid")

cleanup() {
  if [ -n "${ADMIN_PID:-}" ] && kill -0 "$ADMIN_PID" 2>/dev/null; then
    echo "→ stopping Admin (pid $ADMIN_PID)" >&2
    kill "$ADMIN_PID" 2>/dev/null || true
    # Give it a sec, then SIGKILL if still alive.
    sleep 2
    kill -9 "$ADMIN_PID" 2>/dev/null || true
  fi
  rm -f "$QA_OUT_DIR/admin.pid"
}
trap cleanup EXIT INT TERM

# 3. Wait for /login to respond.
echo "→ waiting for Admin to come up (120s timeout)" >&2
deadline=$((SECONDS + 120))
until curl -s -o /dev/null -w "%{http_code}" "$QA_ADMIN_URL/login" | grep -qE "^(200|302|303|307|308)$"; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "✗ Admin failed to start within 120s — see $QA_OUT_DIR/admin-start.log" >&2
    tail -40 "$QA_OUT_DIR/admin-start.log" >&2
    exit 2
  fi
  if ! kill -0 "$ADMIN_PID" 2>/dev/null; then
    echo "✗ Admin process died — see $QA_OUT_DIR/admin-start.log" >&2
    tail -40 "$QA_OUT_DIR/admin-start.log" >&2
    exit 2
  fi
  sleep 2
done
echo "✓ Admin up" >&2

# 4. Login + save storage state.
LOGIN_SPEC="$RUNTIME_DIR/admin-login.spec.ts"
# Copy fresh from template each run so any template updates land.
cp "$QA_AGENT_ROOT/templates/admin-login.ts.tmpl" "$LOGIN_SPEC"

echo "→ logging in to Admin" >&2
(
  cd "$RUNTIME_DIR"
  QA_ADMIN_URL="$QA_ADMIN_URL" \
  QA_ADMIN_EMAIL="$QA_ADMIN_EMAIL" \
  QA_ADMIN_PASSWORD="$QA_ADMIN_PASSWORD" \
  QA_ADMIN_STATE_FILE="$QA_ADMIN_STATE_FILE" \
  npx playwright test "$LOGIN_SPEC" \
    --reporter=list \
    > "$QA_OUT_DIR/login.log" 2>&1
) || {
  echo "✗ login failed — see $QA_OUT_DIR/login.log" >&2
  tail -40 "$QA_OUT_DIR/login.log" >&2
  exit 3
}

if [ ! -s "$QA_ADMIN_STATE_FILE" ]; then
  echo "✗ login spec ran but storage state not saved at $QA_ADMIN_STATE_FILE" >&2
  exit 3
fi
echo "✓ logged in, state saved" >&2

# 5. Run the AC specs.
# PLAYWRIGHT_TEST_DIR points the runtime's config at the per-ticket spec
# directory. Without this, Playwright's testDir defaults to "." (the
# runtime) and never discovers specs at $QA_OUT_DIR/playwright/ — the
# agent would have to copy specs into the runtime, which is the bug we're
# fixing here.
# Screenshots the specs capture for visual review go here; the orchestrator
# attaches every PNG in this dir to the Trello card after the run.
QA_SHOT_DIR="$QA_OUT_DIR/screenshots"
mkdir -p "$QA_SHOT_DIR"

echo "→ running UI specs in $SPEC_DIR" >&2
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

if [ "$ui_rc" -eq 0 ]; then
  echo "✓ UI tests passed" >&2
  exit 0
fi
echo "✗ UI tests failed (rc=$ui_rc) — see $QA_OUT_DIR/ui-results.json" >&2
exit 1
