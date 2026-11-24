#!/usr/bin/env bash
# Route commands through the existing Claude Anderton's worker ownership.
set -euo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$scripts/session-lib.sh"
usage() {
  echo "usage: codex-workers.sh status|output|register <worker> | message <worker> <text>" >&2
  echo "Message exit 4 means submission is unconfirmed. Check status before resending." >&2
  exit 2
}
action=${1:-}
case $action in
  status | output | register) [ "$#" -eq 2 ] || usage ;;
  message) if [ "$#" -ne 3 ] || [ -z "$3" ]; then usage; fi ;;
  sweep) [ "$#" -eq 1 ] || usage ;;
  *) usage ;;
esac
continue_text="Your last turn stopped at the Codex usage limit of the account it ran on, and this conversation now runs on another account. Continue the task from where it stopped. Check the current state before repeating any command, edit or message that may already have completed."

# Codex worker record $1's pane as "<launcher> <socket> <pane> <server>" fields for codex_pane.
pane_of() {
  jq -r '[.launcher // "", .socket // "", .pane // "", .server // ""] | @tsv' "$1"
}

# Stops the Codex client in worker record $1's pane, while the pane shows the worker's thread, so no turn can start
# there while the thread moves. tmux: the pane runs a placeholder until it is reopened. herdr: Ctrl+C, sent only while
# the pane still shows the thread, until Codex has quit. Fails, touching nothing it does not own, when the pane shows
# anything else.
stop_pane() {
  local record=$1 launcher socket pane server id tries=10
  IFS=$'\t' read -r launcher socket pane server <<EOF
$(pane_of "$record")
EOF
  id=$(jq -r .id "$record")
  [ -n "$pane" ] || return 1
  shows_thread "$(codex_pane "$launcher" "$socket" "$pane" "$server")" "$id" || return 1
  case $launcher in
    tmux)
      tmux -S "$socket" respawn-pane -k -t "$pane" sh -c 'echo "Moving this Codex conversation to another account."; exec sleep 3600' \
        >/dev/null 2>&1
      ;;
    herdr)
      while [ "$tries" -gt 0 ] && shows_thread "$(codex_pane "$launcher" "$socket" "$pane" "$server")" "$id"; do
        HERDR_SOCKET_PATH=$socket herdr pane send-keys "$pane" ctrl+c >/dev/null 2>&1 || true
        sleep 0.5
        tries=$((tries - 1))
      done
      ! shows_thread "$(codex_pane "$launcher" "$socket" "$pane" "$server")" "$id"
      ;;
    *) return 1 ;;
  esac
}

# Opens the worker's thread in the pane stop_pane cleared, on the daemon of home $2. A remote resume takes no
# permission overrides: the thread keeps the sandbox and approvals it was started with. Prints a note when Codex waits
# at a prompt there.
reopen_pane() {
  local record=$1 to=$2 launcher socket pane server id name out tries=3
  IFS=$'\t' read -r launcher socket pane server <<EOF
$(pane_of "$record")
EOF
  id=$(jq -r .id "$record") name=$(jq -r .name "$record")
  set -- resume "$id" --remote "unix://$(codex_socket "$to")" -c 'tui.terminal_title=["thread-id"]'
  case $launcher in
    tmux) tmux -S "$socket" respawn-pane -k -t "$pane" -e "CODEX_HOME=$to" codex "$@" >/dev/null 2>&1 && return 0 ;;
    herdr)
      while [ "$tries" -gt 0 ]; do
        if out=$(HERDR_SOCKET_PATH=$socket herdr agent start "$name" --kind codex --pane "$pane" --timeout 30000 -- "$@" 2>&1)
        then
          return 0
        fi
        # Codex started and waits at a prompt in the pane, such as trusting the folder under the new account.
        case $out in *agent_not_ready*) echo "It waits at a startup prompt in its pane."; return 0 ;; esac
        tries=$((tries - 1))
        sleep 1
      done
      ;;
  esac
  echo "Its $launcher pane $pane did not reopen."
  return 1
}

# Records on worker record $1 that the move of its limited turn $2 was tried, and whether it moved ($3 true|false).
note_failover() {
  local updated
  updated=$(mktemp "$1.XXXXXX") || return 0
  if jq --arg turn "$2" --argjson moved "$3" --argjson at "$(date +%s)" '.codexFailover = {turn: $turn, at: $at, moved: $moved}' \
    "$1" >"$updated"; then mv -f "$updated" "$1"; else rm -f "$updated"; fi
}

