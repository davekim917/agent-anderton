#!/usr/bin/env bash
# Stop a worker spawn.sh started and remove the worktree it made for it. A worktree with uncommitted work, or
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
dir=$(jq -r .dir "$record")
root=$(jq -r .root "$record")
worktree=$(jq -r .worktree "$record")
id=$(jq -r '.id // empty' "$record")
launcher=$(jq -r '.launcher // "bg"' "$record")
tab=$(jq -r '.tab // empty' "$record")
socket=$(jq -r '.socket // empty' "$record")
server=$(jq -r '.server // empty' "$record")

# A worker that may still be running keeps its worktree: stop it, or confirm Claude Code no longer lists it.
if ! command -v claude >/dev/null 2>&1; then
  echo "retire.sh needs the claude CLI to stop '$name' first." >&2
  exit 1
fi
if [ "$launcher" != bg ]; then
  # A session in a herdr tab or tmux window has no id for claude stop; closing its tab or window ends it. Only
  # a tab or window place_state recognises as the worker's is closed, in the server it was opened in.
  if [ "$(place_state "$launcher" "$socket" "$tab" "$name" "$server")" = present ]; then
    case $launcher in
      herdr) HERDR_SOCKET_PATH="$socket" herdr tab close "$tab" >/dev/null 2>&1 || true ;;
      tmux) tmux -S "$socket" kill-window -t "$tab" >/dev/null 2>&1 || true ;;
    esac
  fi
  if ! worker_gone "$launcher" "$socket" "$tab" "$name" "$server"; then
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
  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    echo "Stopped '$name'. Kept $dir: it has uncommitted changes."
    exit 3
  fi
  if [ -n "$(git -C "$dir" rev-list -1 HEAD --not --remotes "$(jq -r .base "$record")" 2>/dev/null)" ]; then
    echo "Stopped '$name'. Kept $dir: it has commits no remote branch has."
    exit 3
  fi
  git -C "$root" worktree remove "$dir"
fi
if [ "$launcher" = bg ] && ! claude rm "$id" >/dev/null 2>&1; then
  echo "Stopped '$name' and removed its worktree, but claude rm $id failed; kept the record. Rerun to finish." >&2
  exit 1
fi
rm -f "$record"
echo "Retired '$name'."
