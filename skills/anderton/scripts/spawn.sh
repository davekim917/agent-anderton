#!/usr/bin/env bash
# Start a real Claude Code session to do one task: in its own worktree of the caller's repository (outside the
# checkout), in the caller's permission mode, told to report to the caller by name. Inside herdr it opens in a new
# tab, inside tmux in a new window, where the user can watch it and type into it; elsewhere, or with --bg, it runs
# in the background. $ANDERTON_START_WAIT (seconds, default 30) bounds the wait for a tmux worker to register.
# usage: spawn.sh --effort LEVEL [--bg] [--model M] [--mode MODE] [--base REF] <name> [brief-file]   (else the brief on stdin)
# Workers run on Opus unless --model names another. Worktrees go under $ANDERTON_WORKTREES, default the folder that holds the repository, as wt-<name>.
# Portable to macOS's bash 3.2 and BSD userland.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

require_tools spawn.sh
command -v claude >/dev/null 2>&1 || {
  echo "spawn.sh needs the claude CLI on PATH." >&2
  exit 1
}

usage="usage: spawn.sh --effort low|medium|high|xhigh|max [--bg] [--model M] [--mode MODE] [--base REF] <name: a-z 0-9 -> [brief-file]"
model="" effort="" mode="" base="" launcher=""
while [ $# -gt 0 ]; do
  case $1 in
    --bg) launcher="bg"; shift ;;
    --model | --effort | --mode | --base)
      [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }
      case $1 in
        --model) model=$2 ;;
        --effort) effort=$2 ;;
        --mode) mode=$2 ;;
        --base) base=$2 ;;
      esac
      shift 2
      ;;
    -*) echo "$usage" >&2; exit 2 ;;
    *) break ;;
  esac
done
name="${1:-}"
case $name in
  '' | -* | *[!a-z0-9-]*) echo "$usage" >&2; exit 2 ;;
esac
# Required so a worker never runs at the default just because nobody chose: the user's level, else the caller's
# judgment of the work.
case $effort in
  low | medium | high | xhigh | max) ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
