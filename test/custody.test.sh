#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  for scenario in clear codex-route claude-route renamed-owner fallback-route prefix rename-steer rename-adopt upgrade; do
    "$BASH" "$0" "$scenario"
  done
  exit 0
fi

scripts=$(cd "$(dirname "$0")/../skills/anderton/scripts" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/anderton-custody.XXXXXX")
work=$(cd "$work" && pwd -P)
pids=""
cleanup() {
  local p
  for p in $pids; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT
export CLAUDE_CONFIG_DIR="$work/claude"
export CODEX_HOME="$work/codex"
export PATH="$work/bin:$PATH"
unset CLAUDE_PID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID TMUX HERDR_ENV
# shellcheck source=SCRIPTDIR/../skills/anderton/scripts/session-lib.sh
. "$scripts/session-lib.sh"
sessions="$CLAUDE_CONFIG_DIR/sessions"
projects="$CLAUDE_CONFIG_DIR/projects"
workers="$CLAUDE_CONFIG_DIR/anderton/workers"
root="$work/repo"
dir="$root/worker"
mkdir -p "$sessions" "$projects/fixture" "$workers" "$CODEX_HOME" "$work/bin" "$dir" "$work/state" "$work/stage"
cat > "$work/bin/tmux" <<'TMUX'
#!/usr/bin/env bash
case "$*" in
  '-S /tmp/fixture.sock list-panes -a '*'pane_pid'*) echo "539 %5 $FIXTURE_PANE_PID" ;;
  *) exit 1 ;;
esac
TMUX
chmod +x "$work/bin/tmux"
git init -q "$root"
cd "$root"
claim="$CLAUDE_CONFIG_DIR/anderton/$(printf '%s' "$root" | git hash-object --stdin).json"
worker="$workers/original.json"

child() {
  sleep 120 &
  pid=$!
  pids="$pids $pid"
}

register() {
  jq -nc --argjson pid "$1" --arg id "$2" --arg name "$3" --arg dir "$4" '
    {pid:$pid,sessionId:$id,cwd:$dir,name:$name,status:"busy"}' > "$sessions/$1.json"
}

codex_claim() {
  jq -nc --arg root "$root" --arg home "$CODEX_HOME" '
    {provider:"codex",root:$root,scope:null,dir:$root,codexHome:$home,sessionId:"fixture-codex",
     claudeReportSince:"2030-01-02T00:00:00Z",claudeReportPreviousHolder:{sessionId:"former-owner",pid:984}}
    ' > "$claim"
}

write_worker() {
  jq -nc --arg root "$root" --arg dir "$dir" '
    {name:"original",root:$root,dir:$dir,launcher:"tmux",pane:"%5",socket:"/tmp/fixture.sock",server:"539",
     worktree:true,spawner:"old-lead",spawnerProvider:"claude",spawnerSession:"former-owner",spawnerScope:null,
     startedAt:"2030-01-01T00:00:00Z",claudeLaunchId:"original-id"}' > "$worker"
}

reply() {
  jq -nc --arg id "$1" --arg text "$2" '
    {type:"assistant",sessionId:$id,uuid:($id + "-reply"),timestamp:"2030-01-03T00:00:00Z",
     message:{stop_reason:"end_turn",content:[{type:"text",text:$text}]}}' >> "$projects/fixture/$1.jsonl"
}

send_event() {
  jq -nc --arg id "$1" --arg tool "$2" --arg to "$3" --arg text "$4" '
    {type:"assistant",sessionId:$id,uuid:($tool + "-event"),timestamp:"2030-01-03T00:00:00Z",
     message:{stop_reason:"tool_use",content:[{type:"tool_use",name:"SendMessage",id:$tool,input:{to:$to,message:$text}}]}}'     >> "$projects/fixture/$1.jsonl"
}

stop() {
  env CLAUDE_PID="$1" CLAUDE_CODE_SESSION_ID="$2" ANDERTON_WATCH_TICK=1 "$scripts/watch.sh" < "$work/$2.stop"
}

