#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d /tmp/adtn-coord.XXXXXX)
tmp=$(cd "$tmp" && pwd -P)
claimer=""
clearable_pid=""
replacement_pid=""
fixture_watch=""
cleanup() {
  local pid
  for pid in "$claimer" "$clearable_pid" "$replacement_pid" "$fixture_watch"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
  done
  rm -rf "$tmp"
}
trap cleanup EXIT
export HOME="$tmp/home" CLAUDE_CONFIG_DIR="$tmp/claude" CODEX_HOME="$tmp/codex"
export ANDERTON_WORKTREES="$tmp/worktrees" ANDERTON_START_WAIT=1
# No Codex account helper on this machine's PATH is reached.
export ANDERTON_CODEX_ACCOUNTS="$tmp/no-codex-accounts"
export FIXTURE_TMUX_LOG="$tmp/tmux.log"
export FIXTURE_NOTICE_HOME="$tmp/notices"
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
  start-watch) echo "${CODEX_THREAD_ID:-} ${CODEX_HOME:-} $3" >> "$FIXTURE_ROOT/../watch-starts" ;;
  loaded)
    while [ -n "${FIXTURE_LOADED_GATE:-}" ] && [ ! -e "$FIXTURE_LOADED_GATE" ]; do sleep 0.1; done
    echo "$2 $3" >> "$FIXTURE_ROOT/../loaded-checks"; [ -z "${FIXTURE_NOT_LOADED:-}" ] ;;
  launch-matches)
    [ -z "${LAUNCH_LOOKUP_FAIL:-}" ] || exit 1
    [ "$3" = "${MATCHING_LAUNCH:-}" ] || exit 3
    ;;
  find) case " $* " in *" --token "*) echo "$FIXTURE_WORKER" ;; esac ;;
  state) echo '{"type":"idle"}' ;;
  blocker-during-notice)
    if [ -e "$FIXTURE_NOTICE_HOME/worker-blocked" ] && [ "$(jq -r .name "$2")" = delayed-fixture ]; then
      printf '=== delayed-fixture (Codex fixture, waiting on approval)\t%s\n' "$(cat "$FIXTURE_NOTICE_HOME/worker-blocked")"
    fi
    ;;
  notice)
    cp "$3/message" "$FIXTURE_NOTICE_HOME/current"
    [ -e "$FIXTURE_NOTICE_HOME/finish" ] || exit 1
    if [ -s "$3/blocked" ]; then cp "$3/message" "$FIXTURE_NOTICE_HOME/second"; fi
    ;;
  sweep) ;;
  *) exit 2 ;;
esac
STUB
cat > "$tmp/bin/claude" <<'STUB'
#!/usr/bin/env bash
case $1 in agents) echo '[]' ;; *) exit 2 ;; esac
STUB
cat > "$tmp/bin/tmux" <<'STUB'
#!/usr/bin/env bash
case $1 in new-window) printf '%s\n' "$@" > "$FIXTURE_TMUX_LOG"; echo '@21 %21' ;; *) exit 2 ;; esac
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/codex"
chmod +x "$tmp/scripts/codex-worker.py" "$tmp/bin/"*
python3 - "$CODEX_HOME/app-server-control/app-server-control.sock" <<'PY'
import socket
import sys
socket.socket(socket.AF_UNIX).bind(sys.argv[1])
PY
# Outlives every check that needs the fixture Claude session; cleanup ends it.
sleep 600 &
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
for provider in claude codex; do
  status=0
  codex_role "$script/spawn.sh" --effort low --provider "$provider" "no-mux-$provider" </dev/null > "$tmp/refused" 2>&1 || status=$?
  [ "$status" -eq 2 ]
  grep -q 'inside herdr or tmux' "$tmp/refused"
  status=0
  codex_role env TMUX=/tmp/fixture-tmux,10,0 "$script/spawn.sh" --effort low --provider "$provider" --bg "bg-$provider" \
    </dev/null > "$tmp/refused" 2>&1 || status=$?
  [ "$status" -eq 2 ]
  grep -q -- '--bg is unsupported' "$tmp/refused"
done
[ ! -e "$ANDERTON_WORKTREES" ]
[ ! -e "$claims/workers" ]
[ ! -e "$FIXTURE_TMUX_LOG" ]
printf 'Fixture task.\n' | codex_role env TMUX=/tmp/fixture-tmux,10,0 ANDERTON_START_WAIT=0 "$script/spawn.sh" --effort low from-claude-default
jq -e '(.provider // "claude") == "claude" and .spawnerProvider == "codex" and .spawnerScope == "tools"' "$claims/workers/from-claude-default.json" >/dev/null
if codex_role "$script/role-message.sh" ' ' >/dev/null 2>&1; then exit 1; fi
jq -e '.peerMessage == null' "$root_claim" >/dev/null
codex_role "$script/role-message.sh" "Deploy the catalog fixture"
jq -e '.peerMessage.text == "Deploy the catalog fixture"' "$root_claim" >/dev/null
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
grep -q 'Deploy the catalog fixture' "$tmp/wake"
peer_id=$(jq -er '.peerMessage | select(.attemptedAt > 0) | .id' "$root_claim")
jq -nc --arg peer "$peer_id" '{type:"queue-operation",operation:"enqueue",
  sessionId:"fixture-claude",content:("Peer message " + $peer + " from Anderton fixture.")}' >> "$coordinator_transcript"
