#!/usr/bin/env bash
# Launch a Codex TUI with the pane context its remote tool shells need.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

codex_home=$(invoking_codex_home)
daemon="$codex_home/app-server-control/app-server-control.sock"
if [ ! -S "$daemon" ]; then
  echo "Start the local Codex daemon for $codex_home before opening its Anderton." >&2
  exit 1
fi
set -- --remote "unix://$daemon" -c 'tui.terminal_title=["thread-id"]' "$@"
for variable in TMUX TMUX_PANE HERDR_ENV HERDR_WORKSPACE_ID HERDR_PANE_ID HERDR_SOCKET_PATH CLAUDE_CONFIG_DIR ANDERTON_WORKTREES; do
  value=${!variable:-}
  [ -n "$value" ] || continue
  quoted=$(jq -nc --arg value "$value" '$value')
  set -- -c "shell_environment_policy.set.$variable=$quoted" "$@"
done
exec codex "$@"
