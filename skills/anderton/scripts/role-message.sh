#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

usage() {
  echo "usage: role-message.sh [--project <name>] '<message>'" >&2
  exit 2
}
scope=""
if [ "${1:-}" = --project ]; then
  if [ "$#" -ne 3 ] || [ -z "$2" ]; then usage; fi
  scope=$2
  shift 2
fi
[ "$#" -eq 1 ] || usage
body=$1
case $body in *[![:space:]]*) ;; *) usage ;; esac
root=$(invoking_root)
take_repository_lock "$root"
source=$(caller_claim "$root")
target=$(holder_record "$root" "$scope")
if [ -z "$source" ] || [ -z "$target" ] || [ "$source" = "$target" ]; then
  echo "Two distinct Anderton claims in this repository are required." >&2
  exit 1
fi
if [ "$(record_provider "$source")" = claude ] && [ "$(record_provider "$target")" = claude ]; then
  echo "Use Claude Code SendMessage for a Claude-to-Claude Anderton message." >&2
  exit 2
fi
if [ -n "$scope" ] && [ "$(jq -r '.scope // empty' "$source")" != "" ]; then
  echo "Project Anderton messages route through the repository Anderton." >&2
  exit 2
fi
if [ "$(claim_state "$target")" = gone ]; then
  echo "The destination Anderton no longer holds this role." >&2
  exit 1
fi
if jq -e '.peerMessage != null' "$target" >/dev/null; then
  echo "The destination Anderton has a pending peer message." >&2
  exit 1
fi
token=$(python3 -c 'import uuid; print(uuid.uuid4())')
updated=$(mktemp "$target.XXXXXX")
jq --arg id "$token" --arg from "$(claim_name "$source")" --arg body "$body" '
  .peerMessage = {id: $id, from: $from, text: $body}' "$target" > "$updated" &&
  mv -f "$updated" "$target"
echo "Queued peer message $token for Anderton thread $(jq -r .sessionId "$target")."
