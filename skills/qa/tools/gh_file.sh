#!/usr/bin/env bash
# gh_file.sh — print a file's contents from a GitHub repo (no clone needed).
# For source reconnaissance in REMOTE mode: read .razor / .cs files at the
# PR head ref to resolve selectors and confirm code-evidence.
#
# Usage: gh_file.sh <owner/repo> <path> [ref]
#   gh_file.sh MaistoMyletojai/dserve-backend Dserve.Admin/Pages/Venues/KdsProfileEdit.razor feature/4941-kds-language
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: $(basename "$0") <owner/repo> <path> [ref]" >&2; exit 2; }
slug="$1"; path="$2"; ref="${3:-}"
# Accept TRELLO-style creds env? No — gh uses its own auth (gh auth login).
gh api "repos/${slug}/contents/${path}${ref:+?ref=${ref}}" \
  -H "Accept: application/vnd.github.raw"
