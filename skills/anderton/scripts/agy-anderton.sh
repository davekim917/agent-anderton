#!/usr/bin/env bash
# Opens agy as an Anderton in the current herdr pane: the agy on PATH, guarded as agy workers are, with the identity its
# tool shells need to claim the role (claim.sh, with --project for a named project) and to run the other scripts.
# Without -i/--prompt-interactive it starts agy on a prompt that points it at the Anderton skill. Without --mode it runs
# as agy workers do, with no permission prompts and the guard as the gate.
# usage: agy-anderton.sh --name <name> [agy options]
# Portable to macOS's bash 3.2 and BSD userland.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

usage="usage: agy-anderton.sh --name <name: letters, digits, '.', '_' or '-'> [agy options]"
[ "${1:-}" = --name ] && [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }
name=$2
shift 2
case $name in '' | -* | *[!A-Za-z0-9._-]*) echo "$usage" >&2; exit 2 ;; esac
if [ "${HERDR_ENV:-}" != 1 ] || [ -z "${HERDR_PANE_ID:-}" ] || [ -z "${HERDR_SOCKET_PATH:-}" ]; then
  echo "Open an agy Anderton from a herdr pane: its watch tells it what it hears by prompting that pane." >&2
  exit 2
fi
command -v agy >/dev/null 2>&1 || { echo "agy-anderton.sh needs the agy CLI on PATH." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "agy-anderton.sh needs python3, which runs the Anderton's watch." >&2; exit 1; }
# agy loads a workspace's hooks and agents from each directory between its working directory and the top of the
# checkout, so the Anderton runs at the top of the checkout it was opened in, a linked worktree included.
dir=$(git rev-parse --show-toplevel 2>/dev/null) || dir=$(pwd -P)
cd "$dir"
if ! out=$("$anderton_scripts/agy-hooks.sh" check --workspace "$dir" 2>&1); then
  echo "$out
agy would run unguarded, so the agy Anderton was not started." >&2
  exit 1
fi
ANDERTON_AGY_SESSION=$(python3 -c 'import uuid; print(uuid.uuid4())')
ANDERTON_AGY_NAME=$name ANDERTON_AGY_DIR=$dir
export ANDERTON_AGY_SESSION ANDERTON_AGY_NAME ANDERTON_AGY_DIR
# A launch from inside a Claude Code or Codex session would otherwise be read as that session.
unset CLAUDE_CODE_SESSION_ID CLAUDE_PID CODEX_THREAD_ID
mode="" prompt="" settings=""
for arg; do
  case $arg in
    --mode | --mode=*) mode=1 ;;
    -i | --prompt-interactive | --prompt-interactive=*) prompt=1 ;;
    --settings | --settings=*) settings=1 ;;
  esac
done
if [ -z "$mode" ]; then set -- --dangerously-skip-permissions "$@"; fi
# The checkout the user opened it in is trusted for this session, as a worker's worktree is.
if [ -z "$settings" ]; then
  trust=$(agy_session_settings "$dir") || { echo "$trust" >&2; exit 1; }
  set -- "$@" --settings "$trust"
fi
if [ -z "$prompt" ]; then
  set -- "$@" --prompt-interactive "You are the Anderton named $name for $dir. Read $(cd "$anderton_scripts/.." && pwd)/SKILL.md and follow it. Its scripts are in $anderton_scripts. Claim the role with claim.sh (add --project <name> only if the user names a project), then wait for the user."
fi
exec agy "$@"