if [ -n "${2:-}" ]; then brief=$(cat "$2"); else brief=$(cat); fi
if [ -z "$launcher" ]; then
  if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_WORKSPACE_ID:-}" ] && [ -n "${HERDR_SOCKET_PATH:-}" ] &&
    command -v herdr >/dev/null 2>&1; then
    launcher=herdr
  elif [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    launcher=tmux
  else
    launcher="bg"
  fi
fi
if [ -z "$(printf '%s' "$brief" | tr -d '[:space:]')" ]; then
  echo "spawn.sh: the brief is empty." >&2
  exit 2
fi

sid="${CLAUDE_CODE_SESSION_ID:?not running inside a Claude Code session}"
pid="${CLAUDE_PID:-$(session_pid "$sid")}"
if [ -z "$pid" ]; then
  echo "Cannot find the pid of session $sid under $sessions." >&2
  exit 1
fi
me=$(jq -r '.name // empty' "$sessions/$pid.json" 2>/dev/null || true)
if [ -z "$me" ]; then
  echo "This session has no name for the worker to report to. Name it with /rename, then rerun." >&2
  exit 1
fi

# A peer in another permission mode holds this session's messages for its user's approval, so the worker
# runs in this session's mode, which its transcript records on each prompt.
if [ -z "$mode" ]; then
  for t in "$home"/projects/*/"$sid".jsonl; do
    [ -e "$t" ] || continue
    mode=$(tail -n 2000 "$t" | jq -r 'select(.permissionMode != null) | .permissionMode' 2>/dev/null | tail -n 1)
    break
  done
fi
if [ -z "$mode" ]; then
  echo "Cannot read this session's permission mode from its transcript; pass --mode." >&2
  exit 1
fi

mkdir -p "$holders/workers"
record="$holders/workers/$name.json"
# Creating the record exclusively reserves the name, so two spawns of one name cannot both pass the checks below.
if ! (set -C && : > "$record") 2>/dev/null; then
  echo "A worker named '$name' was started before and not retired: run retire.sh $name first." >&2
  exit 1
fi
reserved=1
trap '[ -z "$reserved" ] || rm -f "$record"' EXIT
if claude agents --json 2>/dev/null | jq -e --arg n "$name" 'any(.[]; .name == $n)' >/dev/null; then
  echo "A live session is already named '$name'; pick another name." >&2
  exit 1
fi

root=$(invoking_root)
dir=$root
worktree=false
if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  if [ -z "$base" ]; then
    for ref in "$(git -C "$root" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)" origin/main origin/master HEAD; do
      if [ -n "$ref" ] && git -C "$root" rev-parse -q --verify "$ref^{commit}" >/dev/null; then
        base=$ref
        break
      fi
    done
  fi
  case $base in origin/*) git -C "$root" fetch -q origin 2>/dev/null || echo "spawn.sh: could not fetch origin; starting from the cached $base." >&2 ;; esac
  parent="${ANDERTON_WORKTREES:-$(dirname "$root")}"
  mkdir -p "$parent"
  parent=$(cd "$parent" && pwd -P)
  dir="$parent/wt-$name"
  if [ -e "$dir" ]; then
    echo "$dir already exists; pick another name." >&2
    exit 1
  fi
  git -C "$root" worktree add -q --detach "$dir" "$base"
  worktree=true
  base=$(git -C "$dir" rev-parse HEAD)
fi

brief="$brief

---
You are a worker the Anderton session \"$me\" started for the task above, in $dir.
- Message \"$me\" by SendMessage only when it changes what they do, one message per milestone, the kind as its first word:
  RESULT: a milestone done (PR ready, task finished), with its link and what you verified.
  QUESTION: a decision you need, with your recommendation.
  BLOCKED: what stops you and what would unblock it.
  ANSWER: a reply to something \"$me\" asked you.
  Never send acknowledgements, \"still waiting\" or \"holding\", restated instructions, or FYIs that change nothing: each message wakes \"$me\" and re-reads its whole context. A hook holds any message to \"$me\" without one of those four kinds, or one that repeats your last. Nobody reads this session, so a question left only in your reply is never answered.
- Give every sub-agent you start an explicit effort that fits its task (low for lookups and mechanical edits). Prefer a one-shot sub-agent that returns its result over a named one you keep alive and message for days. /orchestrate, if installed, does both.
- Do not deploy, restart a service, or message anyone off this machine unless the task says to; \"$me\" owns those."

write_record() {
  jq -nc --arg name "$name" --arg launcher "$launcher" --arg id "$id" --arg tab "$tab" --arg dir "$dir" --arg root "$root" \
    --arg socket "$socket" --arg server "$server" --arg base "$base" --arg spawner "$me" --argjson worktree "$worktree" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{name: $name, launcher: $launcher, id: $id, tab: $tab, socket: $socket, server: $server, dir: $dir, root: $root,
      base: $base, worktree: $worktree, spawner: $spawner, startedAt: $at}' >| "$record"
  reserved=""
}

failed() {
  [ -z "${1:-}" ] || echo "$1" >&2
  if [ "$worktree" = true ]; then git -C "$root" worktree remove --force "$dir"; fi
  rm -f "$record"
  exit 1
}

set -- -n "$name" --permission-mode "$mode" --effort "$effort" --model "${model:-opus}"
# A tab or window id is unique only within its server, so the record keeps which server it was opened in.
id="" tab="" socket="" server=""
if [ "$launcher" = herdr ]; then
  socket="${HERDR_SOCKET_PATH:-}"
  # A tab's or window's process takes its environment from its multiplexer, not from this script: a non-default
  # Claude home is passed on, or the worker would register where neither the caller nor these scripts look.
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    out=$(herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$dir" --label "$name" --no-focus \
      --env "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR" 2>&1) || failed "Could not open a herdr tab: $out"
  else
    out=$(herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$dir" --label "$name" --no-focus 2>&1) ||
      failed "Could not open a herdr tab: $out"
  fi
  tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null || true)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null || true)
  if [ -z "$tab" ] || [ -z "$pane" ]; then failed "herdr opened no tab: $out"; fi
  # Recorded as soon as the tab exists, so a spawn cut short still leaves retire.sh something to stop.
  write_record
  # A startup prompt (folder trust, a new permission mode) leaves the agent blocked: show it, then undo.
  if ! out=$(herdr agent start "$name" --kind claude --pane "$pane" --timeout 120000 -- "$@" 2>&1) ||
    ! out=$(herdr agent prompt "$name" "$brief" 2>&1); then
    screen=$(herdr agent read "$name" 2>/dev/null | tail -n 20 || true)
    herdr tab close "$tab" >/dev/null 2>&1 || true
    if ! worker_gone herdr "$socket" "$tab" "$name"; then
      echo "Claude Code in herdr tab '$name' did not take the brief: $out
$screen
It is not confirmed stopped, so $dir and its record are kept: close tab $tab, then run retire.sh $name." >&2
      exit 1
    fi
    failed "Claude Code in herdr tab '$name' did not take the brief: $out
$screen
Rerun with --bg to start it in the background instead."
  fi
  where="herdr tab '$name' ($tab)"
elif [ "$launcher" = tmux ]; then
  socket="${TMUX%%,*}"
  server=$(printf '%s' "$TMUX" | cut -d, -f2)
  # Given as separate arguments, the window's command runs without a shell, so the brief needs no quoting.
  set -- claude "$@" "$brief"
  [ -z "${CLAUDE_CONFIG_DIR:-}" ] || set -- -e "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR" "$@"
  out=$(tmux new-window -d -P -F '#{window_id}' -n "$name" -c "$dir" "$@" 2>&1) ||
    failed "Could not open a tmux window: $out"
  tab=$(printf '%s\n' "$out" | grep -E '^@[0-9]+$' | tail -n 1 || true)
  [ -n "$tab" ] || failed "tmux opened no window: $out"
  write_record
  # The window closes when claude exits, so a worker that never registers and has no window failed to start.
  listed="" tries=$(( ${ANDERTON_START_WAIT:-30} * 2 ))
  while [ "$tries" -gt 0 ]; do
    if claude agents --json 2>/dev/null | jq -e --arg n "$name" 'any(.[]; .name == $n)' >/dev/null 2>&1; then
      listed=1
      break
    fi
    if [ "$(place_state tmux "$socket" "$tab" "$name" "$server")" = absent ]; then
      failed "Claude Code exited at once in tmux window '$name'."
    fi
    tries=$((tries - 1))
    sleep 0.5
  done
  where="tmux window '$name' ($tab)"
  [ -n "$listed" ] || echo "Worker '$name' has not registered yet: it may be waiting at a startup prompt in its window." >&2
else
  out=$(cd "$dir" && claude --bg "$@" "$brief" 2>&1) || failed "$out"
  # `claude stop` and `claude rm` take the session's id, not its name.
  id=$(claude agents --json 2>/dev/null | jq -r --arg n "$name" 'first(.[] | select(.name == $n) | .id) // empty' 2>/dev/null || true)
  [ -n "$id" ] || id=$(printf '%s\n' "$out" | sed -n 's/^backgrounded · \([0-9a-f]*\) · .*/\1/p' | head -n 1)
  printf '%s\n' "$out"
  where="the background (${id:-id unknown})"
fi

write_record
echo "Started worker '$name' in $where, in $dir ($mode). It reports to '$me'."