watch_status=0
stop_input | claude_role env ANDERTON_WATCH_TICK=1 ANDERTON_WATCH_RENEW=0 "$script/watch.sh" > "$tmp/wake" 2>&1 || watch_status=$?
[ "$watch_status" = 2 ]
jq -e '.peerMessage == null' "$root_claim" >/dev/null
if grep -q 'Deploy the catalog fixture' "$tmp/wake"; then exit 1; fi

rm -f "$claims/"*.json
codex_role "$script/claim.sh"
jq -e --arg thread "$FIXTURE_THREAD" '.provider == "codex" and .sessionId == $thread and .scope == null and (has("pid") | not)' "$root_claim" >/dev/null
# A Codex Anderton at its usage limit resumes on the next account, whose home reads the same conversation store: the
# helper marks the old account and names the new home, and the claim names the new home only once its daemon has the
# thread loaded, after the old home's watch is stopped.
moved_home="$tmp/codex-moved"
mkdir -p "$moved_home/app-server-control"
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$moved_home/app-server-control/app-server-control.sock"
cat > "$tmp/accounts" <<STUB
#!/usr/bin/env bash
echo "\$CODEX_HOME \$*" >> "$tmp/accounts.log"
case \$1 in
  --move-thread) echo "$moved_home" ;;
  --locate-thread) cat "$tmp/locate" 2>/dev/null || echo "$moved_home" ;;
  --start-home) echo "\$CODEX_HOME" ;;
esac
STUB
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s"\n' "$tmp/codex.args" > "$tmp/bin/codex"
chmod +x "$tmp/accounts" "$tmp/bin/codex"
# One thread holds one role whichever account's home it runs on.
refused_claim codex_role env CODEX_HOME="$moved_home" "$script/claim.sh" --project tools
grep -q 'already holds the repository role' "$tmp/refused"
handed_over() { # handed_over <home> [tenths]: waits for the background hand-over to settle the claim on <home>
  for _ in $(seq 1 "${2:-50}"); do
    if jq -e --arg home "$1" '.codexHome == $home' "$root_claim" >/dev/null; then return 0; fi
    sleep 0.1
  done
  return 1
}
# A new session whose daemon never loads the thread leaves the claim on the old home.
rm -f "$tmp/loaded-checks"
codex_role env FIXTURE_NOT_LOADED=1 ANDERTON_CODEX_ACCOUNTS="$tmp/accounts" "$script/codex-anderton.sh" --move "$FIXTURE_THREAD"
for _ in $(seq 1 50); do [ -s "$tmp/loaded-checks" ] && break; sleep 0.1; done
sleep 0.5
grep -qxF "$moved_home $FIXTURE_THREAD" "$tmp/loaded-checks"
jq -e --arg home "$CODEX_HOME" '.codexHome == $home' "$root_claim" > /dev/null
if [ -e "$tmp/watch-starts" ] && grep -q "$moved_home" "$tmp/watch-starts"; then exit 1; fi
: > "$tmp/accounts.log"
# The old home's watch is stopped before the claim moves: a watch for the same thread would leave on finding it held.
watcher="$(dirname "$root_claim")/$(basename "$root_claim" .json).watch"
bash -c 'exec -a watch.sh sleep 60' &
old_watch=$!
echo "$old_watch $FIXTURE_THREAD 0" > "$watcher"
codex_role env ANDERTON_CODEX_ACCOUNTS="$tmp/accounts" "$script/codex-anderton.sh" --move "$FIXTURE_THREAD"
handed_over "$moved_home"
grep -qxF "$CODEX_HOME --move-thread $FIXTURE_THREAD -- -c tui.terminal_title=[\"thread-id\"]" "$tmp/accounts.log"
[ "$(grep -c -- --move-thread "$tmp/accounts.log")" -eq 1 ]
[ "$(head -n 2 "$tmp/codex.args" | tr '\n' ' ')" = "resume $FIXTURE_THREAD " ]
grep -qxF "unix://$moved_home/app-server-control/app-server-control.sock" "$tmp/codex.args"
for _ in $(seq 1 50); do [ -s "$tmp/watch-starts" ] && break; sleep 0.1; done
tail -n 1 "$tmp/watch-starts" | grep -qxF "$FIXTURE_THREAD $moved_home $root_claim"
if kill -0 "$old_watch" 2>/dev/null; then exit 1; fi
[ ! -e "$watcher" ]
refused_claim codex_role "$script/claim.sh"
codex_role env CODEX_HOME="$moved_home" "$script/claim.sh"
# A hand-over that finds the repository lock held past its ten-second wait says so and tries again.
jq --arg home "$CODEX_HOME" '.codexHome = $home' "$root_claim" > "$root_claim.tmp" && mv "$root_claim.tmp" "$root_claim"
rm -f "${root_claim%.json}.handover.log"
# The new daemon reports the thread loaded only once the lock is held here, after the launcher has let go of it.
codex_role env ANDERTON_CODEX_ACCOUNTS="$tmp/accounts" ANDERTON_HANDOVER_RETRY=1 FIXTURE_LOADED_GATE="$tmp/loaded-gate" \
  "$script/codex-anderton.sh" --move "$FIXTURE_THREAD"
