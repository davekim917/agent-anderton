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
      tmux -S "$socket" respawn-pane -k -t "$pane" sh -c 'echo "Moving this Codex conversation to another account."; while :; do sleep 3600; done' \
        >/dev/null 2>&1 || return 1
      # reopen_pane reopens only a pane that still shows this placeholder or the thread.
      tmux -S "$socket" select-pane -t "$pane" -T "$(moving_title "$id")" >/dev/null 2>&1 || true
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

moving_title() {
  printf 'anderton-moving %s\n' "$1"
}

# Opens the worker's thread in the pane stop_pane cleared, on the daemon of home $2. A remote resume takes no
# permission overrides: the thread keeps the sandbox and approvals it was started with. Prints a note when Codex waits
# at a prompt there. Returns 2, touching nothing, when the pane is gone or shows something else: a tmux pane anything
# but stop_pane's placeholder or the thread, a herdr pane another Codex conversation.
reopen_pane() {
  local record=$1 to=$2 launcher socket pane server id name out view tries=1
  IFS=$'\t' read -r launcher socket pane server <<EOF
$(pane_of "$record")
EOF
  id=$(jq -r .id "$record") name=$(jq -r .name "$record")
  view=$(codex_pane "$launcher" "$socket" "$pane" "$server")
  case $view in
    "present $(moving_title "$id")") ;;
    present*)
      if ! shows_thread "$view" "$id"; then
        case $launcher in
          tmux) echo "Its $launcher pane $pane now shows something else, so it was left alone."; return 2 ;;
          *)
            if printf '%s\n' "$view" | grep -qE '[0-9a-f]{8}-[0-9a-f-]{20}\.\.\.$'; then
              echo "Its $launcher pane $pane now shows another Codex conversation, so it was left alone."
              return 2
            fi
            ;;
        esac
      fi
      ;;
    *) echo "Its $launcher pane $pane is gone."; return 2 ;;
  esac
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

