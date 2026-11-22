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
if [ "$provider" = codex ]; then lock_codex_worker "$record"; fi
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

if [ "$(jq -r '.adopted // false' "$record")" = true ]; then
  spawner=$(jq -r '.spawner // "its Anderton"' "$record")
  rm -f "$record"
  echo "Released '$name': it keeps running and no longer reports to $spawner. Tell it so by SendMessage."
  exit 0
fi

# shows_thread <thread id>: true when the worker's tab or window holds one pane, the worker's, titled as Codex titles
# that thread: its id cut to 29 characters and "...", after "Action Required | " while it waits on the user. A tab
# that also holds another pane, or a pane moved out of it, would have that other pane closed with the tab.
shows_thread() {
  local titles prefix
  [ ${#1} -ge 29 ] || return 1
  prefix="${1:0:29}..."
  case $launcher in
    herdr)
      titles=$(HERDR_SOCKET_PATH="$socket" herdr pane list 2>/dev/null | jq -r --arg tab "$tab" --arg pane "$pane" \
        '[.result.panes[]? | select(.tab_id == $tab)] | if length == 1 and .[0].pane_id == $pane then .[0].terminal_title // "" else error("not one pane") end' \
        2>/dev/null) || return 1
      ;;
    tmux) titles=$(tmux -S "$socket" list-panes -t "$tab" -F '#{pane_title}' 2>/dev/null) || return 1 ;;
    *) return 1 ;;
  esac
  case $titles in
    *"
"*) return 1 ;;
    "$prefix" | *" | $prefix") return 0 ;;
  esac
  return 1
}

# renamed: true when the worker's tab or window id still stands in its server under another label. place_state reads
# that as absent, since a restarted server reuses ids, but a Codex worker's tab renamed by the user still runs it.
renamed() {
  case $launcher in
    herdr) HERDR_SOCKET_PATH="$socket" herdr tab get "$tab" 2>/dev/null | jq -e --arg n "$label" '.result.tab.label | type == "string" and . != $n' >/dev/null 2>&1 ;;
    tmux)
      tmux -S "$socket" list-windows -a -F '#{pid} #{window_id} #{window_name}' 2>/dev/null |
        awk -v p="$server" -v w="$tab" '$1 == p && $2 == w { f = 1 } END { exit !f }'
      ;;
    *) return 1 ;;
  esac
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
  if ! "$scripts/codex-worker.py" inactive "$record"; then
    echo "Codex worker '$name' may still be running or have an undelivered direction. Inspect its thread before retiring." >&2
    exit 1
  fi
elif ! command -v claude >/dev/null 2>&1; then
  echo "retire.sh needs the claude CLI to stop '$name' first." >&2
  exit 1
fi
if [ "$launcher" != bg ]; then
  # A session in a herdr tab or tmux window has no id for claude stop; closing its tab or window ends it. Only
  # a tab or window place_state recognises as the worker's is closed, in the server it was opened in.
  state=$(place_state "$launcher" "$socket" "$tab" "$label" "$server")
  if [ "$provider" = codex ] && [ "$state" = absent ] && renamed; then
    echo "Codex worker '$name': its $launcher tab $tab is still open under another name, so it may still run a conversation in $dir. Close it yourself once nothing in it needs keeping, then rerun." >&2
    exit 1
  fi
  if [ "$state" = present ]; then
    # The user can open another conversation in a Codex tab (/resume, /new), which leaves the recorded thread idle
    # and the tab running, and no daemon request says which thread a tab shows. spawn.sh has Codex title the tab with
    # its thread id, which Codex cuts to 29 characters, so only a tab still showing the recorded thread is closed.
    if [ "$provider" = codex ] && ! shows_thread "$id"; then
      echo "Codex worker '$name': its $launcher tab $tab does not hold just the worker's pane showing thread ${id:-(none registered)} (another conversation was opened there, a pane was split off or moved, or Codex left it), so it was not closed. Close it yourself once nothing in it needs keeping, then rerun." >&2
      exit 1
    fi
    # The check above took time: a direction or a turn that started since stops the close.
    if [ "$provider" = codex ] && ! "$scripts/codex-worker.py" inactive "$record"; then
      echo "Codex worker '$name' became active while retiring; its tab was left open." >&2
      exit 1
    fi
    case $launcher in
      herdr) HERDR_SOCKET_PATH="$socket" herdr tab close "$tab" >/dev/null 2>&1 || true ;;
      tmux) tmux -S "$socket" kill-window -t "$tab" >/dev/null 2>&1 || true ;;
    esac
  fi
  if [ "$provider" = codex ]; then
    stopped() {
      [ "$(place_state "$launcher" "$socket" "$tab" "$label" "$server")" = absent ] &&
        "$scripts/codex-worker.py" inactive "$record"
    }
  else
    stopped() { worker_gone "$launcher" "$socket" "$tab" "$name" "$server" "$label"; }
  fi
  if ! stopped; then
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
