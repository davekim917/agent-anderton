#!/usr/bin/env bash
# Launch a Codex TUI with the pane context its remote tool shells need.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

base_home=$(invoking_codex_home)
codex_home=$(codex_start_home "$base_home")
if [ "$codex_home" != "$base_home" ] && ! codex_daemon_up "$codex_home"; then
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
for variable in CODEX_HOME TMUX TMUX_PANE HERDR_ENV HERDR_WORKSPACE_ID HERDR_PANE_ID HERDR_SOCKET_PATH CLAUDE_CONFIG_DIR ANDERTON_WORKTREES; do
  value=${!variable:-}
  [ -n "$value" ] || continue
  quoted=$(jq -nc --arg value "$value" '$value')
  set -- -c "shell_environment_policy.set.$variable=$quoted" "$@"
done
exec codex "$@"
