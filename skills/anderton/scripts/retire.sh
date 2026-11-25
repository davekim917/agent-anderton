#!/usr/bin/env bash
# Stop a worker spawn.sh started and remove the worktree it made for it, or release a session adopt.sh adopted, which
# keeps running and stops reporting to its Anderton. A worktree with uncommitted work, or
# commits since it started that no remote branch has, is kept and the worker stays recorded: push or discard
# that work, then rerun.
# Before closing anything it reads the worker's conversation: a message there since its last report to its Anderton, from
# anyone but that Anderton (the user in its tab, a voice relay, another session), holds the retirement, and so does a
# conversation it cannot read. The hold is written beside the record for waiting.sh to list until it is cleared.
# usage: retire.sh <name> [--reviewed-through <ISO time>]   Exit 0: retired. Exit 3: stopped, worktree kept.
# Exit 4: held for messages since the last report; --reviewed-through clears those up to that time.
# Portable to macOS's bash 3.2 and BSD userland.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

require_tools retire.sh
usage() { echo "usage: retire.sh <name> [--reviewed-through <ISO time>]" >&2; exit 2; }
name="${1:-}"
case $name in
  '' | -* | *[!a-z0-9-]*) usage ;;
esac
shift
reviewed=""
while [ $# -gt 0 ]; do
  case $1 in
    --reviewed-through) [ $# -ge 2 ] || usage; reviewed=$2; shift 2 ;;
    *) usage ;;
  esac
done
if [ -n "$reviewed" ] && ! out=$("$anderton_scripts/claude-worker.py" reviewed-time "$reviewed" 2>&1); then
  echo "${out#Claude worker: }" >&2
  exit 2
fi
record="$holders/workers/$name.json"
if [ ! -f "$record" ]; then
  echo "No worker named '$name' was started by spawn.sh; nothing to retire." >&2
  exit 1
fi
provider=$(jq -r '.provider // "claude"' "$record")
mixed=""
if [ "$(invoking_provider)" = codex ] || [ "$(jq -r '.spawnerProvider // "claude"' "$record")" = codex ]; then mixed=1; fi
if [ "$provider" = codex ] || [ "$provider" = agy ] || [ -n "$mixed" ] ||
  jq -e '.claudeLaunchId != null' "$record" >/dev/null 2>&1; then
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

if { [ -n "$mixed" ] || [ "$provider" = agy ]; } && ! worker_belongs "$record" "$(invoking_root)" "$(caller_claim "$(invoking_root)")"; then
  echo "This Anderton does not own worker '$name'." >&2
  exit 1
fi
if [ "$(jq -r '.adopted // false' "$record")" = true ]; then
  if [ "$provider" = codex ]; then
    if ! worker_belongs "$record" "$(invoking_root)" "$(caller_claim "$(invoking_root)")"; then
      echo "This Anderton does not own worker '$name'." >&2
      exit 1
    fi
    if jq -e '.codexDirection != null or any(.codexDirections[]?; .neverArrived != true)' "$record" >/dev/null &&
      ! "$anderton_scripts/codex-worker.py" inactive "$record" --directions-only --prune; then
      echo "Codex worker '$name' may have an undelivered direction. Check its status before retiring." >&2
      exit 1
    fi
  fi
  spawner=$(jq -r '.spawner // "its Anderton"' "$record")
  emit_worker_done "$record"
  rm -f "$record"
  echo "Released '$name': it keeps running and no longer reports to $spawner."
  exit 0
fi

# hold <why> [messages JSON] [advice]: records the hold for waiting.sh and refuses. What is recorded stays the same
# across retries, so the watch tells it once.
hold_file="${record%.json}.held"
hold() {
  local updated messages=${2:-[]}
  updated=$(mktemp "$hold_file.XXXXXX")
  jq -n --arg name "$name" --arg why "$1" --argjson messages "$messages" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{name: $name, why: $why, heldAt: $at, messages: $messages}' > "$updated" && mv -f "$updated" "$hold_file"
  {
    echo "Not retiring '$name': $1"
    if [ "$messages" != "[]" ]; then
      printf '%s' "$messages" | jq -r '.[] | "  \(.at)  \(.from): \(.line)"'
      echo "Read them first. If nothing in them is still open, run: retire.sh $name --reviewed-through $(printf '%s' "$messages" | jq -r '[.[].at] | max')"
    else
      echo "${3:-Read it yourself}, then run: retire.sh $name --reviewed-through $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi
  } >&2
  exit 4
}
# conversation_gate: holds the retirement when the worker's conversation has a message since its last report from anyone
# but its Anderton, or cannot be read. Run before anything is closed, and again just before the close, so a message that
# arrives while retire.sh works holds it too.
conversation_gate() {
  local check errors status=0 found error
  case $provider in
    agy)
      [ -n "$reviewed" ] || hold "agy keeps no transcript these scripts read, so nothing shows what it was told since its last report." "[]" "Read its pane"
      return 0
      ;;
    codex) check=("$anderton_scripts/codex-worker.py" inbound-since-report "$record") ;;
    *) check=("$anderton_scripts/claude-worker.py" inbound-since-report "$record" --home "$home") ;;
  esac
  if [ -n "$reviewed" ]; then check+=(--reviewed-through "$reviewed"); fi
  errors=$(mktemp "$hold_file.err.XXXXXX")
  found=$("${check[@]}" 2>"$errors") || status=$?
  error=$(head -c 400 "$errors")
  rm -f "$errors"
  case $status in
    0) rm -f "$hold_file" ;;
    4) hold "it has messages since its last report to its Anderton, from someone other than that Anderton:" "$(printf '%s' "$found" | jq -c '.messages')" ;;
    *)
      [ -n "$reviewed" ] || hold "its conversation could not be read (${error:-no reason given}), so nothing shows it has no messages since its last report." "[]" "Read its conversation yourself"
      if [ -z "$unread_noted" ]; then
        echo "Its conversation could not be read (${error:-no reason given}); retiring on your review through $reviewed alone." >&2
        unread_noted=1
      fi
      ;;
  esac
}
unread_noted=""
conversation_gate