# Held past one take's wait, which runs longer than ten seconds where the lock is a directory (macOS).
printf ': > %q\nsleep 25\n' "$tmp/lock-held" > "$tmp/hold-lock.sh"
if command -v flock > /dev/null 2>&1; then
  flock "$root_claim.lock.flock" bash "$tmp/hold-lock.sh" &
else
  ( mkdir "$root_claim.lock" && echo $$ > "$root_claim.lock/pid" && bash "$tmp/hold-lock.sh"; rm -rf "$root_claim.lock" ) &
fi
lock_holder=$!
for _ in $(seq 1 50); do [ -e "$tmp/lock-held" ] && break; sleep 0.1; done
: > "$tmp/loaded-gate"
handed_over "$moved_home" 600
wait "$lock_holder" 2> /dev/null || true
grep -q 'the repository lock is held; try 1 of 10' "${root_claim%.json}.handover.log"
# A thread that moves back while the hand-over waits on the lock keeps its claim and watch where it now runs.
jq --arg home "$CODEX_HOME" '.codexHome = $home' "$root_claim" > "$root_claim.tmp" && mv "$root_claim.tmp" "$root_claim"
rm -f "${root_claim%.json}.handover.log" "$tmp/lock-held" "$tmp/loaded-gate"
watch_lines=$(wc -l < "$tmp/watch-starts")
codex_role env ANDERTON_CODEX_ACCOUNTS="$tmp/accounts" ANDERTON_HANDOVER_RETRY=1 FIXTURE_LOADED_GATE="$tmp/loaded-gate" \
  "$script/codex-anderton.sh" --move "$FIXTURE_THREAD"
if command -v flock > /dev/null 2>&1; then
  flock "$root_claim.lock.flock" bash "$tmp/hold-lock.sh" &
else
  ( mkdir "$root_claim.lock" && echo $$ > "$root_claim.lock/pid" && bash "$tmp/hold-lock.sh"; rm -rf "$root_claim.lock" ) &
fi
lock_holder=$!
for _ in $(seq 1 50); do [ -e "$tmp/lock-held" ] && break; sleep 0.1; done
: > "$tmp/loaded-gate"
for _ in $(seq 1 300); do grep -q 'try 1 of 10' "${root_claim%.json}.handover.log" 2> /dev/null && break; sleep 0.1; done
echo "$CODEX_HOME" > "$tmp/locate"
for _ in $(seq 1 600); do grep -q 'dropped' "${root_claim%.json}.handover.log" 2> /dev/null && break; sleep 0.1; done
wait "$lock_holder" 2> /dev/null || true
grep -q "dropped: its daemon no longer has the thread open; the claim stays on $CODEX_HOME" "${root_claim%.json}.handover.log"
jq -e --arg home "$CODEX_HOME" '.codexHome == $home' "$root_claim" > /dev/null
[ "$(wc -l < "$tmp/watch-starts")" -eq "$watch_lines" ]
rm -f "$tmp/locate"
# A claim a hand-over never reached follows its thread to the home that last ran it when that session claims.
jq --arg home "$CODEX_HOME" '.codexHome = $home' "$root_claim" > "$root_claim.tmp" && mv "$root_claim.tmp" "$root_claim"
codex_role env CODEX_HOME="$moved_home" ANDERTON_CODEX_ACCOUNTS="$tmp/accounts" "$script/claim.sh"
jq -e --arg home "$moved_home" '.codexHome == $home' "$root_claim" > /dev/null
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/codex"
jq --arg home "$CODEX_HOME" '.codexHome = $home' "$root_claim" > "$root_claim.tmp" && mv "$root_claim.tmp" "$root_claim"
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
if MATCHING_LAUNCH="$pending" codex_role "$script/adopt.sh" --provider codex duplicate-pending "$pending" > "$tmp/refused" 2>&1; then exit 1; fi
grep -q 'already has a worker record' "$tmp/refused"
if LAUNCH_LOOKUP_FAIL=1 codex_role "$script/adopt.sh" --provider codex uncertain-pending "$pending" > "$tmp/refused" 2>&1; then exit 1; fi
grep -q 'already has a worker record' "$tmp/refused"
codex_role "$script/adopt.sh" --provider codex independent-thread "$pending"
codex_role "$script/retire.sh" independent-thread
rm "$claims/workers/registering-codex.json"
printf 'Fixture task.\n' | claude_role env TMUX=/tmp/fixture-tmux,10,0 ANDERTON_START_WAIT=0 \
  "$script/spawn.sh" --effort low --provider claude --mode default explicit-claude
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
  event("earlier-current";"2";"Ordinary reply"),
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
mkdir "$tmp/quiet-stage"
claude_role env ANDERTON_PROBE_STATE="$bookmarks" ANDERTON_PROBE_STAGE="$tmp/quiet-stage" "$script/worker.sh" sweep > "$tmp/quiet-output"
[ ! -s "$tmp/quiet-output" ] && [ ! -e "$tmp/quiet-stage/claude-inherited.json" ]

