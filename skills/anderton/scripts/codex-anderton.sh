#!/usr/bin/env bash
# Launch a Codex TUI with the pane context its remote tool shells need.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

base_home=$(invoking_codex_home)
resume=()
# --move <thread-id>: a Codex Anderton at its account's usage limit continues on the next account. Both accounts read
# one conversation store, so the account helper only marks the old account and names the next one (refusing while a
# codex still has the thread open), and the conversation resumes there. The claim keeps the old home until the new
# home's daemon has the thread loaded; then, under the repository lock, the old home's watch is stopped before the
# claim and a watch for the new home take over.
adopt_moved_claim() {
  local claim=$1 thread=$2 from=$3 to=$4 root=$5
  "$anderton_scripts/codex-worker.py" loaded "$to" "$thread" --wait 300 || return 0
  take_repository_lock "$root"
  jq -e --arg id "$thread" --arg from "$from" '.provider == "codex" and .sessionId == $id and .codexHome == $from' \
    "$claim" >/dev/null 2>&1 || return 0
  stop_codex_watch "$claim"
  set_codex_home "$claim" "$to" || return 0
  release_repository_lock
  CODEX_THREAD_ID=$thread CODEX_HOME=$to "$anderton_scripts/codex-worker.py" start-watch "$anderton_scripts/watch.sh" "$claim"
}
if [ "${1:-}" = --move ]; then
  [ $# -ge 2 ] || { echo "usage: codex-anderton.sh --move <thread-id> [codex options]" >&2; exit 2; }
  thread=$2
  shift 2
  if ! helper=$(codex_accounts); then
    echo "Moving a Codex Anderton needs a Codex account helper (ANDERTON_CODEX_ACCOUNTS, or codex-accounts on PATH)." >&2
    exit 1
  fi
  root=$(invoking_root)
  take_repository_lock "$root"
  claim=""
  while IFS= read -r r; do
    if [ -n "$r" ] && jq -e --arg id "$thread" '.provider == "codex" and .sessionId == $id' "$r" >/dev/null 2>&1; then
      claim=$r
    fi
  done <<EOF
$(project_holders "$root")
EOF
  from=$base_home
  if [ -n "$claim" ]; then from=$(jq -r .codexHome "$claim"); fi
  opts=(-c 'tui.terminal_title=["thread-id"]' "$@")
  to=$(CODEX_HOME=$from "$helper" --move-thread "$thread" -- "${opts[@]}" </dev/null) || exit $?
  to=$(cd "$(printf '%s\n' "$to" | tail -n 1)" && pwd -P) || exit 1
  release_repository_lock
  base_home=$to
  resume=(resume "$thread")
  if [ -n "$claim" ]; then
    (adopt_moved_claim "$claim" "$thread" "$from" "$to" "$root" </dev/null >/dev/null 2>&1) &
  fi
fi
codex_home=$(codex_start_home "$base_home" "$@")
[ ${#resume[@]} -eq 0 ] || codex_home=$base_home
if { codex_accounts >/dev/null || [ ${#resume[@]} -gt 0 ]; } && ! codex_daemon_up "$codex_home"; then
  echo "Could not start the Codex daemon of $codex_home, the account new Codex sessions start on." >&2
  exit 1
fi
daemon=$(codex_socket "$codex_home")
if [ ! -S "$daemon" ]; then
  echo "Start the local Codex daemon for $codex_home before opening its Anderton." >&2
  exit 1
fi
set -- --remote "unix://$daemon" -c 'tui.terminal_title=["thread-id"]' "$@"
# Its tool shells name the home its claim records.
export CODEX_HOME=$codex_home
for variable in CODEX_HOME ANDERTON_CODEX_ACCOUNTS TMUX TMUX_PANE HERDR_ENV HERDR_WORKSPACE_ID HERDR_PANE_ID HERDR_SOCKET_PATH CLAUDE_CONFIG_DIR ANDERTON_WORKTREES; do
  value=${!variable:-}
  [ -n "$value" ] || continue
  quoted=$(jq -nc --arg value "$value" '$value')
  set -- -c "shell_environment_policy.set.$variable=$quoted" "$@"
done
exec codex ${resume[@]+"${resume[@]}"} "$@"
