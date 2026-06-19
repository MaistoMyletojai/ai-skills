#!/usr/bin/env bash
# api-tier.sh — runs Dserve.SelfService.Integration QaScratch tests for one ticket.
#
# Usage: api-tier.sh <ticket>
# Reads env: QA_REPO_ROOT, QA_OUT_DIR
# Produces:
#   $QA_OUT_DIR/api-results.trx        — xUnit trx XML (per-test verdicts)
#   $QA_OUT_DIR/api-build.log          — dotnet build output
#   $QA_OUT_DIR/api-test.log           — dotnet test stdout/stderr
# Exits:
#   0 — all scratch tests passed
#   1 — one or more scratch tests failed
#   2 — build failed (no tests ran)
#   3 — no scratch tests found (likely all AC are non-api tier)
#   >3 — runner error

set -uo pipefail

TICKET="${1:-}"
if [ -z "$TICKET" ]; then
  echo "usage: $0 <ticket>" >&2
  exit 64
fi

: "${QA_REPO_ROOT:?must be set to the dserve-backend QA worktree}"
: "${QA_OUT_DIR:?must be set}"

mkdir -p "$QA_OUT_DIR"
PROJECT="$QA_REPO_ROOT/Dserve.SelfService.Integration/Dserve.SelfService.Integration.csproj"
SCRATCH_DIR="$QA_REPO_ROOT/Dserve.SelfService.Integration/QaScratch/T${TICKET}"

if [ ! -d "$SCRATCH_DIR" ]; then
  echo "no scratch tests at $SCRATCH_DIR — skipping API tier" >&2
  exit 3
fi

cd "$QA_REPO_ROOT"

echo "→ dotnet build $PROJECT" >&2
if ! dotnet build "$PROJECT" --nologo > "$QA_OUT_DIR/api-build.log" 2>&1; then
  echo "✗ build failed — see $QA_OUT_DIR/api-build.log" >&2
  tail -30 "$QA_OUT_DIR/api-build.log" >&2
  exit 2
fi
echo "✓ build OK" >&2

# Run only the QaScratch tests for this ticket. The filter uses
# FullyQualifiedName which matches the namespace + class.
FILTER="FullyQualifiedName~Dserve.SelfService.Integration.QaScratch.T${TICKET}"
TRX="$QA_OUT_DIR/api-results.trx"

echo "→ dotnet test --filter \"$FILTER\"" >&2
set +e
dotnet test "$PROJECT" \
  --no-build \
  --filter "$FILTER" \
  --logger "trx;LogFileName=$TRX" \
  --logger "console;verbosity=normal" \
  > "$QA_OUT_DIR/api-test.log" 2>&1
rc=$?
set -e

# dotnet test rc: 0=all passed, 1=test failures, others=runner errors.
if [ "$rc" -eq 0 ]; then
  echo "✓ all API tests passed" >&2
  exit 0
elif [ "$rc" -eq 1 ]; then
  echo "✗ one or more API tests failed — see $QA_OUT_DIR/api-test.log" >&2
  exit 1
else
  echo "! dotnet test runner error rc=$rc — see $QA_OUT_DIR/api-test.log" >&2
  exit 4
fi