clearable="$claims/workers/clearable.json"
clearable_dir=$(jq -r .dir "$inherited")
jq '.name = "clearable" | .spawnerScope = null | .claudeLaunchId = "before-clear" | del(.claudeSession)' "$inherited" > "$clearable"
sleep 60 &
clearable_pid=$!
sleep 60 &
replacement_pid=$!
register_clearable() {
  jq -nc --argjson pid "$1" --arg sid "$2" --arg dir "$clearable_dir" '
    {pid:$pid, sessionId:$sid, name:"clearable", cwd:$dir}' > "$CLAUDE_CONFIG_DIR/sessions/$1.json"
  touch "$CLAUDE_CONFIG_DIR/projects/fixture/$2.jsonl"
}
clearable_stop() {
  jq -nc --arg sid "$2" --arg dir "$clearable_dir" --arg file "$CLAUDE_CONFIG_DIR/projects/fixture/$2.jsonl" '
    {session_id:$sid, cwd:$dir, transcript_path:$file, hook_event_name:"Stop"}' |
    env CLAUDE_PID="$1" CLAUDE_CODE_SESSION_ID="$2" ANDERTON_WATCH_TICK=1 "$script/watch.sh"
}
wait_for_binding() {
  local _
  for _ in $(seq 1 50); do
    if jq -e --arg sid "$1" '.claudeSession.id == $sid' "$clearable" >/dev/null; then return; fi
    sleep 0.2
  done
  return 1
}
register_clearable "$replacement_pid" replacement-session
clearable_stop "$replacement_pid" replacement-session
jq -e '.claudeSession == null' "$clearable" >/dev/null
mkdir "$tmp/plain"
jq -nc --argjson pid "$replacement_pid" --arg dir "$tmp/plain" '
  {pid:$pid, sessionId:"plain-legacy-id", name:"plain-legacy", cwd:$dir}' > "$CLAUDE_CONFIG_DIR/sessions/$replacement_pid.json"
jq -nc --arg dir "$tmp/plain" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  {name:"plain-legacy",root:$dir,dir:$dir,worktree:false,launcher:"tmux",spawner:"fixture-claude",startedAt:$at}
' > "$claims/workers/plain-legacy.json"
refused_claim env CLAUDE_PID="$replacement_pid" CLAUDE_CODE_SESSION_ID=plain-legacy-id "$script/claim.sh"
grep -q "managed as worker 'plain-legacy'" "$tmp/refused"
jq --arg dir "$tmp/plain" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" -nc '
  {type:"user",sessionId:"plain-legacy-id",timestamp:$at,cwd:$dir,message:{
    content:("Brief.\nYou are a worker the Anderton session \"fixture-claude\" started for the task above, in " + $dir + ".")
  }}' > "$CLAUDE_CONFIG_DIR/projects/fixture/plain-legacy-id.jsonl"
jq '.name = "renamed-plain-worker"' "$CLAUDE_CONFIG_DIR/sessions/$replacement_pid.json" > "$tmp/renamed-plain"
mv "$tmp/renamed-plain" "$CLAUDE_CONFIG_DIR/sessions/$replacement_pid.json"
refused_claim env CLAUDE_PID="$replacement_pid" CLAUDE_CODE_SESSION_ID=plain-legacy-id "$script/claim.sh" --project plain-renamed
grep -q "managed as worker 'plain-legacy'" "$tmp/refused"
rm "$claims/workers/plain-legacy.json"
rm "$CLAUDE_CONFIG_DIR/sessions/$replacement_pid.json"
register_clearable "$clearable_pid" before-clear
registry="$CLAUDE_CONFIG_DIR/sessions/$clearable_pid.json"
cp "$registry" "$tmp/registry-original"
jq --arg dir "$tmp" '.name = "renamed-worker" | .cwd = $dir' "$tmp/registry-original" > "$registry"
refused_claim env CLAUDE_PID="$clearable_pid" CLAUDE_CODE_SESSION_ID=before-clear "$script/claim.sh" --project renamed-worker
grep -q "managed as worker 'clearable'" "$tmp/refused"
mv "$tmp/registry-original" "$registry"
mkdir "$clearable.lock"
clearable_stop "$clearable_pid" before-clear > "$tmp/stale-worker-lock" 2>&1
[ "$(grep -c 'A worker operation already holds' "$tmp/stale-worker-lock")" -eq 3 ]
jq -e '.claudeSession == null' "$clearable" >/dev/null
rmdir "$clearable.lock"
clearable_stop "$clearable_pid" before-clear > "$tmp/before-clear-hook" 2>&1 &
before_clear_watch=$!
wait_for_binding before-clear
jq -e --argjson pid "$clearable_pid" '.claudeSession | .id == "before-clear" and .pid == $pid and .procStart != ""' "$clearable" >/dev/null
(
  # shellcheck source=SCRIPTDIR/../skills/anderton/scripts/session-lib.sh
  . "$script/session-lib.sh"
  claude_stop_matches "$clearable" before-clear "$clearable_pid" "$(proc_start "$clearable_pid")"
  if claude_stop_matches "$clearable" before-clear "$clearable_pid" different-process; then exit 1; fi
)
jq '.claudeDirection = {id:"old-direction", target:"before-clear"}' "$clearable" > "$tmp/updated-worker"
mv "$tmp/updated-worker" "$clearable"
register_clearable "$replacement_pid" replacement-session
clearable_stop "$replacement_pid" replacement-session
jq -e '.claudeSession.id == "before-clear"' "$clearable" >/dev/null
register_clearable "$clearable_pid" after-clear
wait "$before_clear_watch"
cp "$clearable" "$tmp/current-worker"
jq '.claudeSession.procStart = "different-process"' "$clearable" > "$tmp/updated-worker"
mv "$tmp/updated-worker" "$clearable"
clearable_stop "$clearable_pid" after-clear
jq -e '.claudeSession.id == "before-clear"' "$clearable" >/dev/null
mv "$tmp/current-worker" "$clearable"
(
  # shellcheck source=SCRIPTDIR/../skills/anderton/scripts/session-lib.sh
  . "$script/session-lib.sh"
  take_repository_lock "$PWD"
  lock_worker "$clearable"
  touch "$tmp/worker-lock-held"
  for _ in $(seq 1 250); do
    if [ -f "$tmp/release-worker-lock" ]; then exit 0; fi
    sleep 0.1
  done
  exit 1
) &
busy_lock=$!
for _ in $(seq 1 50); do
  if [ -f "$tmp/worker-lock-held" ]; then break; fi
  sleep 0.1
