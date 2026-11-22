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
cp "$repo/skills/anderton/scripts/claude-worker.py" "$tmp/scripts/"
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
  launch-matches) [ "$3" = "${MATCHING_LAUNCH:-}" ] || exit 3 ;;
  find) case " $* " in *" --token "*) echo "$FIXTURE_WORKER" ;; esac ;;
  state) echo '{"type":"idle"}' ;;
  sweep) ;;
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
if printf 'Fixture task.\n' | codex_role "$script/spawn.sh" --effort low --bg unsupported > "$tmp/refused" 2>&1; then exit 1; fi
grep -q 'herdr or tmux' "$tmp/refused"
[ ! -e "$ANDERTON_WORKTREES/wt-unsupported" ]
printf 'Fixture task.\n' | codex_role env TMUX=/tmp/fixture-tmux,10,0 ANDERTON_START_WAIT=0 "$script/spawn.sh" --effort low from-claude-default
jq -e '(.provider // "claude") == "claude" and .spawnerProvider == "codex" and .spawnerScope == "tools"' "$claims/workers/from-claude-default.json" >/dev/null
codex_role "$script/role-message.sh" "DEPLOY: catalog fixture"
jq -e '.peerMessage.text == "DEPLOY: catalog fixture"' "$root_claim" >/dev/null
mkdir -p "$CLAUDE_CONFIG_DIR/projects/fixture"
coordinator_transcript="$CLAUDE_CONFIG_DIR/projects/fixture/fixture-claude.jsonl"
: > "$coordinator_transcript"
stop_input() {
  jq -nc --arg dir "$PWD" --arg file "$coordinator_transcript" '
    {session_id:"fixture-claude", cwd:$dir, transcript_path:$file, hook_event_name:"Stop"}'
}
watch_status=0
stop_input | claude_role env ANDERTON_WATCH_TICK=1 "$script/watch.sh" > "$tmp/wake" 2>&1 || watch_status=$?
[ "$watch_status" = 2 ]
grep -q 'DEPLOY: catalog fixture' "$tmp/wake"
peer_id=$(jq -er '.peerMessage | select(.attemptedAt > 0) | .id' "$root_claim")
jq -nc --arg peer "$peer_id" '{type:"queue-operation",operation:"enqueue",
  sessionId:"fixture-claude",content:("Peer message " + $peer + " from Anderton fixture.")}' >> "$coordinator_transcript"
watch_status=0
stop_input | claude_role env ANDERTON_WATCH_TICK=1 ANDERTON_WATCH_RENEW=0 "$script/watch.sh" > "$tmp/wake" 2>&1 || watch_status=$?
[ "$watch_status" = 2 ]
jq -e '.peerMessage == null' "$root_claim" >/dev/null
if grep -q 'DEPLOY: catalog fixture' "$tmp/wake"; then exit 1; fi

rm -f "$claims/"*.json
codex_role "$script/claim.sh"
jq -e --arg thread "$FIXTURE_THREAD" '.provider == "codex" and .sessionId == $thread and .scope == null and (has("pid") | not)' "$root_claim" >/dev/null
refused_claim claude_role "$script/claim.sh"
NOT_REACHABLE=1 refused_claim claude_role "$script/claim.sh"
grep -q 'liveness: unknown' "$tmp/refused"
claude_role "$script/claim.sh" --project tools
printf 'Fixture task.\n' | claude_role env CODEX_HOME="$tmp/unrelated-home" TMUX=/tmp/fixture-tmux,10,0 "$script/spawn.sh" --effort low from-codex-default
jq -e --arg id "$FIXTURE_WORKER" --arg home "$CODEX_HOME" '
  .provider == "codex" and .id == $id and .codexHome == $home and .spawnerProvider == "claude" and .spawnerScope == "tools"' "$claims/workers/from-codex-default.json" >/dev/null
refused_claim env CODEX_THREAD_ID="$FIXTURE_WORKER" "$script/claim.sh" --project worker-scope
grep -q "managed as worker 'from-codex-default'" "$tmp/refused"
pending=019a0000-bbbb-7222-8333-444455556666
jq -nc --arg dir "$PWD" --arg home "$CODEX_HOME" '
  {name:"registering-codex",root:$dir,dir:$dir,provider:"codex",codexHome:$home,id:"",codexLaunchToken:"fixture"}' \
  > "$claims/workers/registering-codex.json"
refused_claim env CODEX_THREAD_ID="$pending" MATCHING_LAUNCH="$pending" "$script/claim.sh" --project worker-scope
grep -q "managed as worker 'registering-codex'" "$tmp/refused"
rm "$claims/workers/registering-codex.json"
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

inherited="$claims/workers/from-claude-default.json"
inherited_transcript="$CLAUDE_CONFIG_DIR/projects/fixture/inherited.jsonl"
jq -c --arg file "$inherited_transcript" '
  .claudeSession = {id:"inherited",transcript:$file} | .startedAt = "2030-01-02T00:00:00Z"
  ' "$inherited" > "$tmp/registered"
mv "$tmp/registered" "$inherited"
jq -nc '
  def event($id; $day; $text): {sessionId:"inherited",uuid:$id,type:"assistant",
    timestamp:("2030-01-0" + $day + "T01:00:00Z"),message:{stop_reason:"end_turn",content:[{type:"text",text:$text}]}};
  event("before-readoption";"1";"RESULT: historical fixture"),
  event("after-readoption";"3";"RESULT: inherited Claude fixture")' > "$inherited_transcript"
bookmarks="${root_claim%.json}.codex-probe/bookmarks"
mkdir -p "$bookmarks"
printf '"before-readoption"\n' > "$bookmarks/claude-inherited.json"
watch_status=0
stop_input | claude_role env ANDERTON_WATCH_TICK=1 "$script/watch.sh" > "$tmp/wake" 2>&1 || watch_status=$?
[ "$watch_status" = 2 ]
grep -q 'RESULT: inherited Claude fixture' "$tmp/wake"
if grep -q 'RESULT: historical fixture' "$tmp/wake"; then exit 1; fi
grep -qx '"after-readoption"' "$bookmarks/claude-inherited.json"

jq -nc --arg dir "$PWD" '
  {name:"another-name",root:$dir,dir:$dir,adopted:true,sessionId:"fixture-claude"}' > "$claims/workers/another-name.json"
refused_claim claude_role "$script/claim.sh" --project worker-scope
grep -q "managed as worker 'another-name'" "$tmp/refused"

echo "coordinator: mixed claims, provider selection, adoption, handoff, and receipts passed"
