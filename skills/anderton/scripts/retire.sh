#!/usr/bin/env bash
# Stop a worker spawn.sh started and remove the worktree it made for it, or release a session adopt.sh adopted, which
# keeps running and stops reporting to its Anderton. A worktree with uncommitted work, or
# commits since it started that no remote branch has, is kept and the worker stays recorded: push or discard
# that work, then rerun.
# usage: retire.sh <name>   Exit 0: retired. Exit 3: stopped, worktree kept.
# Portable to macOS's bash 3.2 and BSD userland.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

require_tools retire.sh
name="${1:-}"
case $name in
  '' | -* | *[!a-z0-9-]*) echo "usage: retire.sh <name>" >&2; exit 2 ;;
esac
record="$holders/workers/$name.json"
if [ ! -f "$record" ]; then
  echo "No worker named '$name' was started by spawn.sh; nothing to retire." >&2
  exit 1
fi
provider=$(jq -r '.provider // "claude"' "$record")
mixed=""
if [ "$(invoking_provider)" = codex ] || [ "$(jq -r '.spawnerProvider // "claude"' "$record")" = codex ]; then mixed=1; fi
if [ "$provider" = codex ] || [ -n "$mixed" ]; then
  take_repository_lock "$(invoking_root)"
  lock_worker "$record"
fi
dir=$(jq -r .dir "$record")
root=$(jq -r .root "$record")
worktree=$(jq -r .worktree "$record")
id=$(jq -r '.id // empty' "$record")
launcher=$(jq -r '.launcher // "bg"' "$record")
tab=$(jq -r '.tab // empty' "$record")
pane=$(jq -r '.pane // empty' "$record")
socket=$(jq -r '.socket // empty' "$record")
server=$(jq -r '.server // empty' "$record")
label=$(jq -r '.label // empty' "$record")
label=${label:-$name}

if [ -n "$mixed" ] && ! worker_belongs "$record" "$(invoking_root)" "$(caller_claim "$(invoking_root)")"; then
  echo "This Anderton does not own worker '$name'." >&2
  exit 1
fi
if [ "$(jq -r '.adopted // false' "$record")" = true ]; then
  if [ "$provider" = codex ]; then
    if ! worker_belongs "$record" "$(invoking_root)" "$(caller_claim "$(invoking_root)")"; then
      echo "This Anderton does not own worker '$name'." >&2
      exit 1
    fi
    if jq -e '.codexDirection != null or ((.codexDirections // []) | length > 0)' "$record" >/dev/null &&
      ! "$anderton_scripts/codex-worker.py" inactive "$record" --directions-only --prune; then
      echo "Codex worker '$name' may have an undelivered direction. Inspect its thread before retiring." >&2
      exit 1
    fi
  fi
  spawner=$(jq -r '.spawner // "its Anderton"' "$record")
  rm -f "$record"
  echo "Released '$name': it keeps running and no longer reports to $spawner."
  exit 0
fi

# The Codex worker's pane, by the id spawn.sh recorded, wherever it now lives: "present <title>", gone, or unknown. A
# tmux pane id counts only in the server process it was opened in, since a restarted server reuses ids.
codex_pane() {
  local out
  case $launcher in
    herdr)
      out=$(HERDR_SOCKET_PATH="$socket" herdr pane get "$pane" 2>&1) || true
      printf '%s' "$out" | jq -r 'if .error.code == "pane_not_found" or .error.code == "server_not_running" then "gone"
        elif (.result.pane.terminal_title | type) == "string" then "present " + .result.pane.terminal_title else "unknown" end' \
        2>/dev/null || echo unknown
      ;;
    tmux)
      if out=$(tmux -S "$socket" list-panes -a -F '#{pid} #{pane_id} #{pane_title}' 2>&1); then
        printf '%s\n' "$out" | awk -v p="$server" -v id="$pane" '
          $1 == p && $2 == id { sub(/^[^ ]* [^ ]* ?/, ""); print "present " $0; f = 1; exit }
          END { if (!f) print "gone" }'
      else
        case $out in *"no server running"* | *"No such file or directory"*) echo gone ;; *) echo unknown ;; esac
      fi
      ;;
    *) echo unknown ;;
  esac
}
# True when codex_pane's answer $1 is the pane titled as Codex titles the recorded thread: its id cut to 29 characters
# and "...", after "Action Required | " while it waits on the user.
shows_thread() {
  [ ${#id} -ge 29 ] || return 1
  case $1 in "present ${id:0:29}..." | "present "*" | ${id:0:29}...") return 0 ;; esac
  return 1
}

mixed_claude_pane() {
  local registry sid pid listed pane_pid
  registry=$(live_claude_worker "$record")
  case $registry in '' | *$'\n'*) return 1 ;; esac
  sid=$(jq -r .sessionId "$registry")
  pid=$(jq -r .pid "$registry")
  case $launcher in
    herdr)
      listed=$(HERDR_SOCKET_PATH="$socket" herdr agent list 2>/dev/null) || return 1
      printf '%s' "$listed" | jq -e --arg sid "$sid" --arg pane "$pane" '
        [.result.agents[]? | select(.agent_session.value == $sid) | .pane_id] == [$pane]' >/dev/null
      ;;
    tmux)
      listed=$(tmux -S "$socket" list-panes -a -F '#{pid} #{pane_id} #{pane_pid}' 2>/dev/null) || return 1
      pane_pid=$(printf '%s\n' "$listed" | awk -v p="$server" -v id="$pane" '$1 == p && $2 == id {print $3}')
      [ -n "$pane_pid" ] && has_ancestor "$pid" "$pane_pid"
      ;;
    *) return 1 ;;
  esac
}