done
[ -f "$tmp/worker-lock-held" ]
clearable_stop "$clearable_pid" after-clear > "$tmp/after-clear-hook" 2>&1 &
after_clear_watch=$!
for _ in $(seq 1 50); do
  if [ -s "${clearable%.json}.after-clear.watch" ]; then break; fi
  sleep 0.1
done
[ -s "${clearable%.json}.after-clear.watch" ]
for _ in $(seq 1 150); do
  if grep -q 'within 10 seconds' "$tmp/after-clear-hook"; then break; fi
  sleep 0.1
done
grep -q 'within 10 seconds' "$tmp/after-clear-hook"
jq -e '.claudeSession.id == "before-clear"' "$clearable" >/dev/null
touch "$tmp/release-worker-lock"
wait "$busy_lock"
wait_for_binding after-clear
jq -e '.claudeSession.id == "after-clear" and (.claudeSession.transcript | endswith("/after-clear.jsonl"))
  and .claudeDirection == null' "$clearable" >/dev/null

sleep 60 &
old_pid=$!
jq --argjson old_pid "$old_pid" '
  .pid = $old_pid | .peerMessage = {id:"pending-peer",text:"DEPLOY: retain across resume"}
  ' "$root_claim" > "$tmp/previous"
mv "$tmp/previous" "$root_claim"
kill "$old_pid"
wait "$old_pid" 2>/dev/null || true
claude_role "$script/claim.sh" --rebind
jq -e --argjson active "$claimer" '.pid == $active and .peerMessage.id == "pending-peer"' "$root_claim" >/dev/null
codex_role "$script/claim.sh" --take-over
jq -e '.provider == "codex" and .peerMessage == null' "$root_claim" >/dev/null
codex_role "$script/worker.sh" message clearable 'Check the updated fixture.'
watch_status=0
wait "$after_clear_watch" || watch_status=$?
[ "$watch_status" = 2 ]
grep -q 'Check the updated fixture.' "$tmp/after-clear-hook"
jq -e '.claudeDirection.target == "after-clear" and .claudeDirection.attemptedAt > 0' "$clearable" >/dev/null
if codex_role "$script/worker.sh" message clearable 'Refuse an idle worker whose watcher ended.' > "$tmp/refused" 2>&1; then exit 1; fi
grep -q 'Anderton Stop watcher has ended' "$tmp/refused"
kill "$clearable_pid"
wait "$clearable_pid" 2>/dev/null || true
clearable_pid=""
register_clearable "$replacement_pid" after-clear
if codex_role "$script/worker.sh" message clearable 'Refuse before the resumed Stop hook.' > "$tmp/refused" 2>&1; then exit 1; fi
grep -q 'has not registered its Anderton Stop hook' "$tmp/refused"
# A worker a Claude Anderton started ends its turns under that Anderton, so its Stop watcher ends at once. The holder
# that takes the role over wakes it in its herdr pane, only while herdr shows that worker's session there, idle.
claude_role "$script/claim.sh" --take-over
inherited_plain="$claims/workers/inherited-plain.json"
jq --arg socket "$tmp/herdr.sock" '.name = "inherited-plain" | .spawnerProvider = "claude" | .claudeLaunchId = "inherited-plain-id"
  | .launcher = "herdr" | .pane = "w9:p90" | .socket = $socket | del(.claudeSession, .reportTransport, .claudeDirection)
  ' "$clearable" > "$inherited_plain"
sleep 60 &
inherited_plain_pid=$!
jq -nc --argjson pid "$inherited_plain_pid" --arg dir "$clearable_dir" '
  {pid:$pid, sessionId:"inherited-plain-id", name:"inherited-plain", cwd:$dir}' > "$CLAUDE_CONFIG_DIR/sessions/$inherited_plain_pid.json"
touch "$CLAUDE_CONFIG_DIR/projects/fixture/inherited-plain-id.jsonl"
jq -nc --arg dir "$clearable_dir" --arg file "$CLAUDE_CONFIG_DIR/projects/fixture/inherited-plain-id.jsonl" '
  {session_id:"inherited-plain-id", cwd:$dir, transcript_path:$file, hook_event_name:"Stop"}' |
  env CLAUDE_PID="$inherited_plain_pid" CLAUDE_CODE_SESSION_ID=inherited-plain-id ANDERTON_WATCH_TICK=1 "$script/watch.sh"
