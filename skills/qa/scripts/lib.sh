#!/usr/bin/env bash
# lib.sh — environment setup for the dserve-qa-runner skill.
#
# SOURCE this (don't execute) before running any runner or glue script:
#     source "<skill>/scripts/lib.sh"
#
# It is a faithful port of qa_rig/helpers.py:agent_env() + augmented_path(),
# minus everything the scheduler/Telegram layers needed. It:
#   1. Locates the skill root and exports QA_AGENT_ROOT (= skill root, so the
#      runners find runners/ templates/ knowledge/ exactly where they expect).
#   2. Loads the config file (config/qa-skill.env, or QA_SKILL_ENV_FILE) and
#      exports it to child processes; also points trello.sh at the same file.
#   3. Builds a Homebrew-augmented PATH (launchd/agent shells miss /opt/homebrew).
#   4. Sets git identity for any agent-side commits.
#   5. Pulls the eshop tablet token from macOS Keychain (rotatable without edits).
#   6. Applies config.py-equivalent defaults for ports, branches, repos, runtime.
#
# Per-run vars (QA_OUT_DIR, QA_REPO_ROOT, QA_TICKET, QA_UI_TIER_AVAILABLE) are
# set by the skill from qa_prepare.py's output — NOT here.

# Resolve the skill root in a shell-agnostic way (bash, zsh, or plain sh).
# bash exposes BASH_SOURCE; zsh exposes ${(%):-%x}; otherwise fall back to an
# explicit QA_SKILL_ROOT env var or the current directory (SKILL.md tells you
# to `cd` into the skill dir before sourcing).
_qa_self=""
if [ -n "${BASH_SOURCE:-}" ]; then
  _qa_self="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  _qa_self="$(eval 'printf "%s" "${(%):-%x}"')"
fi
if [ -n "$_qa_self" ] && [ -f "$_qa_self" ]; then
  QA_AGENT_ROOT="$(cd "$(dirname "$_qa_self")/.." && pwd)"
elif [ -n "${QA_SKILL_ROOT:-}" ]; then
  QA_AGENT_ROOT="$QA_SKILL_ROOT"
elif [ -f "$PWD/scripts/lib.sh" ]; then
  QA_AGENT_ROOT="$PWD"
elif [ -f "$PWD/lib.sh" ]; then
  QA_AGENT_ROOT="$(cd "$PWD/.." && pwd)"
else
  echo "qa-skill: cannot locate skill root — \`cd\` into the skill dir before" >&2
  echo "          \`source scripts/lib.sh\`, or export QA_SKILL_ROOT=<skill-dir>." >&2
  return 1 2>/dev/null || exit 1
fi
export QA_AGENT_ROOT
# Sanity: the playbook must be reachable from the resolved root.
if [ ! -f "$QA_AGENT_ROOT/prompts/qa-card.md" ]; then
  echo "qa-skill: QA_AGENT_ROOT=$QA_AGENT_ROOT looks wrong (no prompts/qa-card.md)." >&2
  echo "          Set QA_SKILL_ROOT to the skill folder and re-source." >&2
  return 1 2>/dev/null || exit 1
fi

# ── 1. Load config file ────────────────────────────────────────────────
# Precedence: $QA_SKILL_ENV_FILE → config/qa-skill.env → skill-root/.env
_QA_ENV_FILE="${QA_SKILL_ENV_FILE:-}"
if [ -z "$_QA_ENV_FILE" ]; then
  if [ -f "$QA_AGENT_ROOT/config/qa-skill.env" ]; then
    _QA_ENV_FILE="$QA_AGENT_ROOT/config/qa-skill.env"
  elif [ -f "$QA_AGENT_ROOT/.env" ]; then
    _QA_ENV_FILE="$QA_AGENT_ROOT/.env"
  fi
fi
if [ -n "$_QA_ENV_FILE" ] && [ -f "$_QA_ENV_FILE" ]; then
  set -a; . "$_QA_ENV_FILE"; set +a
  # trello.sh auto-loads this same file for board/list/member IDs.
  export QA_RIG_ENV_FILE="$_QA_ENV_FILE"
  echo "qa-skill: loaded config from $_QA_ENV_FILE" >&2
else
  echo "qa-skill: no config file found — using built-in defaults" >&2
fi

# THIRD-PARTY tokens (Trello/GitHub) live in a SEPARATE gitignored file
# (config/.secrets); our-system creds (passwords, tabletToken) are in the main
# config above. Load .secrets after the config (override with QA_SECRETS_FILE).
_QA_SECRETS_FILE="${QA_SECRETS_FILE:-$QA_AGENT_ROOT/config/.secrets}"
if [ -f "$_QA_SECRETS_FILE" ]; then
  set -a; . "$_QA_SECRETS_FILE"; set +a
  echo "qa-skill: loaded secrets from $_QA_SECRETS_FILE" >&2
else
  echo "qa-skill: no secrets file at $_QA_SECRETS_FILE — copy config/.secrets.example → config/.secrets and fill it" >&2
fi

# ── 2. Augmented PATH (ported from helpers.augmented_path) ──────────────
_qa_augment_path() {
  local additions=(
    /opt/homebrew/bin /opt/homebrew/sbin
    /usr/local/bin /usr/local/sbin
    "$HOME/.dotnet" "$HOME/.dotnet/tools"
    "$HOME/.local/bin" "$HOME/.claude/local" "$HOME/.npm-global/bin"
  )
  local extra="" p
  for p in "${additions[@]}"; do extra="${extra:+$extra:}$p"; done
  export PATH="$extra:$PATH"
}
_qa_augment_path