stop_input() {
  jq -nc --arg id "$1" --arg dir "$dir" --arg transcript "$projects/fixture/$1.jsonl" '
    {session_id:$id,cwd:$dir,transcript_path:$transcript,hook_event_name:"Stop"}' > "$work/$1.stop"
}

wait_binding() {
  local _
  for _ in $(seq 1 25); do
    if jq -e --arg id "$1" '.claudeSession.id == $id' "$worker" >/dev/null; then return 0; fi
    sleep 0.2
  done
  return 1
}

bind() {
  bind_claude_worker "$worker" "$1" "$2" "$(proc_start "$2")" "$projects/fixture/$1.jsonl"
}

sweep() {
  env CODEX_THREAD_ID=fixture-codex ANDERTON_PROBE_STATE="$work/state" ANDERTON_PROBE_STAGE="$work/stage" "$scripts/worker.sh" sweep
}

gate() {
  jq -nc --arg dir "$dir" --arg to "$1" --arg tool "$2" --arg text "$3" '
    {session_id:"original-id",cwd:$dir,tool_use_id:$tool,hook_event_name:"PreToolUse",tool_input:{to:$to,message:$text}}' |
    "$scripts/report-gate.sh"
}

case "$1" in
  clear)
    codex_claim; write_worker; child; target=$pid
    register "$target" original-id original "$dir"
    reply original-id 'RESULT: before clear'
    bind original-id "$target"
    register "$target" cleared-id original "$dir"
    reply cleared-id 'RESULT: after clear'
    stop_input cleared-id
    stop "$target" cleared-id > "$work/stop" 2>&1 & watcher=$!
    pids="$pids $watcher"
    wait_binding cleared-id || { echo "Fixture did not bind its new native transcript"; exit 1; }
    sweep > "$work/reports"
    grep -qFx 'RESULT: before clear' "$work/reports" || { echo "Lost the pre-clear report"; exit 1; }
    grep -qFx 'RESULT: after clear' "$work/reports"
    mv "$work/stage/"*.json "$work/state/"
    [ -z "$(sweep)" ]
    ;;
  codex-route | claude-route | renamed-owner | fallback-route | prefix)
    codex_claim; write_worker; child; target=$pid
    register "$target" original-id original "$dir"
    : > "$projects/fixture/original-id.jsonl"
    bind original-id "$target"
    child; replacement=$pid
    register "$replacement" unrelated-id old-lead "$root"
    if [ "$1" = claude-route ] || [ "$1" = renamed-owner ]; then
      child; next_owner=$pid
      owner_id=new-owner-id
      if [ "$1" = renamed-owner ]; then owner_id=former-owner; fi
      register "$next_owner" "$owner_id" new-lead "$root"
      jq -nc --arg root "$root" --argjson pid "$next_owner" --arg id "$owner_id" '
        {provider:"claude",root:$root,scope:null,pid:$pid,sessionId:$id}' > "$claim"
    elif [ "$1" = fallback-route ]; then
      jq '.spawnerScope = "departed-project"' "$worker" > "$work/scoped"
      mv "$work/scoped" "$worker"
    fi
    if [ "$1" = prefix ]; then
      send_event original-id explicit-peer 'old-lead [unrelated-ref]' 'RESULT: explicit unrelated recipient'
      send_event original-id unverified-name old-lead 'RESULT: unverified bare delivery'
      sweep > "$work/reports"
      [ ! -s "$work/reports" ] || { cat "$work/reports"; exit 1; }
    else
      code=0
      gate old-lead stale-name 'RESULT: expected coordinator' > "$work/gate" 2>&1 || code=$?
      [ "$code" -eq 2 ] || { echo "Stale bare recipient was allowed"; exit 1; }
      gate 'old-lead [unrelated-ref]' explicit-peer 'Hello from an unrelated conversation'
      if [ "$1" = codex-route ] || [ "$1" = fallback-route ]; then
        send_event original-id stale-name old-lead 'RESULT: expected coordinator'
        reply original-id 'RESULT: expected coordinator'
        gate old-lead changed-text 'RESULT: acknowledged original text' > "$work/gate" 2>&1 || [ "$?" = 2 ]
        send_event original-id changed-text old-lead 'RESULT: different text under same tool ID'
        gate old-lead changed-recipient 'RESULT: same body but different recipient' > "$work/gate" 2>&1 || [ "$?" = 2 ]
        send_event original-id changed-recipient 'old-lead [unrelated-ref]' 'RESULT: same body but different recipient'
        sweep > "$work/reports"
        [ "$(grep -c '^RESULT:' "$work/reports")" -eq 1 ]
        grep -qFx 'RESULT: expected coordinator' "$work/reports"
      fi
    fi
    ;;
  rename-steer | rename-adopt)
    codex_claim; write_worker; child; target=$pid
    register "$target" original-id original "$dir"
    : > "$projects/fixture/original-id.jsonl"
    bind original-id "$target"
    register "$target" original-id renamed "$dir"
    printf '{truncated' > "$workers/a-malformed.json"
    ln -s "$work/missing.json" "$workers/a-dangling.json"
    if [ "$1" = rename-steer ]; then
      env CODEX_THREAD_ID=fixture-codex "$scripts/worker.sh" message original 'Keep working under your fresh display name.'
      jq -e '.claudeDirection.target == "original-id"' "$worker" >/dev/null
    else
      child; scoped=$pid
      register "$scoped" scoped-id scoped-lead "$root"
      env CLAUDE_PID="$scoped" CLAUDE_CODE_SESSION_ID=scoped-id "$scripts/claim.sh" --project other >/dev/null
      if env CLAUDE_PID="$scoped" CLAUDE_CODE_SESSION_ID=scoped-id "$scripts/adopt.sh" renamed > "$work/adopt" 2>&1; then
        echo "A second coordinator adopted the renamed worker"
        exit 1
      fi
      grep -q 'already reports to' "$work/adopt"
      [ ! -e "$workers/renamed.json" ]
    fi
    ;;
  upgrade)
    codex_claim; write_worker
    jq --arg launch "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      .startedAt = $launch | .spawnerProvider = "codex" | .reportTransport = "transcript" | del(.claudeLaunchId)' "$worker" > "$work/legacy"
    mv "$work/legacy" "$worker"
    child; target=$pid
    export FIXTURE_PANE_PID=$target
    child; replacement=$pid
    for id in replacement-id legacy-id; do
      jq -nc --arg id "$id" --arg dir "$dir" '
        {type:"user",sessionId:$id,uuid:($id + "-launch"),timestamp:"2030-01-02T00:00:00Z",cwd:$dir,
         message:{content:("Task.\nYou are a worker the Anderton session \"old-lead\" started for the task above, in " + $dir + ".")}}' \
        > "$projects/fixture/$id.jsonl"
      stop_input "$id"
    done
    register "$replacement" replacement-id original "$dir"
    stop "$replacement" replacement-id >/dev/null 2>&1
    jq -e '.claudeSession == null' "$worker" >/dev/null
    rm "$sessions/$replacement.json"
    register "$target" legacy-id original "$dir"
    reply legacy-id 'RESULT: upgraded worker'
    stop "$target" legacy-id > "$work/stop" 2>&1 & watcher=$!
    pids="$pids $watcher"
    wait_binding legacy-id || { echo "The verified legacy worker did not bind"; exit 1; }
    sweep > "$work/reports"
    grep -qFx 'RESULT: upgraded worker' "$work/reports"
    env CODEX_THREAD_ID=fixture-codex "$scripts/worker.sh" message original 'Directions still reach this worker.'
    code=0
    wait "$watcher" || code=$?
    [ "$code" -eq 2 ]
    grep -q 'Directions still reach this worker.' "$work/stop"
    ;;
  *) exit 2 ;;
esac
echo "$1: ok"