# Moves Codex worker record $1, still on thread $2, whose latest turn failed at its account's usage limit, to the next
# account the account helper names: its pane's client stops, the thread resumes on the new home's daemon, the pane
# reopens there and the worker is told to continue. Prints the outcome for the watch to report.
failover() {
  local record=$1 expected=$2 root name id from helper out to limited turn message reopened retry start stopped=""
  root=$(invoking_root)
  take_repository_lock "$root"
  lock_worker "$record" || return 0
  # The sweep read the record before these locks: the role or the record may have changed since.
  if ! worker_belongs "$record" "$root" "$(caller_claim "$root")" ||
    ! jq -e --arg id "$expected" '.provider == "codex" and .id == $id' "$record" >/dev/null; then
    return 0
  fi
  name=$(jq -r .name "$record") id=$expected from=$(jq -r .codexHome "$record")
  limited=$("$scripts/codex-worker.py" limited "$record") || return 0
  turn=${limited%%$'\n'*} message=${limited#*$'\n'}
  retry=$(jq -r --arg turn "$turn" 'if .codexFailover.turn == $turn then "1" else "" end' "$record")
  if ! helper=$(codex_accounts); then
    note_failover "$record" "$turn" false
    [ -n "$retry" ] || echo "$name (Codex $id) stays at the usage limit of $from: no Codex account helper is installed to move it."
    return 0
  fi
  # A retry touches the pane only once the helper would start a new session somewhere else: the first try marked $from.
  if [ -n "$retry" ] && { ! start=$(CODEX_HOME=$from "$helper" --start-home </dev/null 2>/dev/null) ||
    [ "$(cd "$start" 2>/dev/null && pwd -P)" = "$(cd "$from" && pwd -P)" ]; }; then
    note_failover "$record" "$turn" false
    return 0
  fi
  # No client may start a turn on the old account while the thread moves; then the thread must still wait on nothing.
  if stop_pane "$record"; then stopped=1; fi
  if ! "$scripts/codex-worker.py" limited "$record" >/dev/null; then
    [ -z "$stopped" ] || reopen_pane "$record" "$from" >/dev/null
    return 0
  fi
  if ! out=$(CODEX_HOME=$from "$helper" --move-thread "$id" --message "$message" </dev/null 2>&1) ||
    ! to=$(cd "$(printf '%s\n' "$out" | tail -n 1)" 2>/dev/null && pwd -P); then
    [ -z "$stopped" ] || reopen_pane "$record" "$from" >/dev/null
    note_failover "$record" "$turn" false
    [ -n "$retry" ] || echo "$name (Codex $id) stays at the usage limit of $from: $(printf '%s\n' "$out" | tail -n 1)"
    return 0
  fi
  if ! codex_daemon_up "$to" || ! out=$("$scripts/codex-worker.py" move "$record" "$to" 2>&1); then
    [ -z "$stopped" ] || reopen_pane "$record" "$from" >/dev/null
    note_failover "$record" "$turn" false
    [ -n "$retry" ] || echo "$name (Codex $id) stays on $from: $to did not take its thread. ${out:-Its Codex daemon did not start.}"
    return 0
  fi
  note_failover "$record" "$turn" true
  if [ -z "$stopped" ]; then
    reopened="Its pane did not show thread $id, so it was left alone. Open the thread with: CODEX_HOME=$to codex resume $id --remote unix://$(codex_socket "$to")"
  elif reopened=$(reopen_pane "$record" "$to"); then
    reopened=${reopened:-Its pane shows it there.}
  else
    reopened="$reopened Open it with: CODEX_HOME=$to codex resume $id --remote unix://$(codex_socket "$to")"
  fi
  if "$scripts/codex-worker.py" message "$record" -- "$continue_text" >/dev/null 2>&1; then
    echo "$name (Codex $id) hit the usage limit of $from and continues on $to. $reopened"
  else
    echo "$name (Codex $id) moved from $from to $to, but the direction to continue is unconfirmed: check its status. $reopened"
  fi
}

records=$("$scripts/waiting.sh" --codex-workers)
if [ "$action" = sweep ]; then
  set --
  while IFS= read -r record; do
    if [ -n "$record" ] && jq -e '.id != ""' "$record" >/dev/null 2>&1; then
      set -- "$@" "$record"
    fi
  done <<<"$records"
  [ "$#" -gt 0 ] || exit 0
  limited=$(mktemp "${TMPDIR:-/tmp}/anderton-limited.XXXXXX")
  status=0
  ANDERTON_CODEX_LIMITED=$limited "$scripts/codex-worker.py" sweep "$@" || status=$?
  while IFS=$'\t' read -r record thread; do
    if [ -n "$record" ]; then (failover "$record" "$thread") || true; fi
  done <"$limited"
  rm -f "$limited"
  exit "$status"
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
if [ "$action" != output ]; then
  expected_thread=$(jq -r .id "$record")
  root=$(invoking_root)
  take_repository_lock "$root"
  lock_worker "$record"
  if ! worker_belongs "$record" "$root" "$(caller_claim "$root")" ||
    ! jq -e --arg id "$expected_thread" '.provider == "codex" and .id == $id' "$record" >/dev/null; then
    echo "Codex worker '$2' changed while acquiring its lock." >&2
    exit 1
  fi
fi
if [ "$action" = register ]; then
  thread=$expected_thread
  launch_token=$(jq -r '.codexLaunchToken // ""' "$record")
  if [ -z "$thread" ]; then
    # A record written before spawn.sh kept its launch time has the newest earlier thread instead.
    if launched_at=$(jq -er '.codexLaunchedAt' "$record"); then
      endpoint=(--since "$launched_at")
    else
      endpoint=(--after "$(jq -r '.codexBaseline // ""' "$record")")
    fi
    thread=$("$scripts/codex-worker.py" find "$(jq -r .codexHome "$record")" "$(jq -r .dir "$record")" \
      "${endpoint[@]}" --token "$launch_token") || {
      echo "No verified Codex thread yet. Inspect the worker tab and check that it received the launch brief." >&2
      exit 1
    }
  fi
  bind_codex_worker "$record" "$thread" "$launch_token"
  printf '%s\n' "$thread"
  exit 0
fi
if ! jq -e '.id != ""' "$record" >/dev/null; then
  echo "Codex worker '$2' needs to register its thread first." >&2
  exit 1
fi
if [ "$action" = status ]; then
  "$scripts/codex-worker.py" state "$record" --prune
  exit
fi
if [ "$action" = output ]; then
  exec "$scripts/codex-worker.py" output "$record"
fi
"$scripts/codex-worker.py" message "$record" -- "$3"
