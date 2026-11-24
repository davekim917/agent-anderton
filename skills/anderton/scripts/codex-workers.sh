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

# Reopens Codex worker record $1's pane on the daemon of home $2, at the thread it shows. A remote resume takes no
# permission overrides: the thread keeps the sandbox and approvals it was started with. Only a pane still showing the
# worker's thread is touched. Prints why when it cannot, or a note when Codex waits at a prompt there.
reopen_pane() {
  local record=$1 to=$2 launcher socket pane server id name out tries=3
  launcher=$(jq -r '.launcher // ""' "$record") socket=$(jq -r '.socket // ""' "$record")
  pane=$(jq -r '.pane // ""' "$record") server=$(jq -r '.server // ""' "$record")
  id=$(jq -r .id "$record") name=$(jq -r .name "$record")
  if [ -z "$pane" ]; then echo "Its pane was not recorded."; return 1; fi
  if ! shows_thread "$(codex_pane "$launcher" "$socket" "$pane" "$server")" "$id"; then
    echo "Its pane no longer shows thread $id."
    return 1
  fi
  set -- resume "$id" --remote "unix://$(codex_socket "$to")" -c 'tui.terminal_title=["thread-id"]'
  case $launcher in
    tmux)
      tmux -S "$socket" respawn-pane -k -t "$pane" -e "CODEX_HOME=$to" codex "$@" >/dev/null 2>&1 && return 0
      ;;
    herdr)
      # Codex quits on a second Ctrl+C; agent start then needs the pane back at its shell prompt.
      HERDR_SOCKET_PATH=$socket herdr pane send-keys "$pane" ctrl+c >/dev/null 2>&1 || true
      sleep 0.5
      HERDR_SOCKET_PATH=$socket herdr pane send-keys "$pane" ctrl+c >/dev/null 2>&1 || true
      while [ "$tries" -gt 0 ]; do
        sleep 1
        if out=$(HERDR_SOCKET_PATH=$socket herdr agent start "$name" --kind codex --pane "$pane" --timeout 30000 -- "$@" 2>&1)
        then
          return 0
        fi
        # Codex started and waits at a prompt in the pane, such as trusting the folder under the new account.
        case $out in *agent_not_ready*) echo "It waits at a startup prompt in its pane."; return 0 ;; esac
        tries=$((tries - 1))
      done
      ;;
  esac
  echo "Its $launcher pane $pane did not reopen."
  return 1
}

# Moves Codex worker record $1, whose latest turn failed at its account's usage limit, to the next account the
# account helper names, reopens its pane there and tells it to continue. Prints the outcome for the watch to report.
failover() {
  local record=$1 name id from helper out to message reopened
  take_repository_lock "$(jq -r .root "$record")"
  lock_worker "$record" || return 0
  name=$(jq -r .name "$record") id=$(jq -r .id "$record") from=$(jq -r .codexHome "$record")
  # The thread may have moved, or taken a direction, since the sweep read it.
  message=$("$scripts/codex-worker.py" limited "$record") || return 0
  if ! helper=$(codex_accounts); then
    echo "$name (Codex $id) stays at the usage limit of $from: no Codex account helper is installed to move it."
    return 0
  fi
  if ! out=$(CODEX_HOME=$from "$helper" --move-thread "$id" --message "$message" </dev/null 2>&1); then
    echo "$name (Codex $id) stays at the usage limit of $from: $(printf '%s\n' "$out" | tail -n 1)"
    return 0
  fi
  if ! to=$(cd "$(printf '%s\n' "$out" | tail -n 1)" 2>/dev/null && pwd -P); then
    echo "$name (Codex $id) stays on $from: the account helper named no home it could move to."
    return 0
  fi
  if ! codex_daemon_up "$to"; then
    echo "$name (Codex $id) stays on $from: the Codex daemon of $to did not start."
    return 0
  fi
  if ! out=$("$scripts/codex-worker.py" move "$record" "$to" 2>&1); then
    echo "$name (Codex $id) stays on $from: $to could not resume its thread. $out"
    return 0
  fi
  if reopened=$(reopen_pane "$record" "$to"); then
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
  while IFS= read -r record; do
    if [ -n "$record" ]; then (failover "$record") || true; fi
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
