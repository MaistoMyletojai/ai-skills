#!/usr/bin/env bash
# kc.sh — read a generic-password entry from macOS Keychain by service name.
# Never prints anything besides the raw secret value (stdout) on success.
# Usage: kc.sh <service>
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $(basename "$0") <service>" >&2; exit 2; }
security find-generic-password -a "$USER" -s "$1" -w 2>/dev/null \
  || { echo "kc.sh: '$1' not found in Keychain" >&2; exit 1; }