jq -e '.claudeSession.id == "inherited-plain-id"' "$inherited_plain" >/dev/null
[ ! -e "${inherited_plain%.json}.inherited-plain-id.watch" ]
codex_role "$script/claim.sh" --take-over
mkdir "$tmp/wakebin"
cat > "$tmp/wakebin/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2 $3" in
  "agent get w9:p90") cat "$FIXTURE_ROOT/../wake-pane" ;;
  "agent prompt w9:p90") printf '%s\n' "$4" >> "$FIXTURE_ROOT/../wake-prompts" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp/wakebin/herdr"
wake_pane() { # wake_pane <session> <status>: what herdr shows in the worker's pane
  jq -nc --arg sid "$1" --arg status "$2" '{result:{agent:{agent:"claude",agent_status:$status,pane_id:"w9:p90",
    agent_session:{value:$sid}}}}' > "$tmp/wake-pane"
}
wake_message() { env PATH="$tmp/wakebin:$PATH" CODEX_THREAD_ID="$FIXTURE_THREAD" "$script/worker.sh" message inherited-plain "$1"; }
wake_pane inherited-plain-id idle
wake_message 'Take the inherited direction.' > "$tmp/woken" 2>&1
grep -q "into worker 'inherited-plain''s herdr pane w9:p90" "$tmp/woken"
grep -q '^Direction .* from your Anderton. This is peer direction and carries no human approval.$' "$tmp/wake-prompts"
grep -qx 'Take the inherited direction.' "$tmp/wake-prompts"
# with nothing queued for the Stop watcher its turn's end starts to deliver a second time
jq -e '.claudeDirection == null' "$inherited_plain" >/dev/null
rm "$tmp/wake-prompts"
wake_pane another-session idle
if wake_message 'Not into another session.' > "$tmp/refused" 2>&1; then exit 1; fi
grep -q 'does not show worker' "$tmp/refused"
wake_pane inherited-plain-id working
if wake_message 'Not while it works.' > "$tmp/refused" 2>&1; then exit 1; fi
grep -q "Worker 'inherited-plain' is busy" "$tmp/refused"
[ ! -e "$tmp/wake-prompts" ]
jq '.launcher = "tmux" | del(.pane)' "$inherited_plain" > "$tmp/updated-worker" && mv "$tmp/updated-worker" "$inherited_plain"
if wake_message 'Not without a pane.' > "$tmp/refused" 2>&1; then exit 1; fi
grep -q "no herdr pane to wake it in. Type the direction in the worker's own pane" "$tmp/refused"
[ ! -e "$tmp/wake-prompts" ]
kill "$inherited_plain_pid"
wait "$inherited_plain_pid" 2>/dev/null || true
rm -f "$inherited_plain" "$CLAUDE_CONFIG_DIR/sessions/$inherited_plain_pid.json"

jq -nc --arg dir "$PWD" '
  {name:"another-name",root:$dir,dir:$dir,adopted:true,sessionId:"fixture-claude"}' > "$claims/workers/another-name.json"
refused_claim claude_role "$script/claim.sh" --project worker-scope
grep -q "managed as worker 'another-name'" "$tmp/refused"

cutoff=2030-01-02T00:00:00Z
jq --arg cutoff "$cutoff" '.claudeReportSince = $cutoff |
  .claudeReportPreviousHolder = {sessionId:"former-id",pid:984}' "$root_claim" > "$tmp/updated-claim"
mv "$tmp/updated-claim" "$root_claim"
legacy="$claims/workers/legacy-reporter.json"
legacy_transcript="$CLAUDE_CONFIG_DIR/projects/fixture/legacy-native-report.jsonl"
jq '.name = "legacy-reporter" | .spawner = "former-claude" | .spawnerScope = null | .spawnerSession = "former-id" |
    .spawnerProvider = "claude" | .startedAt = "2030-01-01T01:00:01Z" |
    del(.claudeLaunchId,.claudeSession,.reportTransport)' "$inherited" > "$legacy"
rm "$CLAUDE_CONFIG_DIR/sessions/$replacement_pid.json"
jq -nc --arg dir "$clearable_dir" '
  def entry($id; $time): {sessionId:"legacy-native-report",uuid:$id,cwd:$dir,
    timestamp:("2030-01-0" + $time + "T01:00:00Z")};
  def user($id; $time; $text): entry($id; $time) + {type:"user",message:{content:$text}};
  def send($id; $time; $to; $text): entry($id; $time) + {type:"assistant",
    message:{stop_reason:"tool_use",content:[{type:"tool_use",name:"SendMessage",id:$id,input:{to:$to,message:$text}}]}};
  def reply($id; $text): entry($id; "3") + {type:"assistant",
    message:{stop_reason:"end_turn",content:[{type:"text",text:$text}]}};
  def receipt($id; $tool; $success): entry($id; "1") + {type:"user",toolUseResult:{success:$success},
    message:{content:[{type:"tool_result",tool_use_id:$tool}]}};
  def before_takeover: .timestamp = "2030-01-01T02:00:00Z";
  user("launch";"1";"Brief.\nYou are a worker the Anderton session \"former-claude\" started for the task above, in " + $dir + "."),
  send("historical";"1";"former-claude";"RESULT: historical transport"),
  ((user("sent-turn";"1";"Continue."), send("sent-old";"1";"uds:/run/claude/984.sock";"RESULT: old delivered echo"),
    receipt("sent-result";"sent-old";true), reply("resent-old";"RESULT: old delivered echo")) | before_takeover),
  ((user("failed-turn";"1";"Continue."), send("missed-old";"1";"former-claude";"RESULT: old unread final"),
    receipt("missed-result";"missed-old";false), reply("unread-old";"RESULT: old unread final")) | before_takeover),
  user("turn-one";"3";"Continue."),
  send("outbound-one";"3";"former-claude";"RESULT: same milestone"),
  send("different-recipient";"3";"another-claude";"RESULT: unrelated message"),
  reply("duplicate-final";"RESULT: same milestone"),
  user("turn-two";"3";"Report the next milestone."),
  send("outbound-two";"3";"former-claude";"RESULT: same milestone"),
  send("prior-socket";"3";"uds:/run/claude/984.sock";"RESULT: scoped socket milestone"),
  send("wrong-socket";"3";"uds:/run/claude/985.sock";"RESULT: unrelated socket"),
  user("turn-three";"3";"Report the third milestone."),
  send("outbound-three";"3";"former-claude";"RESULT: example PR opened"),
  reply("distinct-final";"RESULT: example CI passed")