mixed_claude_gone() {
  local listed sid entry pid cwd
  sid=$(jq -r '.claudeSession.id // empty' "$record")
  for entry in "$sessions"/*.json; do
    [ -f "$entry" ] || continue
    cwd=$(jq -r '.cwd // empty' "$entry" 2>/dev/null) || continue
    case $cwd in "$dir" | "$dir"/*) ;; *) continue ;; esac
    pid=$(jq -r '.pid // empty' "$entry" 2>/dev/null) || continue
    if [ -n "$pid" ] && registered_alive "$pid" "$(jq -r '.startedAt // empty | floor' "$entry")" \
      "$(jq -r '.procStart // empty' "$entry")"; then
      return 1
    fi
  done
  listed=$(claude agents --json 2>/dev/null) || return 1
  printf '%s' "$listed" | jq -e --arg sid "$sid" --arg dir "$dir" '
    type == "array" and all(.[];
      ($sid == "" or .sessionId != $sid) and
      ((.cwd // "") as $cwd | $cwd != $dir and ($cwd | startswith($dir + "/") | not)))' >/dev/null
}

# A worker that may still be running keeps its worktree: stop it, or confirm Claude Code no longer lists it.
if [ "$provider" = codex ]; then
  scripts=$(cd "$(dirname "$0")" && pwd)
  # Read whole, not piped into grep -q: grep would exit at the match, and pipefail would read the lister's SIGPIPE
  # as "not owned".
  owned=""
  while IFS= read -r r; do
    if [ "$r" = "$record" ]; then owned=1; fi
  done <<EOF
$("$scripts/waiting.sh" --codex-workers)
EOF
  if [ -z "$owned" ]; then
    echo "This Anderton does not own Codex worker '$name'." >&2
    exit 1
  fi
  if ! "$scripts/codex-worker.py" inactive "$record" --prune; then
    echo "Codex worker '$name' may still be running or have an undelivered direction. Inspect its thread before retiring." >&2
    exit 1
  fi
elif ! command -v claude >/dev/null 2>&1; then
  echo "retire.sh needs the claude CLI to stop '$name' first." >&2
  exit 1
fi
if [ "$launcher" != bg ] && [ "$provider" = codex ]; then
  # The user can split a Codex worker's tab, move its pane, or open another conversation in it (/resume), and no daemon
  # request says which thread a client shows: only the recorded pane is closed, and only while titled with its thread.
  refuse_pane() {
    echo "Codex worker '$name': $1, so it was not closed. Close it yourself once nothing in it needs keeping, then rerun." >&2
    exit 1
  }
  if [ -z "$pane" ]; then
    # Without a pane id only the tab says whether it still runs, and a tab the user renamed still does: place_state
    # reads its new label as absent, so a tab id still standing in the same server refuses too.
    if [ "$(place_state "$launcher" "$socket" "$tab" "$label" "$server")" != absent ] || case $launcher in
      herdr) HERDR_SOCKET_PATH="$socket" herdr tab get "$tab" 2>/dev/null | jq -e '.result.tab.label | type == "string"' >/dev/null 2>&1 ;;
      tmux) tmux -S "$socket" list-windows -a -F '#{pid} #{window_id} #{window_name}' 2>/dev/null |
        awk -v p="$server" -v w="$tab" '$1 == p && $2 == w { f = 1 } END { exit !f }' ;;
      *) false ;;
    esac; then
      echo "Codex worker '$name' was recorded without its pane, and $launcher tab $tab still exists, maybe renamed. It may also be an unrelated tab that took the id after a $launcher restart, and closing that would end someone else's work. Its record and worktree are left in place: tell the user." >&2
      exit 1
    fi
  elif now=$(codex_pane) && [ "$now" != gone ]; then
    shows_thread "$now" ||
      refuse_pane "its $launcher pane $pane does not show thread ${id:-(none registered)} (another conversation was opened there, Codex left it, or $launcher cannot say)"
    # The check above took time: a direction or a turn that started since stops the close.
    "$scripts/codex-worker.py" inactive "$record" || refuse_pane "thread $id became active while retiring"
    # The last read before the close, after the slow daemon call: only a change made after it goes unseen.
    now=$(codex_pane)
    if [ "$now" != gone ]; then
      shows_thread "$now" || refuse_pane "its $launcher pane $pane changed while retiring"
      case $launcher in
        herdr) HERDR_SOCKET_PATH="$socket" herdr pane close "$pane" >/dev/null 2>&1 || true ;;
        tmux) tmux -S "$socket" kill-pane -t "$pane" >/dev/null 2>&1 || true ;;
      esac
    fi
  fi
  if { [ -n "$pane" ] && [ "$(codex_pane)" != gone ]; } || ! "$scripts/codex-worker.py" inactive "$record"; then
    echo "Could not confirm '$name' stopped ($launcher pane ${pane:-(none recorded)} in ${socket:-(no server recorded)}); kept its worktree and record." >&2
    exit 1
  fi
elif [ "$launcher" != bg ] && [ -n "$mixed" ] && [ -n "$pane" ]; then
  current=$(codex_pane)
  if [ "$current" != gone ]; then
    if ! mixed_claude_pane; then
      echo "Could not verify '$name' still runs in its original pane. Close it directly, then retry." >&2
      exit 1
    fi
    case $launcher in
      herdr) HERDR_SOCKET_PATH="$socket" herdr pane close "$pane" >/dev/null 2>&1 || true ;;
      tmux) tmux -S "$socket" kill-pane -t "$pane" >/dev/null 2>&1 || true ;;
    esac
  fi
  if [ "$(codex_pane)" != gone ] || ! session_gone "$name" || ! mixed_claude_gone; then
    echo "Could not confirm '$name' stopped; kept its worktree and record." >&2
    exit 1
  fi
elif [ "$launcher" != bg ]; then
  if [ -n "$mixed" ]; then
    if ! worker_gone "$launcher" "$socket" "$tab" "$name" "$server" "$label" || ! mixed_claude_gone; then
      echo "The worker's exact pane was never recorded. Close it directly, then retry once the tab is gone." >&2
      exit 1
    fi
  fi
  # A session in a herdr tab or tmux window has no id for claude stop; closing its tab or window ends it. Only
  # a tab or window place_state recognises as the worker's is closed, in the server it was opened in.
  if [ -z "$mixed" ] && [ "$(place_state "$launcher" "$socket" "$tab" "$label" "$server")" = present ]; then
    case $launcher in
      herdr) HERDR_SOCKET_PATH="$socket" herdr tab close "$tab" >/dev/null 2>&1 || true ;;
      tmux) tmux -S "$socket" kill-window -t "$tab" >/dev/null 2>&1 || true ;;
    esac
  fi
  if ! worker_gone "$launcher" "$socket" "$tab" "$name" "$server" "$label"; then
    echo "Could not confirm '$name' stopped ($launcher ${tab:-(no id recorded)} in ${socket:-(no server recorded)}); kept its worktree and record." >&2
    exit 1
  fi
else
  if [ -z "$id" ]; then
    echo "The record for '$name' has no session id; stop it by hand (claude agents), then rerun." >&2
    exit 1
  fi
  if ! claude stop "$id" >/dev/null 2>&1; then
    if ! listed=$(claude agents --json 2>/dev/null) ||
      ! printf '%s' "$listed" | jq -e --arg id "$id" 'all(.[]; .id != $id)' >/dev/null 2>&1; then
      echo "Could not stop '$name' ($id), and it is not confirmed gone; kept its worktree and record." >&2
      exit 1
    fi
  fi
fi

if [ "$worktree" = true ] && [ -d "$dir" ]; then
  case $(worktree_work "$dir" "$(jq -r '.base // empty' "$record")") in
    uncommitted) echo "Stopped '$name'. Kept $dir: it has uncommitted changes."; exit 3 ;;
    unpushed) echo "Stopped '$name'. Kept $dir: it has commits no remote branch has."; exit 3 ;;
    flagged) echo "Stopped '$name'. Kept $dir: git marks files in it assume-unchanged or skip-worktree (as a sparse checkout does), so status cannot show their edits. Remove it yourself once nothing in it needs keeping."; exit 3 ;;
    unreadable) echo "Stopped '$name'. Kept $dir: git could not read its status or compare it with its base and remotes."; exit 3 ;;
  esac
  git -C "$root" worktree remove "$dir"
fi
if [ "$launcher" = bg ] && ! claude rm "$id" >/dev/null 2>&1; then
  echo "Stopped '$name' and removed its worktree, but claude rm $id failed; kept the record. Rerun to finish." >&2
  exit 1
fi
rm -f "$record"
# Earlier versions kept a last-report file beside each worker record.
find "$holders/workers" -maxdepth 1 -name '*.last-report' -exec rm -f {} + 2>/dev/null || true
echo "Retired '$name'."