# Records on worker record $1 what became of the move of its limited turn $2: $3 is stopped (its pane's client stopped,
# $4 1 when it was this pane's; the move runs on a later sweep), resumed (continued on its own home once that home's
# limit reset), helper (the helper named no account, or the new home's daemon did not take the thread, after the
# helper marked the home limited) or failed.
note_failover() {
  local updated
  updated=$(mktemp "$1.XXXXXX") || return 0
  if jq --arg turn "$2" --arg how "$3" --arg pane "${4:-}" --argjson at "$(date +%s)" '
      (if (.codexFailover // {}).turn == $turn then .codexFailover else {} end) as $was
      | .codexFailover = {turn: $turn, at: $at, moved: false, resumed: ($how == "resumed"),
          marked: ($how == "helper" or ($was.marked // false))}
        + if $how == "stopped" then {stage: "stopped", stoppedAt: $at, paneStopped: ($pane == "1")} else {} end' \
    "$1" >"$updated"; then
    mv -f "$updated" "$1"
  else
    rm -f "$updated"
  fi
}

# Reports once per (worker, text): a retry that changes nothing wakes no one.
once() {
  local record=$1 text=$2 updated
  [ "$(jq -r '.codexFailoverSaid // ""' "$record")" != "$text" ] || return 0
  updated=$(mktemp "$record.XXXXXX") || return 0
  if jq --arg text "$text" '.codexFailoverSaid = $text' "$record" >"$updated"; then mv -f "$updated" "$record"; else rm -f "$updated"; fi
  printf '%s\n' "$text"
}

# Takes the locks a change to worker record $1, still on thread $2, needs: the repository lock, then the worker lock
# unless this process holds it, and the caller's custody of the worker.
lock_owned_worker() {
  local root
  root=$(invoking_root)
  take_repository_lock "$root"
  if [ -z "${worker_lock:-}" ]; then lock_worker "$1" || return 1; fi
  worker_belongs "$1" "$root" "$(caller_claim "$root")" &&
    jq -e --arg id "$2" '.provider == "codex" and .id == $id' "$1" >/dev/null
}

# Points worker record $1 at home $4, the daemon there running its thread $2's limited turn's conversation, and leaves
# the steps still to run as flags: reopen its pane there ($5 true when failover stopped it) and tell it to continue. One
# write, so an interrupted sweep leaves either the old home or the new home with every step still owed. The caller holds
# the repository lock.
moved_to() {
  local updated
  updated=$(mktemp "$1.XXXXXX") || return 1
  if jq --arg turn "$2" --arg from "$3" --arg to "$4" --arg pane "$5" --argjson at "$(date +%s)" '
      .codexHome = $to
      | .codexFailover = {turn: $turn, at: $at, from: $from, moved: true, resumed: false, marked: true,
          paneStopped: ($pane == "true"), reopen: ($pane == "true"), continue: true, tries: 0}' "$1" >"$updated" &&
    mv -f "$updated" "$1"; then
    return 0
  fi
  rm -f "$updated"
  return 1
}

# Sets field $2 of worker record $1's failover to JSON $3 under the repository lock; the caller holds the worker lock.
set_failover() {
  local updated status=1
  take_repository_lock "$(invoking_root)"
  if updated=$(mktemp "$1.XXXXXX"); then
    if jq --arg key "$2" --argjson value "$3" '.codexFailover[$key] = $value' "$1" >"$updated" && mv -f "$updated" "$1"; then
      status=0
    else
      rm -f "$updated"
    fi
  fi
  release_repository_lock
  return "$status"
}

# Runs the steps a move of worker record $1 still owes, under its worker lock and on later sweeps too: reopens its
# pane on the new home (tried on three sweeps at most) and tells it to continue. The direction is sent once, and only
# while the limited turn is still the thread's latest with nothing queued or running behind it; one whose submission
# is not confirmed is left for the Anderton to check. Returns 10 when it ran a step.
finish_failover() {
  local record=$1 id name home from turn reopen cont tries note="" status said=""
  failover_fields() {
    IFS=$'\x1f' read -r id name home from turn reopen cont tries <<EOF
$(jq -r '[.id, .name, .codexHome, (.codexFailover.from // ""), (.codexFailover.turn // ""),
  (.codexFailover.reopen // false), (.codexFailover.continue // false), (.codexFailover.tries // 0)]
  | map(tostring) | join([31] | implode)' "$record")
EOF
  }
  failover_fields
  [ "$reopen" = true ] || [ "$cont" = true ] || return 0
  lock_owned_worker "$record" "$id" || return 0
  release_repository_lock
  # Read again under the lock: another sweep may have run the steps meanwhile.
  failover_fields
  [ "$reopen" = true ] || [ "$cont" = true ] || return 0
  tries=$((tries + 1))
  set_failover "$record" tries "$tries" || return 0
  from=${from:-its old account}
  if [ "$reopen" = true ]; then
    status=0
    note=$(reopen_pane "$record" "$home") || status=$?
    if [ "$status" -eq 0 ]; then
      note=${note:-Its pane shows it there.}
    else
      note="$note Open it with: CODEX_HOME=$home codex resume $id --remote unix://$(codex_socket "$home")"
    fi
    if [ "$status" -ne 1 ] || [ "$tries" -ge 3 ]; then set_failover "$record" reopen false || true; fi
  elif [ "$(jq -r '.codexFailover.paneStopped // empty' "$record")" != true ]; then
    note="Its pane did not show thread $id, so it was left alone. Open the thread with: CODEX_HOME=$home codex resume $id --remote unix://$(codex_socket "$home")"
  fi
  if [ "$cont" = true ]; then
    status=0
    "$scripts/codex-worker.py" still-limited "$record" "$turn" >/dev/null 2>&1 || status=$?
    if [ "$status" -eq 3 ]; then
      said="$name (Codex $id) moved from $from to $home, where its conversation has moved on since, so no direction to continue was sent. $note"
    elif [ "$status" -ne 0 ]; then
      # The daemon did not answer: nothing is known, so the step stays owed.
      if [ "$tries" -lt 3 ]; then
        once "$record" "$name (Codex $id) moved from $from to $home, whose daemon did not answer; telling it to continue is retried next sweep. $note"
        return 10
      fi
      said="$name (Codex $id) moved from $from to $home, whose daemon did not answer, so it was not told to continue. Tell it yourself. $note"
    elif "$scripts/codex-worker.py" message "$record" -- "$continue_text" >/dev/null 2>&1; then
      said="$name (Codex $id) hit the usage limit of $from and continues on $home. $note"
    else
      said="$name (Codex $id) moved from $from to $home, but its direction to continue is unconfirmed: check its status before resending. $note"
    fi
    set_failover "$record" continue false || true
  fi
  if [ -n "$said" ]; then
    once "$record" "$said"
  else
    once "$record" "$name (Codex $id) runs on $home. $note"
  fi
  return 10
}

# Moves Codex worker record $1, still on thread $2, whose latest turn failed at its account's usage limit, to the next
# account the account helper names, across sweeps so no sweep waits: the first stops the pane's client, a later one
# waits until the old daemon has let go of the thread (about a minute after its last client leaves), resumes it on the
# new home's daemon (both homes read one conversation store, so nothing is copied) and points the record there; the
# next sweep runs the steps finish_failover owes. The repository lock is held only for the record's writes. A move that could not run is retried: on the same home once its limit has reset, else once the
# helper names another home. Prints the outcome for the watch to report. Returns 10 when it changed something, so the
# sweep moves at most one worker.
failover() {
  local record=$1 id=$2 name from helper out to limited turn message marked start status stage stopped_at pane
  lock_owned_worker "$record" "$id" || return 0
  name=$(jq -r .name "$record") from=$(jq -r .codexHome "$record")
  limited=$("$scripts/codex-worker.py" limited "$record") || return 0
  turn=${limited%%$'\n'*} message=${limited#*$'\n'}
  marked=$(jq -r --arg turn "$turn" 'if .codexFailover.turn == $turn and .codexFailover.marked == true then "1" else "" end' "$record")
  stage=$(jq -r --arg turn "$turn" 'if .codexFailover.turn == $turn then .codexFailover.stage // "" else "" end' "$record")
  if ! helper=$(codex_accounts); then
    note_failover "$record" "$turn" failed
    once "$record" "$name (Codex $id) stays at the usage limit of $from: no Codex account helper is installed to move it."
    return 0
  fi
  if [ "$stage" != stopped ]; then
    if [ -n "$marked" ]; then
      status=0
      CODEX_HOME=$from "$helper" --is-limited </dev/null >/dev/null 2>&1 || status=$?
      if [ "$status" -eq 1 ]; then
        if "$scripts/codex-worker.py" message "$record" -- "$continue_text" >/dev/null 2>&1; then
          note_failover "$record" "$turn" resumed
          echo "$name (Codex $id) continues on $from, whose usage limit has reset."
        fi
        return 10
      fi
      if ! start=$(CODEX_HOME=$from "$helper" --start-home </dev/null 2>/dev/null) ||
        [ "$(cd "$start" 2>/dev/null && pwd -P)" = "$(cd "$from" && pwd -P)" ]; then
        note_failover "$record" "$turn" helper
        return 0
      fi
    fi
    # No client may start a turn on the old account while the thread moves. The stop is recorded first, so a sweep
    # cut short after it still reopens the pane.
    note_failover "$record" "$turn" stopped 1
    if ! stop_pane "$record"; then note_failover "$record" "$turn" stopped 0; fi
    return 10
  fi
  pane=$(jq -r '.codexFailover.paneStopped // false' "$record")
  stopped_at=$(jq -r '.codexFailover.stoppedAt // 0' "$record")
  release_repository_lock
  if ! "$scripts/codex-worker.py" unloaded "$record" >/dev/null 2>&1; then
    # A daemon unloads a thread about a minute after its last client leaves; one still loaded later has another client.
    [ "$(( $(date +%s) - stopped_at ))" -ge 180 ] || return 0
    [ "$pane" != true ] || reopen_pane "$record" "$from" >/dev/null || true
    note_failover "$record" "$turn" failed
    echo "$name (Codex $id) stays at the usage limit of $from: another Codex client still has thread $id open. Close it to let the move run."
    return 10
  fi
  # A sweep cut short after the new daemon took the thread left it open there: that move is recorded, not repeated.
  if to=$(codex_thread_home "$id") && [ "$to" != "$(cd "$from" 2>/dev/null && pwd -P)" ]; then
    lock_owned_worker "$record" "$id" || return 10
    moved_to "$record" "$turn" "$from" "$to" "$pane" || return 10
    release_repository_lock
    return 10
  fi
  if ! out=$(CODEX_HOME=$from "$helper" --move-thread "$id" --message "$message" </dev/null 2>&1) ||
    ! to=$(cd "$(printf '%s\n' "$out" | tail -n 1)" 2>/dev/null && pwd -P); then
    [ "$pane" != true ] || reopen_pane "$record" "$from" >/dev/null || true
    note_failover "$record" "$turn" helper
    once "$record" "$name (Codex $id) stays at the usage limit of $from: $(printf '%s\n' "$out" | tail -n 1)"
    return 10
  fi
  out=""
  if ! codex_daemon_up "$to" || ! out=$("$scripts/codex-worker.py" resume-on "$record" "$to" 2>&1); then
    [ "$pane" != true ] || reopen_pane "$record" "$from" >/dev/null || true
    note_failover "$record" "$turn" helper
    once "$record" "$name (Codex $id) stays on $from: $to did not take its thread. ${out:-Its Codex daemon did not start.}"
    return 10
  fi
  lock_owned_worker "$record" "$id" || return 10
  moved_to "$record" "$turn" "$from" "$to" "$pane" || return 10
  release_repository_lock
  return 10
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
  # Like a move, at most one owed step runs per sweep, and none when a move steps.
  finished=0
  for record; do
    acted=0
    (finish_failover "$record") || acted=$?
    if [ "$acted" -eq 10 ]; then finished=1; break; fi
  done
  limited=$(mktemp "${TMPDIR:-/tmp}/anderton-limited.XXXXXX")
  status=0
  ANDERTON_CODEX_LIMITED=$limited "$scripts/codex-worker.py" sweep "$@" || status=$?
  # At most one worker's move runs a step per sweep, so the sweep stays inside the watch's time; the rest are offered
  # again next sweep.
  while [ "$finished" -eq 0 ] && IFS=$'\t' read -r record thread; do
    [ -n "$record" ] || continue
    acted=0
    (failover "$record" "$thread") || acted=$?
    [ "$acted" -ne 10 ] || break
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
# Its pane shows a placeholder while the thread moves to another account; a turn started now would run on the old one.
if [ "$action" = message ] && jq -e '.codexFailover | . != null and .stage == "stopped" and .moved != true' "$record" >/dev/null; then
  echo "Codex worker '$2' is moving to another Codex account after a usage limit; message it once the watch reports it continues." >&2
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
