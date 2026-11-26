#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  for scenario in clear codex-route claude-route renamed-owner fallback-route prefix rename-steer rename-adopt upgrade resume-clear \
    adopted-restart dead-legacy; do
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
    # A worker record from before launch ids: its Stop hook no longer guesses which session it is, and in its repository
    # nothing is claimed until migrate-workers.sh stamps it from its live session.
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
    register "$target" legacy-id original "$dir"
    # Its Stop hook binds nothing, so it leaves at once rather than watching for directions.
    stop "$target" legacy-id >/dev/null 2>&1 &
    hook=$!
    pids="$pids $hook"
    for _ in $(seq 1 25); do
      kill -0 "$hook" 2>/dev/null || break
      sleep 0.2
    done
    if kill -0 "$hook" 2>/dev/null || ! jq -e '.claudeSession == null' "$worker" >/dev/null; then
      echo "The Stop hook bound a record from before launch ids on a guess"
      exit 1
    fi
    code=0
    env CLAUDE_PID="$target" CLAUDE_CODE_SESSION_ID=legacy-id "$scripts/claim.sh" --project upgraded > "$work/claim" 2>&1 || code=$?
    if [ "$code" -ne 4 ] || ! grep -q 'migrate-workers.sh' "$work/claim"; then echo "An unmigrated record did not hold the claim back"; exit 1; fi
    # Two live sessions in its checkout: neither is known to be the worker, so the record is left for a person.
    cp "$worker" "$work/before"
    code=0
    "$scripts/migrate-workers.sh" --apply > "$work/migrate" 2>&1 || code=$?
    if [ "$code" -ne 1 ] || ! grep -qF "original: left for a person: 2 live sessions run in $dir" "$work/migrate" ||
      ! cmp -s "$worker" "$work/before"; then
      echo "An ambiguous record was not left alone"
      exit 1
    fi
    rm "$sessions/$replacement.json"
    # One live session, running in the worker's pane: a dry run says what it would stamp and writes nothing.
    "$scripts/migrate-workers.sh" > "$work/migrate"
    if ! grep -qF "original: would be stamped with session legacy-id (pid $target), the one live session in $dir: it runs in the worker's tmux pane %5" "$work/migrate" ||
      ! cmp -s "$worker" "$work/before"; then
      echo "The dry run did not report the stamp, or wrote it"
      exit 1
    fi
    "$scripts/migrate-workers.sh" --apply > "$work/migrate"
    jq -e --argjson pid "$target" '.claudeSession | .id == "legacy-id" and .pid == $pid and .procStart != ""' "$worker" >/dev/null ||
      { echo "The verified legacy worker was not stamped"; exit 1; }
    cp "$worker" "$work/stamped"
    "$scripts/migrate-workers.sh" --apply > "$work/migrate"
    if ! grep -q '^original: identified: ' "$work/migrate" || ! cmp -s "$worker" "$work/stamped"; then echo "A second run changed the record"; exit 1; fi
    reply legacy-id 'RESULT: upgraded worker'
    stop "$target" legacy-id > "$work/stop" 2>&1 & watcher=$!
    pids="$pids $watcher"
    sweep > "$work/reports"
    grep -qFx 'RESULT: upgraded worker' "$work/reports"
    env CODEX_THREAD_ID=fixture-codex "$scripts/worker.sh" message original 'Directions still reach this worker.'
    code=0
    wait "$watcher" || code=$?
    [ "$code" -eq 2 ]
    grep -q 'Directions still reach this worker.' "$work/stop"
    ;;
  resume-clear)
    # A resume runs the worker's session as a new process, and /clear before its first turn ends gives that process a new
    # session id: the startup hook of the resume records the process, so the worker keeps custody of its new session.
    codex_claim; write_worker; child; first=$pid
    session=00000000-0000-4000-8000-0000000000a1
    register "$first" "$session" original "$dir"
    : > "$projects/fixture/$session.jsonl"
    bind "$session" "$first"
    kill "$first"
    wait "$first" 2>/dev/null || true
    rm -f "$sessions/$first.json"
    jq -nc --arg dir "$dir" --arg file "$projects/fixture/$session.jsonl" --arg id "$session" '
      {session_id:$id,cwd:$dir,transcript_path:$file,hook_event_name:"SessionStart",source:"resume"}' > "$work/resume.start"
    # The hook runs under the resumed process, which then stays: exec keeps its pid and its start time.
    bash -c 'CLAUDE_PID=$$ CLAUDE_CODE_SESSION_ID=$3 "$1" --claude-start < "$2"; exec sleep 120' _ "$scripts/watch.sh" "$work/resume.start" \
      "$session" &
    resumed=$!
    pids="$pids $resumed"
    for _ in $(seq 1 25); do
      if jq -e --argjson pid "$resumed" '.claudeSession.pid == $pid' "$worker" >/dev/null; then break; fi
      sleep 0.2
    done
    register "$resumed" cleared-id original "$dir"
    code=0
    env CLAUDE_PID="$resumed" CLAUDE_CODE_SESSION_ID=cleared-id "$scripts/claim.sh" --project resumed > "$work/claim" 2>&1 || code=$?
    if [ "$code" -ne 3 ] || ! grep -q "managed as worker 'original'" "$work/claim"; then
      echo "A resumed worker cleared before its first Stop escaped its record"
      exit 1
    fi
    ;;
  adopted-restart)
    # /restart keeps an adopted session's process and rewrites its registry entry with a new startedAt; /clear then gives
    # it a new session id. Its record names its process by pid and start time, so it is still the adopted worker.
    codex_claim; child; target=$pid
    jq -nc --argjson pid "$target" --arg dir "$root" --argjson at "$(( $(date +%s) - $(proc_age "$target") ))000" '
      {pid:$pid,sessionId:"adopted-id",cwd:$dir,name:"handmade",startedAt:$at}' > "$sessions/$target.json"
    env CODEX_THREAD_ID=fixture-codex "$scripts/adopt.sh" handmade > /dev/null
    jq --argjson later "$(( $(date +%s) + 5 ))000" '.startedAt = $later | .sessionId = "adopted-cleared"' "$sessions/$target.json" > "$work/restarted"
    mv "$work/restarted" "$sessions/$target.json"
    code=0
    env CLAUDE_PID="$target" CLAUDE_CODE_SESSION_ID=adopted-cleared "$scripts/claim.sh" --project adopted > "$work/claim" 2>&1 || code=$?
    if [ "$code" -ne 3 ] || ! grep -q "managed as worker 'handmade'" "$work/claim"; then
      echo "An adopted worker escaped its record after /restart and /clear"
      exit 1
    fi
    ;;
  dead-legacy)
    # A record from before launch ids whose worker has gone: once migrate-workers.sh marks it as naming no session, it
    # no longer holds the repository's claims back, and a second run leaves it as it is.
    codex_claim; write_worker
    jq 'del(.claudeLaunchId)' "$worker" > "$work/legacy"
    mv "$work/legacy" "$worker"
    child; caller=$pid
    register "$caller" caller-id caller "$root"
    code=0
    env CLAUDE_PID="$caller" CLAUDE_CODE_SESSION_ID=caller-id "$scripts/claim.sh" --project after-migration > "$work/claim" 2>&1 || code=$?
    if [ "$code" -ne 4 ]; then echo "An unmigrated record did not hold the claim back"; exit 1; fi
    # Its pane still runs a process: no session in its checkout is not enough to mark it.
    cp "$worker" "$work/before"
    code=0
    env FIXTURE_PANE_PID="$caller" "$scripts/migrate-workers.sh" --apply > "$work/migrate" 2>&1 || code=$?
    if [ "$code" -ne 1 ] || ! grep -qF "original: left for a person: no live session in $dir, but its pane %5 still shows one" "$work/migrate" ||
      ! cmp -s "$worker" "$work/before"; then
      echo "A record whose pane still runs something was marked"
      exit 1
    fi
    # Its pane is gone too: it is marked, and claims proceed.
    "$scripts/migrate-workers.sh" --apply > "$work/migrate"
    if ! grep -qF "original: marked as naming no session: no live session in $dir" "$work/migrate" ||
      ! jq -e '.migration.result == "names no session" and .claudeSession == null' "$worker" >/dev/null; then
      echo "The dead record was not marked"
      exit 1
    fi
    env CLAUDE_PID="$caller" CLAUDE_CODE_SESSION_ID=caller-id "$scripts/claim.sh" --project after-migration > "$work/claim"
    grep -q 'project after-migration claimed' "$work/claim"
    cp "$worker" "$work/marked"
    "$scripts/migrate-workers.sh" --apply > "$work/migrate"
    if ! grep -q '^original: identified: settled by an earlier run' "$work/migrate" || ! cmp -s "$worker" "$work/marked"; then
      echo "A second run changed the marked record"
      exit 1
    fi
    ;;
  *) exit 2 ;;
esac
echo "$1: ok"
