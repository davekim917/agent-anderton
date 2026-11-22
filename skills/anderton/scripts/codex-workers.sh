#!/usr/bin/env bash
# Route commands through the existing Claude Anderton's worker ownership.
set -euo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$scripts/session-lib.sh"
usage() {
  echo "usage: codex-workers.sh status|output|register <worker> | message <worker> <text>" >&2
  exit 2
}
action=${1:-}
case $action in
  status | output | register) [ "$#" -eq 2 ] || usage ;;
  message) if [ "$#" -ne 3 ] || [ -z "$3" ]; then usage; fi ;;
  sweep) [ "$#" -eq 1 ] || usage ;;
  *) usage ;;
esac
records=$("$scripts/waiting.sh" --codex-workers)
if [ "$action" = sweep ]; then
  set --
  while IFS= read -r record; do
    if [ -n "$record" ] && jq -e '.id != ""' "$record" >/dev/null 2>&1; then
      set -- "$@" "$record"
    fi
  done <<<"$records"
  if [ "$#" -gt 0 ]; then
    exec "$scripts/codex-worker.py" sweep "$@"
  fi
  exit 0
fi
case $2 in '' | -* | *[!a-z0-9-]*) usage ;; esac
record=""
while IFS= read -r owned; do
  if [ "${owned##*/}" = "$2.json" ]; then record=$owned; break; fi
done <<<"$records"
if [ -z "$record" ]; then
  echo "No Codex worker '$2' owned by this Anderton." >&2
  exit 1
fi
if [ "$action" = register ] || [ "$action" = message ]; then
  expected_thread=$(jq -r .id "$record")
  lock_codex_worker "$record"
  if ! jq -e --arg id "$expected_thread" '.provider == "codex" and .id == $id' "$record" >/dev/null; then
    echo "Codex worker '$2' changed while acquiring its lock." >&2
    exit 1
  fi
fi
update_record() {
  local updated
  updated=$(mktemp "$record.XXXXXX")
  if jq --arg key "$1" --arg value "$2" '.[$key] = $value' "$record" >"$updated" &&
    mv -f "$updated" "$record"; then return; fi
  rm -f "$updated"
  return 1
}
if [ "$action" = register ] && jq -e '.id == ""' "$record" >/dev/null; then
  thread=$("$scripts/codex-worker.py" find "$(jq -r .codexHome "$record")" "$(jq -r .dir "$record")" \
    --after "$(jq -r '.codexBaseline // ""' "$record")" --token "$(jq -r '.codexLaunchToken // ""' "$record")") || {
    echo "No verified Codex thread yet. Inspect the worker tab and check that it received the launch brief." >&2
    exit 1
  }
  update_record id "$thread"
fi
if ! jq -e '.id != ""' "$record" >/dev/null; then
  echo "Codex worker '$2' needs to register its thread first." >&2
  exit 1
fi
if [ "$action" = register ]; then
  jq -r .id "$record"
  exit 0
fi
if [ "$action" = status ]; then
  exec "$scripts/codex-worker.py" state "$record"
fi
if [ "$action" = output ]; then
  exec "$scripts/codex-worker.py" output "$record"
fi
socket=$("$scripts/codex-worker.py" target "$record")
thread=$(jq -r .id "$record")
codex_home=$(jq -r .codexHome "$record")
if ! "$scripts/codex-worker.py" received "$record"; then
  echo "A previous direction to '$2' has no delivery receipt. Inspect the worker's thread before sending another." >&2
  exit 1
fi
token=$(python3 -c 'import uuid; print(uuid.uuid4())')
update_record codexPending "$token"
message=$(printf 'Anderton direction %s\nDirection from your Claude Code Anderton. Follow the existing approval policy.\n\n%s' "$token" "$3")
CODEX_HOME="$codex_home" codex queue --remote "unix://$socket" --thread "$thread" --message "$message" --resume