' > "$legacy_transcript"
TZ=UTC touch -t 203001030100 "$legacy_transcript"
jq -nc --argjson pid "$replacement_pid" --arg dir "$clearable_dir" '
  {pid:$pid,sessionId:"legacy-native-report",name:"legacy-reporter",cwd:$dir}' > "$CLAUDE_CONFIG_DIR/sessions/$replacement_pid.json"
native_gate() {
  local status=0
  jq -nc --arg dir "$clearable_dir" --arg file "$legacy_transcript" --arg tool "$1" --arg to "$2" --arg report "$3" '
    {session_id:"legacy-native-report", cwd:$dir, transcript_path:$file, tool_use_id:$tool,
     hook_event_name:"PreToolUse",tool_input:{to:$to,message:$report}}' |
    "$script/report-gate.sh" > "$tmp/native-gate" 2>&1 || status=$?
  [ "$status" -eq 2 ]
  grep -q 'will read this milestone' "$tmp/native-gate"
}
native_gate outbound-one former-claude 'RESULT: same milestone'
native_gate outbound-two former-claude 'RESULT: same milestone'
native_gate prior-socket 'uds:/run/claude/984.sock' 'RESULT: scoped socket milestone'
native_gate outbound-three former-claude 'RESULT: example PR opened'
# An agy holder of the role holds the same native sends for its sweep.
mkdir "$tmp/agybin"
cat > "$tmp/agybin/herdr" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2 $3" = "agent get w9:p77" ] || exit 1
jq -nc --arg dir "$FIXTURE_ROOT" '{result:{agent:{agent:"agy",agent_status:"idle",pane_id:"w9:p77",cwd:$dir,agent_session:{value:"conv-fixture"}}}}'
STUB
chmod +x "$tmp/agybin/herdr"
as_agy_holder() {
  cp "$root_claim" "$tmp/codex-claim"
  jq --arg socket "$tmp/herdr.sock" --arg dir "$FIXTURE_ROOT" '.provider = "agy" | .sessionId = "agy-fixture" |
    .name = "fixture-agy" | .dir = $dir | .pane = "w9:p77" | .socket = $socket | .agyInstance = "conv-fixture" | del(.codexHome)
    ' "$tmp/codex-claim" > "$root_claim"
}
agy_role() { env PATH="$tmp/agybin:$PATH" ANDERTON_AGY_SESSION=agy-fixture ANDERTON_AGY_NAME=fixture-agy HERDR_PANE_ID=w9:p77 \
  HERDR_SOCKET_PATH="$tmp/herdr.sock" "$@"; }
as_agy_holder
mv "$claims/reports/routes" "$tmp/codex-routes"
PATH="$tmp/agybin:$PATH" native_gate outbound-one former-claude 'RESULT: same milestone'
PATH="$tmp/agybin:$PATH" native_gate outbound-two former-claude 'RESULT: same milestone'
PATH="$tmp/agybin:$PATH" native_gate prior-socket 'uds:/run/claude/984.sock' 'RESULT: scoped socket milestone'
PATH="$tmp/agybin:$PATH" native_gate outbound-three former-claude 'RESULT: example PR opened'
diff -r "$tmp/codex-routes" "$claims/reports/routes"
rm -rf "$tmp/codex-routes"
mv "$tmp/codex-claim" "$root_claim"
rm "$CLAUDE_CONFIG_DIR/sessions/$replacement_pid.json"
fallback="$claims/workers/fallback-fixture.json"
fallback_transcript="$CLAUDE_CONFIG_DIR/projects/fixture/fallback-native-report.jsonl"
jq --arg transcript "$fallback_transcript" '.name = "fallback-fixture" | .spawnerScope = "vacant-project" |
  .claudeSession = {id:"fallback-native-report",transcript:$transcript}' "$legacy" > "$fallback"
jq -c '.sessionId = "fallback-native-report" | select(.type == "assistant")
  | if .message.stop_reason == "end_turn" then .message.content[0].text = "RESULT: fallback final" else . end' "$legacy_transcript" > "$fallback_transcript"
