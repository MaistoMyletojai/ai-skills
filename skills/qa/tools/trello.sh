#!/usr/bin/env bash
# trello.sh — minimal Trello REST API wrapper. Reads key+token from Keychain.
#
# Usage:
#   trello.sh boards                          — your boards
#   trello.sh lists <board-id>                — lists on a board
#   trello.sh cards <list-id>                 — cards in a given list
#   trello.sh search "<query>" [limit]        — search cards (default limit 10)
#   trello.sh get <card-id>                   — card fields
#   trello.sh full <card-id>                  — card + checklists + members + attachments
#   trello.sh comments <card-id>              — card's comment actions
#   trello.sh move <card-id> <list-id>        — move card to list
#   trello.sh comment <card-id> "text"        — add a comment
#   trello.sh create <list-id> "name" "desc"  — new card (no assignment)
#   trello.sh create-todo "name" "desc"       — new card on TRELLO_LIST_TODO, assigned to TRELLO_MEMBER_ID
#   trello.sh label <card-id> <label-id>      — add a label
#   trello.sh assign <card-id> <member-id>    — add member to card
#   trello.sh me                              — my member profile
#   trello.sh my-cards                        — open cards assigned to me on TRELLO_BOARD_ID
#   trello.sh done-since <ISO-datetime>       — my moves into TRELLO_LIST_IDS_COMPLETED since given time
#   trello.sh weekly-done                     — convenience: done-since 7 days ago (UTC)
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# Auto-load .env so board/list/member IDs are available both in interactive
# shell use and when the rig spawns an agent subprocess. The rig's .env lives
# in the repo root (one level up from tools/). Override with QA_RIG_ENV_FILE
# if you want to point elsewhere.
ENV_FILE="${QA_RIG_ENV_FILE:-$DIR/../.env}"
if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
fi

# Keychain entries — QA rig uses _qa_ prefix to keep separate from any
# dev rig credentials. Fall back to the dev rig entry for backward compat
# during transitions (will warn but work).
# Keychain is primary (preserves rig behavior); fall back to TRELLO_API_KEY /
# TRELLO_TOKEN env vars for environments that inject creds (e.g. 1Password).
KEY="$("$DIR/kc.sh" autodev_qa_trello_key 2>/dev/null || "$DIR/kc.sh" autodev_trello_key 2>/dev/null || printf '%s' "${TRELLO_API_KEY:-}")"
TOK="$("$DIR/kc.sh" autodev_qa_trello_token 2>/dev/null || "$DIR/kc.sh" autodev_trello_token 2>/dev/null || printf '%s' "${TRELLO_TOKEN:-}")"
BASE="https://api.trello.com/1"

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "trello.sh: missing env var $name (set it in $ENV_FILE)" >&2
    exit 3
  fi
}