# ── 3. config.py-equivalent defaults ───────────────────────────────────
export QA_DATA_ROOT="${QA_DATA_ROOT:-$HOME/dserve-qa-skill-data}"
mkdir -p "$QA_DATA_ROOT/runs" "$QA_DATA_ROOT/logs" 2>/dev/null || true

export MAIN_REPO_DIR="${MAIN_REPO_DIR:-$HOME/Documents/GitHub/dserve-backend}"
export MAIN_REPO_QA="${MAIN_REPO_QA:-$HOME/Documents/GitHub/dserve-backend-qa}"
export WEB_REPO_DIR="${WEB_REPO_DIR:-$HOME/Documents/GitHub/self-service-web}"
export WEB_REPO_QA="${WEB_REPO_QA:-$HOME/Documents/GitHub/self-service-web-qa}"
export MAIN_BASE_BRANCH="${MAIN_BASE_BRANCH:-master}"
export WEB_BASE_BRANCH="${WEB_BASE_BRANCH:-main}"

# ── orders-dashboard (KDS) — third surface (React/Vite, login-based) ──
export ORDERS_REPO_DIR="${ORDERS_REPO_DIR:-$HOME/Documents/GitHub/orders-dashboard}"
export ORDERS_REPO_QA="${ORDERS_REPO_QA:-$HOME/Documents/GitHub/orders-dashboard-qa}"
export ORDERS_REPO_SLUG="${ORDERS_REPO_SLUG:-MaistoMyletojai/orders-dashboard}"
export ORDERS_BASE_BRANCH="${ORDERS_BASE_BRANCH:-main}"
export QA_ORDERS_PORT="${QA_ORDERS_PORT:-3000}"
export QA_ORDERS_API_URL="${QA_ORDERS_API_URL:-https://ss-dev.dserve.app/api/kds}"  # KdsController base
export QA_ORDERS_DEV_URL="${QA_ORDERS_DEV_URL:-}"          # deployed KDS dashboard (set me)
export QA_ORDERS_EMAIL="${QA_ORDERS_EMAIL:-}"              # KDS login (/users/authenticate)
export QA_ORDERS_PASSWORD="${QA_ORDERS_PASSWORD:-}"

export QA_ADMIN_PORT="${QA_ADMIN_PORT:-5080}"
export QA_API_PORT="${QA_API_PORT:-5070}"
export QA_ESHOP_PORT="${QA_ESHOP_PORT:-5173}"
export QA_VITE_API_URL="${QA_VITE_API_URL:-https://ss-dev.dserve.app/api}"
export QA_ADMIN_EMAIL="${QA_ADMIN_EMAIL:-}"
export QA_ADMIN_PASSWORD="${QA_ADMIN_PASSWORD:-}"

export QA_PLAYWRIGHT_RUNTIME="${QA_PLAYWRIGHT_RUNTIME:-$QA_DATA_ROOT/playwright-runtime}"

# ── Remote mode (no local repos): GitHub slugs + deployed dev-server URLs ──
# Used by `qa_prepare.py --remote`, gh_file.sh, and the *-remote runners.
export MAIN_REPO_SLUG="${MAIN_REPO_SLUG:-MaistoMyletojai/dserve-backend}"
export WEB_REPO_SLUG="${WEB_REPO_SLUG:-MaistoMyletojai/self-service-web}"
export QA_ADMIN_DEV_URL="${QA_ADMIN_DEV_URL:-}"               # Blazor Admin dev URL (set me)
export QA_ESHOP_DEV_URL="${QA_ESHOP_DEV_URL:-https://ss-dev.dserve.app}"

# ── 4. git identity (ported from helpers.git_identity_env) ──────────────
export BOT_GIT_NAME="${BOT_GIT_NAME:-Dserve QA Bot}"
export BOT_GIT_EMAIL="${BOT_GIT_EMAIL:-qa-bot@dserve.local}"
export GIT_AUTHOR_NAME="$BOT_GIT_NAME"  GIT_AUTHOR_EMAIL="$BOT_GIT_EMAIL"
export GIT_COMMITTER_NAME="$BOT_GIT_NAME" GIT_COMMITTER_EMAIL="$BOT_GIT_EMAIL"

# ── 5. tablet token from Keychain (rotatable; optional) ─────────────────
if [ -z "${QA_TABLET_TOKEN:-}" ]; then
  QA_TABLET_TOKEN="$("$QA_AGENT_ROOT/tools/kc.sh" autodev_qa_tablet_token 2>/dev/null || true)"
  export QA_TABLET_TOKEN
fi

# ── Summary ─────────────────────────────────────────────────────────────
echo "qa-skill: QA_AGENT_ROOT=$QA_AGENT_ROOT" >&2
echo "qa-skill: data=$QA_DATA_ROOT  admin:$QA_ADMIN_PORT api:$QA_API_PORT eshop:$QA_ESHOP_PORT" >&2
[ -n "$QA_ADMIN_EMAIL" ] && [ -n "$QA_ADMIN_PASSWORD" ] \
  && echo "qa-skill: UI tier AVAILABLE (admin creds present)" >&2 \
  || echo "qa-skill: UI tier UNAVAILABLE (admin creds missing → admin-ui AC fall back to code-evidence)" >&2
