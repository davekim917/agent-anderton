#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

usage() {
  echo "usage: worker.sh status|output <name> | message <name> <direction>" >&2
  exit 2
}
action=${1:-}
name=${2:-}
if [ "$action" = sweep ] && [ "$#" -eq 1 ]; then
  result=0
  "$anderton_scripts/codex-workers.sh" sweep || result=1
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    "$anderton_scripts/claude-worker.py" sweep "$record" || result=1
  done <<RECORDS
$("$anderton_scripts/waiting.sh" --transcript-workers)
RECORDS
  exit "$result"
fi
case $name in '' | -* | *[!a-z0-9-]*) usage ;; esac
case "$action:$#" in status:2 | output:2 | message:3) ;; *) usage ;; esac
root=$(invoking_root)
role=$(caller_claim "$root")
record="$holders/workers/$name.json"
if [ ! -f "$record" ] || ! worker_belongs "$record" "$root" "$role"; then
  echo "No worker '$name' owned by this Anderton." >&2
  exit 1
fi
if [ "$(record_provider "$record")" = codex ]; then
  exec "$anderton_scripts/codex-workers.sh" "$@"
fi
if [ "$action" = output ]; then
  exec "$anderton_scripts/claude-worker.py" output "$record"
fi
reg=$(live_claude_worker "$record")
case $reg in ''|*$'\n'*) echo "Cannot verify a unique live Claude worker '$name'." >&2; exit 1 ;; esac
if [ "$action" = status ]; then
  jq '{sessionId, status, waitingFor, cwd}' "$reg"
  exit 0
fi
if [ "$(invoking_provider)" != codex ]; then
  echo "Use Claude Code SendMessage to the verified Claude session in this registry entry: $reg" >&2
  exit 2
fi
[ -n "$3" ] || usage
take_repository_lock "$root"
lock_worker "$record"
still=$(live_claude_worker "$record")
[ "$reg" = "$still" ] && caller_matches_claim "$role" && worker_belongs "$record" "$root" "$role" || exit 1
target=$(jq -r .sessionId "$reg")
sender=$(invoking_session)
if ! jq -e --arg sid "$target" '.claudeSession.id == $sid' "$record" >/dev/null ||
  ! claude_binding_process_matches "$record" "$(jq -r .pid "$reg")"; then
  echo "The worker has not registered its Anderton Stop hook. Have it end a turn with the plugin loaded and retry." >&2
  exit 1
fi
case $(jq -r '.status // empty' "$reg") in
  busy | waiting) ;;
  *)
    if ! read -r watch_pid watch_start 2>/dev/null < "${record%.json}.$target.watch" ||
      [ -z "$watch_start" ] || [ "$(proc_start "$watch_pid")" != "$watch_start" ]; then
      echo "The worker's Anderton Stop watcher has ended. Have it end a turn with the plugin loaded and retry." >&2
      exit 1
    fi
    ;;
esac
if jq -e --arg from "$sender" '.claudeDirection.from == $from' "$record" >/dev/null &&
  ! "$anderton_scripts/claude-worker.py" acknowledged "$record"; then
  echo "Wait for the preceding Anderton direction to be delivered." >&2
  exit 1
fi
token=$(python3 -c 'import uuid; print(uuid.uuid4())')
updated=$(mktemp "$record.XXXXXX")
jq --arg id "$token" --arg sid "$target" --arg text "$3" --arg from "$sender" '
  .claudeDirection = {id: $id, target: $sid, text: $text, from: $from}' "$record" > "$updated" &&
  mv -f "$updated" "$record"
echo "Queued direction $token for Claude session $target."