[ $# -ge 1 ] || { grep '^#' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
cmd="$1"; shift
case "$cmd" in
  boards)
    curl -fsS --get "${BASE}/members/me/boards" \
      --data-urlencode "fields=name,shortUrl" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}"
    ;;
  lists)
    [ $# -eq 1 ] || { echo "usage: trello.sh lists <board-id>" >&2; exit 2; }
    curl -fsS --get "${BASE}/boards/$1/lists" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}"
    ;;
  cards)
    [ $# -eq 1 ] || { echo "usage: trello.sh cards <list-id>" >&2; exit 2; }
    curl -fsS --get "${BASE}/lists/$1/cards" \
      --data-urlencode "fields=name,desc,shortUrl,idList,labels,idMembers" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}"
    ;;
  board_cards)
    # All open cards on a board with full label info. Used by the QA poller
    # to scan for 'Ready for QA' candidates.
    # Usage: trello.sh board_cards <board-id>
    [ $# -eq 1 ] || { echo "usage: trello.sh board_cards <board-id>" >&2; exit 2; }
    curl -fsS --get "${BASE}/boards/$1/cards" \
      --data-urlencode "fields=name,desc,shortUrl,idList,labels,idMembers,idShort" \
      --data-urlencode "filter=open" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}"
    ;;
  resolve)
    # Best-effort card resolution from a short ID, URL, or title fragment.
    # Output shape matches `get` (single card object).
    # Tries (in order):
    #   1. Treat input as a card ID (short or full hex) → GET /cards/<id>
    #   2. If it's a URL, extract the shortLink and use that
    #   3. Search by title, return the first hit
    # Usage: trello.sh resolve "<id-or-url-or-fragment>"
    [ $# -eq 1 ] || { echo "usage: trello.sh resolve <ref>" >&2; exit 2; }
    ref="$1"
    # URL → extract shortLink (between /c/ and the next /)
    if [[ "$ref" == http*://* ]]; then
      ref="$(echo "$ref" | sed -nE 's@.*/c/([A-Za-z0-9]+).*@\1@p')"
      [ -n "$ref" ] || { echo '{"error":"could not extract shortLink from URL"}'; exit 0; }
    fi
    # Try direct GET (works for both short hex IDs and full 24-char IDs).
    direct="$(curl -fsS --get "${BASE}/cards/${ref}" \
              --data-urlencode "fields=all" \
              --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}" \
              2>/dev/null || true)"
    if [ -n "$direct" ] && echo "$direct" | grep -q '"id"'; then
      echo "$direct"
      exit 0
    fi
    # Fall back to search; require at least one alphanumeric character.
    if [[ "$ref" =~ ^[0-9]+$ ]] && [ -n "${TRELLO_BOARD_ID:-}" ]; then
      # Numeric → search board for a card whose shortLink matches.
      # Trello's search filters down well by query.
      first="$(curl -fsS --get "${BASE}/search" \
                --data-urlencode "query=${ref}" \
                --data-urlencode "modelTypes=cards" \
                --data-urlencode "idBoards=${TRELLO_BOARD_ID}" \
                --data-urlencode "cards_limit=5" \
                --data-urlencode "card_fields=all" \
                --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}" \
              | python3 -c 'import sys,json; d=json.load(sys.stdin); cs=d.get("cards") or []; print(json.dumps(cs[0]) if cs else "")' \
              2>/dev/null || true)"
      if [ -n "$first" ]; then
        echo "$first"; exit 0
      fi
    fi
    echo '{"error":"could not resolve card","ref":"'"$ref"'"}'
    ;;
  search)
    [ $# -ge 1 ] || { echo "usage: trello.sh search \"<query>\" [limit]" >&2; exit 2; }
    q="$1"; limit="${2:-10}"
    curl -fsS --get "${BASE}/search" \
      --data-urlencode "query=${q}" \
      --data-urlencode "modelTypes=cards" \
      --data-urlencode "cards_limit=${limit}" \
      --data-urlencode "card_fields=name,desc,shortUrl,idList,idBoard" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}"
    ;;
  get)
    [ $# -eq 1 ] || { echo "usage: trello.sh get <card-id>" >&2; exit 2; }
    curl -fsS --get "${BASE}/cards/$1" \
      --data-urlencode "fields=name,desc,idList,shortUrl,labels,due,dueComplete,idMembers" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}"
    ;;
  full)
    [ $# -eq 1 ] || { echo "usage: trello.sh full <card-id>" >&2; exit 2; }
    curl -fsS --get "${BASE}/cards/$1" \
      --data-urlencode "fields=all" \
      --data-urlencode "checklists=all" \
      --data-urlencode "members=true" \
      --data-urlencode "attachments=true" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}"
    ;;
  comments)
    [ $# -eq 1 ] || { echo "usage: trello.sh comments <card-id>" >&2; exit 2; }
    curl -fsS --get "${BASE}/cards/$1/actions" \
      --data-urlencode "filter=commentCard" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}"
    ;;
  move)
    [ $# -eq 2 ] || { echo "usage: trello.sh move <card-id> <list-id>" >&2; exit 2; }
    curl -fsS -X PUT --get "${BASE}/cards/$1" \
      --data-urlencode "idList=$2" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}"
    ;;
  comment)
    [ $# -eq 2 ] || { echo "usage: trello.sh comment <card-id> \"text\"" >&2; exit 2; }
    curl -fsS -X POST "${BASE}/cards/$1/actions/comments" \
      --data-urlencode "text=$2" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}"
    ;;
  attach)
    # Attach a local file (e.g. a QA screenshot) to a card.
    # Usage: trello.sh attach <card-id> <file-path> [display-name]
    [ $# -ge 2 ] || { echo "usage: trello.sh attach <card-id> <file-path> [name]" >&2; exit 2; }
    [ -f "$2" ] || { echo "trello.sh attach: file not found: $2" >&2; exit 2; }
    # key/token go in the query string; the file is multipart form-data.
    curl -fsS -X POST "${BASE}/cards/$1/attachments?key=${KEY}&token=${TOK}" \
      -F "file=@$2" \
      ${3:+-F "name=$3"}
    ;;
  attachments)
    # List a card's attachments (id, name, url).
    [ $# -eq 1 ] || { echo "usage: trello.sh attachments <card-id>" >&2; exit 2; }
    curl -fsS --get "${BASE}/cards/$1/attachments" \
      --data-urlencode "fields=name,url,date" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}"
    ;;
  labels)
    # List ALL labels defined on a board (id + name + color). Used to
    # resolve the "AI QA Ready"/"InProgress"/"Complete" label IDs.
    # Usage: trello.sh labels <board-id>
    [ $# -eq 1 ] || { echo "usage: trello.sh labels <board-id>" >&2; exit 2; }
    curl -fsS --get "${BASE}/boards/$1/labels" \
      --data-urlencode "fields=name,color" \
      --data-urlencode "limit=1000" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}"
    ;;
  label-add)
    # Add a label to a card. Idempotent: Trello dedups on its side.
    # Usage: trello.sh label-add <card-id> <label-id>
    [ $# -eq 2 ] || { echo "usage: trello.sh label-add <card-id> <label-id>" >&2; exit 2; }
    curl -fsS -X POST "${BASE}/cards/$1/idLabels" \
      --data-urlencode "value=$2" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}"
    ;;
  label-remove)
    # Remove a label from a card. Idempotent.
    # Usage: trello.sh label-remove <card-id> <label-id>
    [ $# -eq 2 ] || { echo "usage: trello.sh label-remove <card-id> <label-id>" >&2; exit 2; }
    curl -fsS -X DELETE "${BASE}/cards/$1/idLabels/$2" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}"
    ;;
  create)
    [ $# -ge 2 ] || { echo "usage: trello.sh create <list-id> \"name\" [\"desc\"]" >&2; exit 2; }
    curl -fsS -X POST "${BASE}/cards" \
      --data-urlencode "idList=$1" \
      --data-urlencode "name=$2" \
      --data-urlencode "desc=${3:-}" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}"
    ;;
  create-todo)
    [ $# -ge 1 ] || { echo "usage: trello.sh create-todo \"name\" [\"desc\"]" >&2; exit 2; }
    require_env TRELLO_LIST_TODO
    require_env TRELLO_MEMBER_ID
    curl -fsS -X POST "${BASE}/cards" \
      --data-urlencode "idList=${TRELLO_LIST_TODO}" \
      --data-urlencode "name=$1" \
      --data-urlencode "desc=${2:-}" \
      --data-urlencode "idMembers=${TRELLO_MEMBER_ID}" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}"
    ;;
  label)
    [ $# -eq 2 ] || { echo "usage: trello.sh label <card-id> <label-id>" >&2; exit 2; }
    curl -fsS -X POST "${BASE}/cards/$1/idLabels" \
      --data-urlencode "value=$2" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}"
    ;;
  assign)
    [ $# -eq 2 ] || { echo "usage: trello.sh assign <card-id> <member-id>" >&2; exit 2; }
    curl -fsS -X POST "${BASE}/cards/$1/idMembers" \
      --data-urlencode "value=$2" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}"
    ;;
  me)
    curl -fsS --get "${BASE}/members/me" \
      --data-urlencode "fields=id,username,fullName" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}"
    ;;
  my-cards)
    require_env TRELLO_BOARD_ID
    require_env TRELLO_MEMBER_ID
    curl -fsS --get "${BASE}/members/${TRELLO_MEMBER_ID}/cards" \
      --data-urlencode "fields=name,desc,shortUrl,idList,idBoard,labels,due" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}" \
      | jq --arg b "$TRELLO_BOARD_ID" '[.[] | select(.idBoard == $b)]'
    ;;
  done-since)
    [ $# -eq 1 ] || { echo "usage: trello.sh done-since <ISO-datetime>  (e.g. 2026-04-15T00:00:00Z)" >&2; exit 2; }
    require_env TRELLO_MEMBER_ID
    require_env TRELLO_LIST_IDS_COMPLETED
    since="$1"
    # Split CSV of completion list IDs into a JSON array for jq.
    completed_json=$(printf '%s' "$TRELLO_LIST_IDS_COMPLETED" \
      | jq -R 'split(",") | map(select(length>0))')
    curl -fsS --get "${BASE}/members/${TRELLO_MEMBER_ID}/actions" \
      --data-urlencode "filter=updateCard" \
      --data-urlencode "since=${since}" \
      --data-urlencode "limit=1000" \
      --data-urlencode "key=${KEY}" --data-urlencode "token=${TOK}" \
      | jq --argjson done "$completed_json" '
          [ .[]
            | select(.data.listAfter != null and (.data.listAfter.id as $a | $done | index($a)))
            | {
                date: .date,
                cardId: .data.card.id,
                cardName: .data.card.name,
                fromList: .data.listBefore.name,
                toList: .data.listAfter.name,
                shortLink: .data.card.shortLink
              }
          ]'
    ;;
  weekly-done)
    # 7 days ago in UTC, ISO8601 — works on BSD date (macOS) and GNU date.
    if date -u -v-7d +"%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
      since=$(date -u -v-7d +"%Y-%m-%dT%H:%M:%SZ")
    else
      since=$(date -u -d "7 days ago" +"%Y-%m-%dT%H:%M:%SZ")
    fi
    exec "$0" done-since "$since"
    ;;
  *)
    echo "unknown subcommand: $cmd" >&2
    grep '^#' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