mixed_claude_pane() {
  local registry sid pid
  registry=$(live_claude_worker "$record")
  case $registry in '' | *$'\n'*) return 1 ;; esac
  sid=$(jq -r .sessionId "$registry")
  pid=$(jq -r .pid "$registry")
  claude_in_worker_pane "$record" "$sid" "$pid"
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
    echo "Codex worker '$name' may still be running or have an undelivered direction. Check its status before retiring." >&2
    exit 1
  fi
elif [ "$provider" != agy ] && ! command -v claude >/dev/null 2>&1; then
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
  elif now=$(codex_pane "$launcher" "$socket" "$pane" "$server") && [ "$now" != gone ]; then
    shows_thread "$now" "$id" ||
      refuse_pane "its $launcher pane $pane does not show thread ${id:-(none registered)} (another conversation was opened there, Codex left it, or $launcher cannot say)"
    # A turn typed and finished since the first read leaves the thread inactive again: its conversation is read again.
    conversation_gate
    # Those checks took time: a direction or a turn that started since, even during that read, stops the close.
    "$scripts/codex-worker.py" inactive "$record" || refuse_pane "thread $id became active while retiring"
    # The last read before the close, after the slow daemon call: only a change made after it goes unseen.
    now=$(codex_pane "$launcher" "$socket" "$pane" "$server")
    if [ "$now" != gone ]; then
      shows_thread "$now" "$id" || refuse_pane "its $launcher pane $pane changed while retiring"
      case $launcher in
        herdr) HERDR_SOCKET_PATH="$socket" herdr pane close "$pane" >/dev/null 2>&1 || true ;;
        tmux) tmux -S "$socket" kill-pane -t "$pane" >/dev/null 2>&1 || true ;;
      esac
    fi
  fi
  if { [ -n "$pane" ] && [ "$(codex_pane "$launcher" "$socket" "$pane" "$server")" != gone ]; } || ! "$scripts/codex-worker.py" inactive "$record"; then
    echo "Could not confirm '$name' stopped ($launcher pane ${pane:-(none recorded)} in ${socket:-(no server recorded)}); kept its worktree and record." >&2
    exit 1
  fi
  # The record names one home's daemon; the thread may have been opened on another account's since.
  if [ -n "$id" ] && held=$(codex_thread_home "$id") && [ "$held" != "$(cd "$(jq -r .codexHome "$record")" 2>/dev/null && pwd -P)" ]; then
    echo "'$name' (Codex $id) is open on $held's daemon, not the home its record names; kept its worktree and record." >&2
    exit 1
  fi
elif [ "$provider" = agy ]; then
  # Only the recorded pane is closed, and only while herdr shows the agy spawn.sh started there, idle.
  agy_check "$record"
  case $agy_state in
    running)
      case $agy_status in
        idle | done) ;;
        *) echo "agy worker '$name' is not idle (herdr says: ${agy_status:-nothing}). Retire it once it is." >&2; exit 1 ;;
      esac
      HERDR_SOCKET_PATH="$socket" herdr pane close "$pane" >/dev/null 2>&1 || true
      ;;
    gone) ;;
    elsewhere)
      echo "agy worker '$name': herdr pane $pane does not show it as recorded (it exited, or something else runs there). Close the pane yourself once nothing in it needs keeping, then rerun." >&2
      exit 1
      ;;
    *)
      echo "agy worker '$name': herdr could not say what runs in pane ${pane:-(none recorded)}; kept its worktree and record." >&2
      exit 1
      ;;
  esac
  # agy takes a few seconds to exit once its pane is closed.
  for _ in $(seq 1 30); do
    agy_check "$record"
    [ "$agy_state" != gone ] || break
    sleep 0.5
  done
  if [ "$agy_state" != gone ]; then
    echo "Could not confirm agy worker '$name' stopped (herdr pane $pane); kept its worktree and record." >&2
    exit 1
  fi
elif [ "$launcher" != bg ] && [ -n "$mixed" ] && [ -n "$pane" ]; then
  current=$(codex_pane "$launcher" "$socket" "$pane" "$server")
  if [ "$current" != gone ]; then
    if ! mixed_claude_pane; then
      echo "Could not verify '$name' still runs in its original pane. Close it directly, then retry." >&2
      exit 1
    fi
    conversation_gate
    case $launcher in
      herdr) HERDR_SOCKET_PATH="$socket" herdr pane close "$pane" >/dev/null 2>&1 || true ;;
      tmux) tmux -S "$socket" kill-pane -t "$pane" >/dev/null 2>&1 || true ;;
    esac
  fi
  if [ "$(codex_pane "$launcher" "$socket" "$pane" "$server")" != gone ] || ! session_gone "$name" || ! mixed_claude_gone; then
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
    conversation_gate
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
  conversation_gate
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
emit_worker_done "$record"
rm -f "$record" "${record%.json}.agy-config" "$hold_file"
# Earlier versions kept a last-report file beside each worker record.
find "$holders/workers" -maxdepth 1 -name '*.last-report' -exec rm -f {} + 2>/dev/null || true
echo "Retired '$name'."
