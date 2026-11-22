#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d /tmp/adtn-coord.XXXXXX)
claimer=""
cleanup() {
  if [ -n "$claimer" ]; then kill "$claimer" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
export HOME="$tmp/home" CLAUDE_CONFIG_DIR="$tmp/claude" CODEX_HOME="$tmp/codex"
export ANDERTON_WORKTREES="$tmp/worktrees" ANDERTON_START_WAIT=1
unset CLAUDE_PID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID TMUX HERDR_ENV
export PATH="$tmp/bin:$PATH"
mkdir -p "$HOME" "$tmp/bin" "$CLAUDE_CONFIG_DIR/sessions" "$CODEX_HOME/app-server-control" "$tmp/scripts" "$tmp/repo"
cp "$repo"/skills/anderton/scripts/*.sh "$tmp/scripts/"
cd "$tmp/repo"
git init -q
git -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m seed
export FIXTURE_ROOT="$PWD"
export FIXTURE_THREAD=019a0000-1111-7222-8333-444455556666
export FIXTURE_WORKER=019a0000-9999-7222-8333-444455556666

cat > "$tmp/scripts/codex-worker.py" <<'STUB'
#!/usr/bin/env bash
case $1 in
  identity) jq -cn --arg id "$3" --arg dir "$FIXTURE_ROOT" '{id:$id, dir:$dir, name:"fixture-codex"}' ;;
  claim-state) if [ -n "${NOT_REACHABLE:-}" ]; then exit 1; fi; echo "${CLAIM_STATE:-live}" ;;
  start-watch) ;;
  find) case " $* " in *" --token "*) echo "$FIXTURE_WORKER" ;; esac ;;
  state) echo '{"type":"idle"}' ;;
  *) exit 2 ;;
esac
STUB
cat > "$tmp/bin/claude" <<'STUB'
#!/usr/bin/env bash
case $1 in agents) echo '[]' ;; --bg) echo 'backgrounded · abc123 · fixture' ;; *) exit 2 ;; esac
STUB
cat > "$tmp/bin/tmux" <<'STUB'
#!/usr/bin/env bash
case $1 in new-window) echo '@21 %21' ;; *) exit 2 ;; esac
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/codex"
chmod +x "$tmp/scripts/codex-worker.py" "$tmp/bin/"*
python3 - "$CODEX_HOME/app-server-control/app-server-control.sock" <<'PY'
import socket
import sys
socket.socket(socket.AF_UNIX).bind(sys.argv[1])
PY
sleep 60 &
claimer=$!
jq -nc --argjson pid "$claimer" --arg cwd "$PWD" '{pid:$pid, sessionId:"fixture-claude", name:"fixture-claude", cwd:$cwd}' > "$CLAUDE_CONFIG_DIR/sessions/$claimer.json"

claude_role() { env CLAUDE_PID="$claimer" CLAUDE_CODE_SESSION_ID=fixture-claude "$@"; }
codex_role() { env CODEX_THREAD_ID="$FIXTURE_THREAD" "$@"; }
refused_claim() {
  local code=0
  "$@" > "$tmp/refused" 2>&1 || code=$?
  [ "$code" = 3 ]
}
script="$tmp/scripts"
claims="$CLAUDE_CONFIG_DIR/anderton"
root_claim="$claims/$(printf '%s' "$PWD" | git hash-object --stdin).json"
claude_role "$script/claim.sh"
refused_claim codex_role "$script/claim.sh"
codex_role "$script/claim.sh" --project tools
refused_claim codex_role "$script/claim.sh" --take-over
printf 'Fixture task.\n' | codex_role "$script/spawn.sh" --effort low --bg from-claude-default
jq -e '(.provider // "claude") == "claude" and .spawnerProvider == "codex" and .spawnerScope == "tools"' "$claims/workers/from-claude-default.json" >/dev/null
codex_role "$script/role-message.sh" "DEPLOY: catalog fixture"
jq -e '.peerMessage.text == "DEPLOY: catalog fixture"' "$root_claim" >/dev/null

rm -f "$claims/"*.json
codex_role "$script/claim.sh"
jq -e --arg thread "$FIXTURE_THREAD" '.provider == "codex" and .sessionId == $thread and .scope == null and (has("pid") | not)' "$root_claim" >/dev/null
refused_claim claude_role "$script/claim.sh"
NOT_REACHABLE=1 refused_claim claude_role "$script/claim.sh"
grep -q 'liveness: unknown' "$tmp/refused"
claude_role "$script/claim.sh" --project tools
printf 'Fixture task.\n' | claude_role env TMUX=/tmp/fixture-tmux,10,0 "$script/spawn.sh" --effort low from-codex-default
jq -e --arg id "$FIXTURE_WORKER" '.provider == "codex" and .id == $id and .spawnerProvider == "claude" and .spawnerScope == "tools"' "$claims/workers/from-codex-default.json" >/dev/null
printf 'Fixture task.\n' | claude_role "$script/spawn.sh" --effort low --bg --provider claude --mode default explicit-claude
jq -e '(.provider // "claude") == "claude"' "$claims/workers/explicit-claude.json" >/dev/null
if codex_role "$script/adopt.sh" --provider codex duplicate "$FIXTURE_WORKER" > "$tmp/refused" 2>&1; then exit 1; fi
grep -q 'already has a worker record' "$tmp/refused"
existing=019a0000-aaaa-7222-8333-444455556666
codex_role "$script/adopt.sh" --provider codex existing "$existing"
jq -e --arg id "$existing" '.provider == "codex" and .id == $id and .adopted and (.worktree | not)' "$claims/workers/existing.json" >/dev/null
codex_role "$script/retire.sh" existing
[ ! -f "$claims/workers/existing.json" ]
rm -f "$claims/"*.json
codex_role "$script/claim.sh"
CLAIM_STATE=gone claude_role "$script/claim.sh"
jq -e '.provider == "claude"' "$root_claim" >/dev/null

echo "coordinator: mixed claims, liveness, provider selection and adoption passed"