mkdir "$tmp/native-state" "$tmp/native-stage"
codex_role env ANDERTON_PROBE_STATE="$tmp/native-state" ANDERTON_PROBE_STAGE="$tmp/native-stage" "$script/worker.sh" sweep > "$tmp/native-output"
[ "$(grep -c '^RESULT: same milestone$' "$tmp/native-output")" = 2 ]
grep -qx 'RESULT: scoped socket milestone' "$tmp/native-output"
grep -qx 'RESULT: fallback final' "$tmp/native-output"
grep -qx 'RESULT: old unread final' "$tmp/native-output"
if grep -Eq 'historical transport|old delivered echo|unrelated message|unrelated socket' "$tmp/native-output"; then exit 1; fi
# A final reply with another milestone of the same kind as its turn's native send is a report of its own.
grep -qx 'RESULT: example PR opened' "$tmp/native-output"
grep -qx 'RESULT: example CI passed' "$tmp/native-output"
as_agy_holder
mkdir "$tmp/agy-native-state" "$tmp/agy-native-stage"
agy_role env ANDERTON_PROBE_STATE="$tmp/agy-native-state" ANDERTON_PROBE_STAGE="$tmp/agy-native-stage" "$script/worker.sh" sweep \
  > "$tmp/agy-native-output"
mv "$tmp/codex-claim" "$root_claim"
[ "$(grep -c '^RESULT: same milestone$' "$tmp/agy-native-output")" = 2 ]
grep -qx 'RESULT: scoped socket milestone' "$tmp/agy-native-output"
grep -qx 'RESULT: fallback final' "$tmp/agy-native-output"
grep -qx 'RESULT: old unread final' "$tmp/agy-native-output"
if grep -Eq 'historical transport|old delivered echo|unrelated message|unrelated socket' "$tmp/agy-native-output"; then exit 1; fi
grep -qx 'RESULT: example PR opened' "$tmp/agy-native-output"
grep -qx 'RESULT: example CI passed' "$tmp/agy-native-output"
if codex_role "$script/worker.sh" message legacy-reporter 'Refuse legacy transcript-only identity.' > "$tmp/refused" 2>&1; then exit 1; fi
mv "$tmp/native-stage/"*.json "$tmp/native-state/"
codex_role env ANDERTON_PROBE_STATE="$tmp/native-state" ANDERTON_PROBE_STAGE="$tmp/native-stage" "$script/worker.sh" sweep > "$tmp/native-output"
[ ! -s "$tmp/native-output" ]
sed 's/started for the task/never started for the task/' "$legacy_transcript" > "$tmp/replacement-transcript"
mv "$tmp/replacement-transcript" "$legacy_transcript"
TZ=UTC touch -t 203001030100 "$legacy_transcript"
rm "$tmp/native-state/claude-legacy-native-report.json"
codex_role env ANDERTON_PROBE_STATE="$tmp/native-state" ANDERTON_PROBE_STAGE="$tmp/native-stage" "$script/worker.sh" sweep > "$tmp/native-output"
[ ! -s "$tmp/native-output" ]

mkdir "$FIXTURE_NOTICE_HOME"
jq -nc --arg dir "$PWD" --arg home "$CODEX_HOME" '
  {name:"delayed-fixture",root:$dir,dir:$dir,provider:"codex",codexHome:$home,
   id:"019a0000-dddd-7222-8333-444455556666",spawnerScope:null}' > "$claims/workers/delayed-fixture.json"
jq '.peerMessage = {id:"pending-first",from:"fixture",text:"DEPLOY: the first message"}' "$root_claim" > "$tmp/updated-claim"
mv "$tmp/updated-claim" "$root_claim"
codex_role env ANDERTON_WATCH_TICK=1 "$script/watch.sh" --codex "$root_claim" > "$tmp/delayed-watch" 2>&1 &
fixture_watch=$!
wait_for_file() {
  local _
  for _ in $(seq 1 100); do
    if [ -s "$1" ]; then return; fi
    sleep 0.2
  done
  return 1
}
wait_for_file "$FIXTURE_NOTICE_HOME/current"
grep -q 'the first message' "$FIXTURE_NOTICE_HOME/current"
printf 'first-item\n' > "$FIXTURE_NOTICE_HOME/worker-blocked"
wait_for_file "${root_claim%.json}.$FIXTURE_THREAD.blocked"
grep -q 'delayed-fixture.*waiting on approval' "${root_claim%.json}.$FIXTURE_THREAD.blocked"
grep -q 'the first message' "$FIXTURE_NOTICE_HOME/current"
printf 'second-item\n' > "$FIXTURE_NOTICE_HOME/worker-blocked"
for _ in $(seq 1 100); do
  if grep -q 'second-item' "${root_claim%.json}.$FIXTURE_THREAD.blocked"; then break; fi
  sleep 0.2
done
grep -q 'second-item' "${root_claim%.json}.$FIXTURE_THREAD.blocked"
rm "$FIXTURE_NOTICE_HOME/worker-blocked"
touch "$FIXTURE_NOTICE_HOME/finish"
wait_for_file "$FIXTURE_NOTICE_HOME/second"
[ "$(grep -c 'delayed-fixture.*waiting on approval' "$FIXTURE_NOTICE_HOME/second")" = 2 ]
if grep -q 'the first message' "$FIXTURE_NOTICE_HOME/second"; then exit 1; fi

echo "coordinator: mixed claims, provider selection, adoption, handoff, and receipts passed"
