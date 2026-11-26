#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

usage() {
  echo "usage: worker.sh status|output <name> | message <name> <direction>" >&2
  echo "Codex message exit 4 means submission is unconfirmed. Check status before resending." >&2
  exit 2
}
action=${1:-}
name=${2:-}
if [ "$action" = sweep ] && [ "$#" -eq 1 ]; then
  result=0
  root=$(invoking_root)
  role=$(caller_claim "$root")
  "$anderton_scripts/codex-workers.sh" sweep || result=1
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    "$anderton_scripts/claude-worker.py" sweep "$record" --claim "$role" || result=1
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
if [ "$(record_provider "$record")" = agy ]; then
  pane=$(jq -r '.pane // empty' "$record")
  socket=$(jq -r '.socket // empty' "$record")
  unidentified="agy worker '$name' was recorded without its agy instance, so herdr cannot show that pane $pane runs it rather than another agy. Run migrate-workers.sh, or read the pane yourself."
  case $action in
    status)
      agy_check "$record"
      jq -n --arg pane "$pane" --arg state "$agy_state" --arg status "$agy_status" \
        '{pane: $pane, worker: $state, status: (if $status == "" then null else $status end)}'
      ;;
    output)
      agy_check "$record"
      if [ "$agy_state" = unidentified ]; then echo "$unidentified" >&2; exit 1; fi
      if [ "$agy_state" != running ]; then
        echo "agy worker '$name' is not running in its pane $pane, so there is no screen to read." >&2
        exit 1
      fi
      # agy keeps no transcript these scripts read yet, so its replies come from the terminal.
      echo "Screen read of herdr pane $pane (recent output, not a transcript):"
      HERDR_SOCKET_PATH="$socket" herdr agent read "$pane" --source recent --lines 200
      ;;
    message)
      [ -n "$3" ] || usage
      take_repository_lock "$root"
      lock_worker "$record"
      if ! caller_matches_claim "$role" || ! worker_belongs "$record" "$root" "$role"; then
        echo "This Anderton no longer holds worker '$name'." >&2
        exit 1
      fi
      agy_check "$record"
      # The pane must show the agy spawn.sh started, as it showed it then, just before the send.
      if [ "$agy_state" = unidentified ]; then echo "$unidentified" >&2; exit 1; fi
      if [ "$agy_state" != running ]; then
        echo "agy worker '$name' is not running in its pane $pane, so the direction was not sent." >&2
        exit 1
      fi
      if ! out=$(HERDR_SOCKET_PATH="$socket" herdr agent prompt "$pane" "$3" 2>&1); then
        echo "herdr did not take the direction for agy worker '$name': $out" >&2
        exit 1
      fi
      echo "Sent the direction to agy worker '$name' in pane $pane."
      ;;
  esac
  exit 0
fi
if [ "$action" = output ]; then
  exec "$anderton_scripts/claude-worker.py" output "$record"
fi
# An idle Claude worker hears directions through its Stop watcher, which ends at once while a Claude Anderton answers for
# it. After a take-over, the direction $1 goes into the worker's herdr pane instead, only while herdr shows that worker's
# session there, idle. Exits.
wake_claude_worker() {
  local pane socket out shown status token
  pane=$(jq -r 'if .launcher == "herdr" then .pane // empty else empty end' "$record")
  socket=$(jq -r '.socket // empty' "$record")
  if [ -z "$pane" ] || [ -z "$socket" ]; then
    echo "The worker's Anderton Stop watcher has ended, and it has no herdr pane to wake it in. Type the direction in the worker's own pane, or have it end a turn with the plugin loaded and retry." >&2
    exit 1
  fi
  out=$(HERDR_SOCKET_PATH="$socket" herdr agent get "$pane" 2>&1) || true
  IFS=$'\x1f' read -r shown status <<EOF
$(printf '%s' "$out" | jq -r '(.result.agent // empty) | select(.agent == "claude")
  | [(.agent_session.value // "" | tostring), .agent_status // ""] | join("\u001f")' 2>/dev/null)
EOF
  if [ "$shown" != "$target" ]; then
    echo "herdr pane $pane does not show worker '$name' (Claude session $target), so the direction was not sent. Type it in the worker's own pane." >&2
    exit 1
  fi
  case $status in
    idle | done) ;;
    *)
      echo "Worker '$name' is busy in herdr pane $pane ($status), so the direction was not sent. Retry once it is idle." >&2
      exit 1
      ;;
  esac
  token=$(python3 -c 'import uuid; print(uuid.uuid4())')
  if ! out=$(HERDR_SOCKET_PATH="$socket" herdr agent prompt "$pane" "$(claude_direction_notice "$token" "$1")" 2>&1); then
    echo "herdr did not take the direction for worker '$name': $out" >&2
    exit 1
  fi
  # Nothing is queued: the Stop watcher this turn's end starts would deliver a queued direction again, since a typed
  # prompt is not the notice claude-worker.py acknowledged looks for.
  echo "Sent direction $token into worker '$name''s herdr pane $pane, its Stop watcher having ended."
  exit 0
}
reg=$(live_claude_worker "$record")
case $reg in ''|*$'\n'*) echo "Cannot verify a unique live Claude worker '$name'." >&2; exit 1 ;; esac
if [ "$action" = status ]; then
  jq '{sessionId, status, waitingFor, cwd}' "$reg"
  exit 0
fi
if [ "$(invoking_provider)" = claude ]; then
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
      ! process_start_matches "$watch_pid" "$watch_start"; then
      wake_claude_worker "$3"
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
