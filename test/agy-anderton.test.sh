#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034 # check runs its eval strings later, so they must not expand here, and they read what is set for them
# An agy Anderton against fake herdr and agy CLIs: the launcher, the claim, the watch that tells it things through its
# pane, and the workers it starts.
# Runs under macOS's bash 3.2 as well as Linux: bash test/agy-anderton.test.sh
set -euo pipefail

scripts="$(cd "$(dirname "$0")/../skills/anderton/scripts" && pwd)"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/agy-anderton-test.XXXXXX")
tmp=$(cd "$tmp" && pwd -P)
agy_procs=""
cleanup() {
  for pid in $agy_procs; do kill "$pid" 2>/dev/null || true; done
  rm -f "$tmp"/claude/anderton/*.json 2>/dev/null || true
  sleep 0.5
  chmod -R u+w "$tmp" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
failures=0
check() { # check <description> <command...>
  local description=$1
  shift
  if "$@"; then echo "ok   $description"; else echo "FAIL $description"; failures=$((failures + 1)); fi
}
contains() { case $out in *"$1"*) return 0 ;; *) return 1 ;; esac; }
eventually() { # eventually <command...>: true once it is, within five seconds
  local _
  for _ in $(seq 1 50); do
    if "$@"; then return 0; fi
    sleep 0.1
  done
  return 1
}

export HOME="$tmp/home" CLAUDE_CONFIG_DIR="$tmp/claude" ANDERTON_WORKTREES="$tmp/worktrees" ANDERTON_WATCH_TICK=0.2
export FAKE="$tmp/fake"
unset CLAUDE_PID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID TMUX ANDERTON_AGY_SESSION ANDERTON_AGY_NAME ANDERTON_AGY_DIR ANDERTON_AGY_PID \
  ANTIGRAVITY_CONVERSATION_ID ANDERTON_AGY_SANDBOXED
mkdir -p "$HOME/.gemini/config" "$HOME/.gemini/antigravity-cli" "$tmp/bin" "$FAKE" "$CLAUDE_CONFIG_DIR/sessions" \
  "$tmp/guard/plugins/workflow-agents/hooks" "$tmp/repo"
export PATH="$tmp/bin:$PATH"

# A fake herdr: one tab per create, its root pane w9:p5. agent get answers from $FAKE/agent-get.<pane>, else
# agent_not_found; pane get from $FAKE/panes; pane process-info names the process in $FAKE/pid.<pane> as the pane's agy; prompts are logged one per line as "<pane> <text>".
cat > "$tmp/bin/herdr" <<'FAKEHERDR'
#!/usr/bin/env bash
case "$1 $2" in
  "tab create") echo '{"result":{"root_pane":{"pane_id":"w9:p5","tab_id":"w9:t5"},"tab":{"tab_id":"w9:t5"}}}' ;;
  "agent start") printf '%s\n' "$@" > "$FAKE/start" ;;
  "agent read") printf 'Antigravity CLI example\n? for shortcuts\n' ;;
  "agent prompt") printf '%s %s\n' "$3" "$(printf '%s' "$4" | tr '\n' ' ')" >> "$FAKE/prompts" ;;
  "agent get") cat "$FAKE/agent-get.$3" 2>/dev/null || { echo '{"error":{"code":"agent_not_found"}}' >&2; exit 1; } ;;
  "pane get")
    grep -qx "$3" "$FAKE/panes" 2>/dev/null || { echo '{"error":{"code":"pane_not_found"}}'; exit 1; }
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3"
    ;;
  "pane process-info")
    pid=$(cat "$FAKE/pid.$4" 2>/dev/null) || { echo '{"error":{"code":"pane_not_found"}}'; exit 1; }
    if [ "$pid" = empty ]; then echo '{"result":{"process_info":{"foreground_processes":[]}}}'; exit 0; fi
    case $pid in noname:*) printf '{"result":{"process_info":{"foreground_processes":[{"name":"","pid":%s}]}}}\n' "${pid#noname:}"; exit 0 ;; esac
    printf '{"result":{"process_info":{"foreground_process_group_id":%s,"foreground_processes":[{"name":"agy","pid":%s}]}}}\n' "$pid" "$pid"
    ;;
  "pane close") rm -f "$FAKE/agent-get.$3"; grep -vx "$3" "$FAKE/panes" > "$FAKE/panes.tmp" || true; mv "$FAKE/panes.tmp" "$FAKE/panes" ;;
  *) exit 1 ;;
esac
FAKEHERDR
# A fake agy that records how it was started, and a claude that lists no sessions.
cat > "$tmp/bin/agy" <<'FAKEAGY'
#!/usr/bin/env bash
{
  echo "session=${ANDERTON_AGY_SESSION:-} name=${ANDERTON_AGY_NAME:-} claude=${CLAUDE_CODE_SESSION_ID:-}${CLAUDE_PID:-}"
  echo "dir=${ANDERTON_AGY_DIR:-} cwd=$(pwd -P) pid=${ANDERTON_AGY_PID:-} self=$$"
  printf '%s\n' "$@"
} > "$FAKE/agy-run"
FAKEAGY
printf '#!/bin/sh\ncase $1 in agents) echo "[]" ;; *) exit 2 ;; esac\n' > "$tmp/bin/claude"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/bun"
printf '#!/bin/sh\nexit 0\n' > "$tmp/guard/plugins/workflow-agents/hooks/agy-guard.sh"
printf 'export const WATCHDOG_SECONDS = 3630;\n' > "$tmp/guard/plugins/workflow-agents/hooks/agy-supervisor.ts"
chmod +x "$tmp/bin/"*
: > "$HOME/.gemini/config/.migrated"
printf '{"exampleSetting":true}' > "$HOME/.gemini/antigravity-cli/settings.json"
"$scripts/agy-hooks.sh" register --guard "$tmp/guard" >/dev/null
: > "$FAKE/panes"
: > "$FAKE/prompts"

cd "$tmp/repo"
git init -q
git -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m seed
repo=$(pwd -P)
herdr_env=(HERDR_ENV=1 HERDR_WORKSPACE_ID=w9 "HERDR_SOCKET_PATH=$tmp/herdr.sock")
# Stand-ins for agy processes, copies of bash named agy, under which the claims run as agy's tool shells do. The lead's
# runs each command it is sent as its child, across many commands, and a check below ends and replaces it; this shell
# stands in for the rest.
mkdir -p "$tmp/plainbin"
cp "$(command -v bash)" "$tmp/plainbin/agy"
start_agy() { # start_agy: starts one; sets $agy_pid and $agy_jobs
  agy_jobs=$(mktemp -d "$tmp/agy-jobs.XXXXXX")
  mkfifo "$agy_jobs/fifo"
  "$tmp/plainbin/agy" -c 'while read -r job < "$1/fifo"; do
    bash "$job" > "$job.out" 2>&1 < "$job.in"; echo $? > "$job.st"; mv "$job.st" "$job.status"; done' agy "$agy_jobs" &
  agy_pid=$!
  agy_procs="$agy_procs $agy_pid"
}
in_agy() { # in_agy <jobs> [--stdin <file>] <env...> -- <command...>: runs it under that agy, here; sets $out and $status
  local jobs=$1 input=/dev/null job
  shift
  if [ "$1" = --stdin ]; then input=$2; shift 2; fi
  job=$(mktemp "$jobs/job.XXXXXX")
  {
    printf 'cd %q || exit 1\nexec env' "$(pwd -P)"
    while [ "$1" != -- ]; do printf ' %q' "$1"; shift; done
    shift
    printf ' %q' "$@"
    printf '\n'
  } > "$job"
  cp "$input" "$job.in"
  echo "$job" > "$jobs/fifo"
  while [ ! -e "$job.status" ]; do sleep 0.1; done
  out=$(cat "$job.out")
  status=$(cat "$job.status")
}
start_agy
lead_agy=$agy_pid lead_jobs=$agy_jobs
# What agy gives its tool shells: its conversation, and the launcher's role name; herdr adds the pane.
lead=(ANTIGRAVITY_CONVERSATION_ID=conv-lead ANDERTON_AGY_NAME=agy-lead "${herdr_env[@]}" HERDR_PANE_ID=w9:p77)
agy_id() { jq -r '.sessionId' "$1"; } # a claim's session, which the scripts derive from its agy process
as() { # as <env...> -- <command...>: sets $out and $status
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  set +e
  out=$(env "${envs[@]}" "$@" 2>&1)
  status=$?
  set -e
}
agent_in() { # agent_in <pane> <agent> [status] [conversation] [dir] [pid]: what herdr shows in <pane>: the agent, in
  # <dir> (the repository), in the conversation herdr's agy integration names (conv-<pane>; "" for none), as process <pid>
  # (the one it showed there before, else this shell)
  if [ -n "${6:-}" ]; then echo "$6" > "$FAKE/pid.$1"; elif [ ! -e "$FAKE/pid.$1" ]; then echo $$ > "$FAKE/pid.$1"; fi
  jq -nc --arg pane "$1" --arg kind "$2" --arg status "${3:-idle}" --arg conv "${4-conv-$1}" --arg cwd "${5:-$repo}" \
    '{result: {agent: {agent: $kind, agent_status: $status, pane_id: $pane, cwd: $cwd,
      agent_session: (if $conv == "" then null else {value: $conv} end)}}}' > "$FAKE/agent-get.$1"
  grep -qx "$1" "$FAKE/panes" || echo "$1" >> "$FAKE/panes"
}

plain_agy() { # plain_agy <pane> [--dangerously-skip-permissions] [VAR=value...] -- <command...>: runs it under a one-off
  # plain agy in <pane>, here; sets $out and $status
  local pane=$1 flag=plain envs=()
  shift
  while [ "$1" != -- ]; do
    case $1 in *=*) envs+=("$1") ;; *) flag=$1 ;; esac
    shift
  done
  shift
  agent_in "$pane" agy
  as "${herdr_env[@]}" "HERDR_PANE_ID=$pane" ANTIGRAVITY_CONVERSATION_ID=conv-plain CLAUDE_CODE_SESSION_ID=parent-9 CLAUDE_PID=1 \
    ${envs[@]+"${envs[@]}"} -- "$tmp/plainbin/agy" -c 'echo "agy-pid=$$"; echo $$ > "$FAKE/pid.$1"; shift 2; "$@"; exit $?' agy "$pane" "$flag" "$@"
}
session_agy() { # session_agy <pane> [dir]: a long-lived agy in <pane>, started in <dir>; sets $agy_pid and $agy_jobs
  (cd "${2:-$PWD}" && start_agy && echo "$agy_pid $agy_jobs" > "$tmp/started")
  read -r agy_pid agy_jobs < "$tmp/started"
  agy_procs="$agy_procs $agy_pid"
  agent_in "$1" agy idle "conv-$1" "${3:-$repo}" "$agy_pid"
}

as HERDR_ENV= -- "$scripts/agy-anderton.sh" --name agy-lead
check "the launcher refuses outside herdr" eval '[ "$status" -eq 2 ] && contains "from a herdr pane"'
as "${herdr_env[@]}" HERDR_PANE_ID=w9:p77 CLAUDE_CODE_SESSION_ID=parent-1 CLAUDE_PID=1 -- "$scripts/agy-anderton.sh" --name agy-lead
check "the launcher starts the agy on PATH under the role's name, not as the session it was started from" eval '[ "$status" -eq 0 ] &&
  grep -qx "session= name=agy-lead claude=" "$FAKE/agy-run"'
check "and supplies no identity of its own, which the scripts read from the agy process" eval 'grep -qE "^dir= cwd=.* pid= self=[0-9]+$" "$FAKE/agy-run"'
check "with no permission prompts, pointed at the Anderton skill" eval 'grep -qx -- --dangerously-skip-permissions "$FAKE/agy-run" &&
  grep -qF "Read $(cd "$scripts/.." && pwd)/SKILL.md" "$FAKE/agy-run"'
check "trusting the repository for this session, with agy's saved settings kept" \
  grep -qxF "{\"exampleSetting\":true,\"trustedWorkspaces\":[\"$repo\"]}" "$FAKE/agy-run"
as "${herdr_env[@]}" HERDR_PANE_ID=w9:p77 -- "$scripts/agy-anderton.sh" --name agy-lead --mode plan -i "Example prompt."
check "or in the agy mode and with the prompt it is given" eval '[ "$status" -eq 0 ] && ! grep -qx -- --dangerously-skip-permissions "$FAKE/agy-run" &&
  ! grep -qF "SKILL.md" "$FAKE/agy-run"'
chmod u+w "$HOME/.gemini/config/hooks.json"
as "${herdr_env[@]}" HERDR_PANE_ID=w9:p77 -- "$scripts/agy-anderton.sh" --name agy-lead
check "the launcher refuses while agy would run unguarded" eval '[ "$status" -eq 1 ] && contains "agy would run unguarded"'
"$scripts/agy-hooks.sh" register --guard "$tmp/guard" >/dev/null

# The claim, from the agy session's tool shell.
agent_in w9:p77 agy idle conv-w9:p77 "$repo" "$lead_agy"
in_agy "$lead_jobs" "${lead[@]}" -- "$scripts/claim.sh"
record=$(ls "$CLAUDE_CONFIG_DIR"/anderton/*.json)
check "an agy session claims the repository's role, as the agy process it runs under" eval '[ "$status" -eq 0 ] &&
  contains "claimed by agy session agy-$lead_agy-" && contains "(agy-lead, herdr pane w9:p77)"'
check "recorded with its pane and name" [ "$(jq -r '"\(.provider) \(.pane) \(.name) \(.dir)"' "$record")" = "agy w9:p77 agy-lead $repo" ]
check "and the agy process it runs in" [ "$(jq -r .agyPid "$record")" = "$lead_agy" ]
check "and its watch runs" eventually [ -s "${record%.json}.watch" ]
plain_agy w9:p78 ANDERTON_AGY_NAME=agy-other -- "$scripts/claim.sh"
check "another agy session cannot take it while herdr shows the holder in its pane" eval '[ "$status" -eq 3 ] &&
  contains "held by agy session $(agy_id "$record")"'
in_agy "$lead_jobs" "${lead[@]}" ANDERTON_AGY_NAME=agy-lead-again -- "$scripts/claim.sh" --project second
check "one agy process holds one role, whatever it calls itself" eval '[ "$status" -eq 3 ] && contains "already holds the repository role"'
# The holder's session id, pane and pid are only variables: a shell that does not run under that agy is not the holder.
forged=("${lead[@]}" "ANDERTON_AGY_SESSION=$(agy_id "$record")" "ANDERTON_AGY_PID=$lead_agy" "ANDERTON_AGY_DIR=$repo")
as "${forged[@]}" -- "$scripts/claim.sh"
check "a shell naming the holder's session, pane and agy process, but not running under it, cannot claim as it" eval '[ "$status" -ne 0 ] &&
  [ "$(jq -r .agyPid "$record")" = "$lead_agy" ]'
printf 'Tidy the example module.\n' | as "${forged[@]}" -- "$scripts/spawn.sh" --provider claude --effort low forged-worker
check "nor act as the Anderton" eval '[ "$status" -ne 0 ] && [ ! -e "$CLAUDE_CONFIG_DIR/anderton/workers/forged-worker.json" ]'

# What agy loads hooks from in the Anderton's own checkout changes: its watch tells it once, through its pane.
mkdir -p "$repo/.agents"
printf '{}' > "$repo/.agents/hooks.json"
check "the holder's watch prompts its pane with the change" eventually grep -qF "w9:p77 Anderton watch: a session you answer for is blocked" "$FAKE/prompts"
check "naming the file" grep -qF "=== Anderton agy-lead (agy hook or agent configuration changed since it claimed the role" "$FAKE/prompts"
sleep 1
check "once" [ "$(grep -c "^w9:p77 " "$FAKE/prompts")" -eq 1 ]
rm -rf "$repo/.agents"
: > "$FAKE/prompts"
# A busy holder is told once it is idle again.
agent_in w9:p77 agy working
printf '{}' > "$HOME/.gemini/hooks.json"
sleep 1
check "a busy holder's pane is not prompted" eval '[ ! -s "$FAKE/prompts" ]'
agent_in w9:p77 agy idle
check "until it is idle" eventually grep -qF "w9:p77 Anderton watch" "$FAKE/prompts"
rm -f "$HOME/.gemini/hooks.json"
: > "$FAKE/prompts"

# The workers it starts report to it the way they report to a Codex Anderton.
printf 'Tidy the example module.\n' > "$tmp/brief.md"
in_agy "$lead_jobs" --stdin "$tmp/brief.md" "${lead[@]}" -- "$scripts/spawn.sh" --provider claude --effort low lead-claude
check "an agy Anderton starts a Claude worker in herdr" eval '[ "$status" -eq 0 ] && grep -qx -- default "$FAKE/start" &&
  grep -qx -- --plugin-dir "$FAKE/start"'
check "which reports in its final replies, to the agy Anderton" [ "$(jq -r '"\(.reportTransport) \(.spawnerProvider) \(.spawner)"' "$CLAUDE_CONFIG_DIR/anderton/workers/lead-claude.json")" = "transcript agy agy-lead" ]
check "and the brief says so" grep -qF "w9:p5 Tidy the example module." "$FAKE/prompts"
mv "$CLAUDE_CONFIG_DIR/anderton/workers/lead-claude.json" "$tmp/lead-claude.json"
git -C "$repo" worktree remove --force "$ANDERTON_WORKTREES/wt-lead-claude"
agent_in w9:p5 agy
in_agy "$lead_jobs" --stdin "$tmp/brief.md" "${lead[@]}" -- "$scripts/spawn.sh" --provider agy --effort low lead-agy
jq -c --arg cwd "$ANDERTON_WORKTREES/wt-lead-agy" '.result.agent.cwd = $cwd' "$FAKE/agent-get.w9:p5" > "$FAKE/agent-get.tmp"
mv "$FAKE/agent-get.tmp" "$FAKE/agent-get.w9:p5"
check "and an agy worker" eval '[ "$status" -eq 0 ] && grep -qx -- agy "$FAKE/start" &&
  [ "$(jq -r .spawnerProvider "$CLAUDE_CONFIG_DIR/anderton/workers/lead-agy.json")" = agy ]'
: > "$FAKE/prompts"
in_agy "$lead_jobs" "${lead[@]}" -- "$scripts/worker.sh" message lead-agy "Rebase on main."
check "which it directs through the worker's pane" eval '[ "$status" -eq 0 ] && grep -qx "w9:p5 Rebase on main." "$FAKE/prompts"'
in_agy "$lead_jobs" "${lead[@]}" -- "$scripts/retire.sh" lead-agy
check "and retires once it has read the pane" eval '[ "$status" -eq 4 ] && contains "agy keeps no transcript"'
in_agy "$lead_jobs" "${lead[@]}" -- "$scripts/retire.sh" lead-agy --reviewed-through "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
check "then retires" eval '[ "$status" -eq 0 ] && [ ! -e "$CLAUDE_CONFIG_DIR/anderton/workers/lead-agy.json" ]'

# A named project's Anderton on agy is the same claim, scoped.
plain_agy w9:p78 ANDERTON_AGY_NAME=agy-proj -- "$scripts/claim.sh" --project example
check "an agy session claims a named project's role" eval '[ "$status" -eq 0 ] && contains "project example claimed by agy session agy-"'

# A workgroup's role on agy is a workgroup-scoped claim, which tells the host it started as any holder's does.
printf '#!/bin/sh\ncat >> "%s"\n' "$FAKE/events" > "$tmp/bin/event-log"
chmod +x "$tmp/bin/event-log"
plain_agy w9:p80 ANDERTON_AGY_NAME=agy-wg "ANDERTON_EVENT_COMMAND=$tmp/bin/event-log" -- "$scripts/claim.sh" --project workgroup:example/demo
check "an agy session claims a workgroup project's role" eval '[ "$status" -eq 0 ] && contains "project workgroup:example/demo claimed by agy session agy-"'
check "and the host hears it started" eventually grep -q '"scope":"workgroup:example/demo","kind":"start"' "$FAKE/events"

# /clear starts a new conversation in the same agy process: the holder keeps the role, and its watch.
agent_in w9:p77 agy idle conv-cleared
lead_watch=$(cat "${record%.json}.watch")
plain_agy w9:p78 ANDERTON_AGY_NAME=agy-other -- "$scripts/claim.sh"
check "after /clear in the holder's pane, another session cannot take the role" eval '[ "$status" -eq 3 ] &&
  contains "held by agy session agy-$lead_agy-"'
sleep 1
check "and its watch still runs" eval '[ "$(cat "${record%.json}.watch")" = "$lead_watch" ] && kill -0 "${lead_watch%% *}"'
# A relaunch in that pane is another agy process: the old holder is gone, and the new one claims without --take-over.
kill "$lead_agy"
start_agy
lead_agy=$agy_pid lead_jobs=$agy_jobs
agent_in w9:p77 agy idle conv-relaunched "$repo" "$lead_agy"
in_agy "$lead_jobs" "${lead[@]}" -- "$scripts/claim.sh"
check "an agy relaunched in the holder's pane claims the role without taking it over" eval '[ "$status" -eq 0 ] &&
  contains "claimed by agy session agy-$lead_agy-" && [ "$(jq -r .agyPid "$record")" = "$lead_agy" ]'

# Once herdr no longer shows the holder in its pane, the role is free, and its watch leaves.
rm -f "$FAKE/agent-get.w9:p77"
grep -vx w9:p77 "$FAKE/panes" > "$FAKE/panes.tmp" || true
mv "$FAKE/panes.tmp" "$FAKE/panes"
session_agy w9:p79
other_agy=$agy_pid other_jobs=$agy_jobs
other=(ANTIGRAVITY_CONVERSATION_ID=conv-other ANDERTON_AGY_NAME=agy-other "${herdr_env[@]}" HERDR_PANE_ID=w9:p79)
in_agy "$other_jobs" "${other[@]}" -- "$scripts/claim.sh"
check "another agy session claims a role whose holder's pane is gone" eval '[ "$status" -eq 0 ] && contains "claimed by agy session agy-$other_agy-"'
# A take-over of a live agy holder tells it, in its pane, who took the role and how to hand it back.
session_agy w9:p82
taker_agy=$agy_pid taker_jobs=$agy_jobs
: > "$FAKE/prompts"
in_agy "$taker_jobs" ANTIGRAVITY_CONVERSATION_ID=conv-taker ANDERTON_AGY_NAME=agy-taker "${herdr_env[@]}" HERDR_PANE_ID=w9:p82 -- "$scripts/claim.sh" --take-over
check "an agy take-over of a live holder says how to hand it back" eval '[ "$status" -eq 0 ] && contains "Took it over from agy session agy-$other_agy-" &&
  contains "claim.sh --take-over"'
check "and the displaced holder's watch tells it in its pane" eventually grep -qE "^w9:p79 Anderton watch: agy session agy-$taker_agy-[0-9a-f]+ \(agy-taker\) took over your role" "$FAKE/prompts"
in_agy "$other_jobs" "${other[@]}" -- "$scripts/claim.sh" --take-over
check "and it takes the role back the way it was told" eval '[ "$status" -eq 0 ] && contains "Took it over from agy session agy-$taker_agy-"'

# Opened below the top of a linked worktree, agy runs at the top of that checkout, guarded and trusted for it.
git -C "$repo" worktree add -q "$tmp/linked"
linked=$(cd "$tmp/linked" && pwd -P)
mkdir -p "$linked/sub" "$linked/.agents"
printf '{"agent-anderton-agy-guard":{}}' > "$linked/.agents/hooks.json"
cd "$linked/sub"
as "${herdr_env[@]}" HERDR_PANE_ID=w9:p81 -- "$scripts/agy-anderton.sh" --name agy-linked
check "the launcher refuses a linked worktree whose workspace hooks would switch the guard off" eval '[ "$status" -eq 1 ] &&
  contains "agy would run unguarded"'
rm -rf "$linked/.agents"
as "${herdr_env[@]}" HERDR_PANE_ID=w9:p81 -- "$scripts/agy-anderton.sh" --name agy-linked
cd "$repo"
check "and starts agy at the top of that checkout" eval '[ "$status" -eq 0 ] &&
  grep -qF "dir= cwd=$linked " "$FAKE/agy-run" && grep -qF "for $linked." "$FAKE/agy-run" &&
  grep -qxF "{\"exampleSetting\":true,\"trustedWorkspaces\":[\"$linked\"]}" "$FAKE/agy-run"'
session_agy w9:p81 "$linked/sub" "$linked"
linked_agy=$agy_pid
cd "$linked/sub"
in_agy "$agy_jobs" ANTIGRAVITY_CONVERSATION_ID=conv-linked ANDERTON_AGY_NAME=agy-linked "${herdr_env[@]}" HERDR_PANE_ID=w9:p81 -- \
  "$scripts/claim.sh" --project linked
cd "$repo"
check "an agy session in a linked worktree claims the repository's role, recorded in its own checkout" eval '[ "$status" -eq 0 ] &&
  [ "$(jq -r "select(.scope == \"linked\") | .dir" "$CLAUDE_CONFIG_DIR"/anderton/*.json)" = "$linked" ]'
plain_agy w9:p82 ANDERTON_AGY_NAME=agy-other -- "$scripts/claim.sh" --project linked
check "where herdr shows it live, so another session cannot take it" eval '[ "$status" -eq 3 ] && contains "held by agy session agy-$linked_agy-"'
# agy opened in a directory outside the repository, whose tool shell runs in the repository.
cd "$tmp"
plain_agy w9:p82 ANDERTON_AGY_NAME=agy-other -- bash -c 'cd "$1" && shift && exec "$@"' in "$repo" "$scripts/claim.sh" --project elsewhere
cd "$repo"
check "a claim from a session opened in another directory is refused" eval '[ "$status" -eq 1 ] && contains "runs in another repository"'

# An agy session opened plainly in a herdr pane, which runs /anderton: its tool shells carry only agy's own variables,
# here with a Claude Code session's leaking in from where agy was started.
plain_agy w9:p90 -- "$scripts/claim.sh" --project plain
plain_record=$(grep -l '"scope":"plain"' "$CLAUDE_CONFIG_DIR"/anderton/*.json || true)
check "a plain agy session claims a role as itself, not as the Claude Code session it was started from" eval '[ "$status" -eq 0 ] &&
  contains "project plain claimed by agy session agy-" && [ "$(jq -r .provider "$plain_record")" = agy ]'
check "recorded with the agy process it runs under, its pane, its checkout and a name from it" eval '
  [ "$(jq -r "\"\(.agyPid) \(.pane) \(.dir) \(.name)\"" "$plain_record")" = "$(printf "%s" "$out" | sed -n "s/^agy-pid=//p") w9:p90 $repo agy-repo-plain" ]'
check "and told once that agy started this way prompts, with the relaunch into this conversation that does not" eval 'contains "started without --dangerously-skip-permissions" &&
  contains "agy --dangerously-skip-permissions --conversation=conv-plain,"'
plain_agy w9:p92 --dangerously-skip-permissions -- "$scripts/claim.sh" --project plain-unprompted
check "one started with no permission prompts is not told so" eval '[ "$status" -eq 0 ] && contains "claimed by agy session agy-" &&
  ! contains "started without --dangerously-skip-permissions"'
as "${herdr_env[@]}" HERDR_PANE_ID=w9:p93 ANTIGRAVITY_CONVERSATION_ID=conv-sandboxed ANDERTON_AGY_SANDBOXED=1 -- "$scripts/claim.sh" --project sandboxed
check "a sandbox flag from the environment is not believed, nor is the shell's claim" eval '[ "$status" -ne 0 ] && ! contains "terminal sandbox" &&
  ! grep -q "\"scope\":\"sandboxed\"" "$CLAUDE_CONFIG_DIR"/anderton/*.json'
plain_agy w9:p94 -- env HERDR_PANE_ID=w9:p95 "$scripts/claim.sh" --project unseen
check "a claim from a pane where herdr shows no agy is refused" eval '[ "$status" -eq 1 ] && contains "herdr does not show this agy in pane w9:p95"'
chmod u+w "$HOME/.gemini/config/hooks.json"
plain_agy w9:p96 -- "$scripts/claim.sh" --project unguarded
"$scripts/agy-hooks.sh" register --guard "$tmp/guard" >/dev/null
check "and one where agy would run unguarded" eval '[ "$status" -eq 1 ] && contains "agy would run unguarded"'
# An agy worker's tool shells look like any plain agy session's: its record, by pane, refuses it the role.
agent_in w9:p5 agy
in_agy "$other_jobs" --stdin "$tmp/brief.md" "${other[@]}" -- "$scripts/spawn.sh" --provider agy --effort low plain-worker
check "an agy Anderton starts an agy worker" [ "$status" -eq 0 ]
plain_agy w9:p5 -- "$scripts/claim.sh" --project from-worker
check "whose session cannot claim a role" eval '[ "$status" -eq 3 ] && contains "managed as worker '"'"'plain-worker'"'"'"'
plain_agy w9:p5 "HERDR_SOCKET_PATH=$tmp/other-herdr.sock" ANDERTON_AGY_NAME=agy-elsewhere -- "$scripts/claim.sh" --project other-server
check "though a session in the same pane id on another herdr server is not that worker" eval '[ "$status" -eq 0 ] &&
  contains "project other-server claimed by agy session agy-"'

# Two agy sessions in one checkout: a claim holds while herdr shows its own agy process in its pane, not just any agy.
session_agy w9:p98
bound_agy=$agy_pid
in_agy "$agy_jobs" ANTIGRAVITY_CONVERSATION_ID=conv-bound ANDERTON_AGY_NAME=agy-bound "${herdr_env[@]}" HERDR_PANE_ID=w9:p98 -- \
  "$scripts/claim.sh" --project bound
check "an agy session claims a project role" eval '[ "$status" -eq 0 ] && contains "project bound claimed by agy session agy-$bound_agy-"'
plain_agy w9:p99 ANDERTON_AGY_NAME=agy-other -- "$scripts/claim.sh" --project bound
check "which another agy session in the checkout cannot take" eval '[ "$status" -eq 3 ] && contains "held by agy session agy-$bound_agy-"'
echo $$ > "$FAKE/pid.w9:p98"
plain_agy w9:p99 ANDERTON_AGY_NAME=agy-other -- "$scripts/claim.sh" --project bound
check "until herdr shows another agy process in the holder's pane" eval '[ "$status" -eq 0 ] && contains "project bound claimed by agy session agy-"'

# The guard check reads what agy loads: from agy's own home, not the tool shell's, and from every workspace directory
# between agy's working directory and the top of the checkout, which the watch keeps fingerprinting.
mkdir -p "$tmp/shellhome/.gemini/config" "$tmp/shellhome/.gemini/antigravity-cli"
: > "$tmp/shellhome/.gemini/config/.migrated"
HOME="$tmp/shellhome" "$scripts/agy-hooks.sh" register --guard "$tmp/guard" >/dev/null
chmod u+w "$HOME/.gemini/config/hooks.json"
plain_agy w9:p85 ANDERTON_AGY_NAME=agy-homed -- env "HOME=$tmp/shellhome" "$scripts/claim.sh" --project homed
"$scripts/agy-hooks.sh" register --guard "$tmp/guard" >/dev/null
check "a tool shell whose HOME names a guarded configuration cannot claim while agy's own runs unguarded" eval '[ "$status" -eq 1 ] &&
  contains "agy would run unguarded"'
mkdir -p "$repo/deep/er"
session_agy w9:p84 "$repo/deep/er"
deep=(ANTIGRAVITY_CONVERSATION_ID=conv-deep ANDERTON_AGY_NAME=agy-deep "${herdr_env[@]}" HERDR_PANE_ID=w9:p84)
deep_jobs=$agy_jobs
in_agy "$deep_jobs" "${deep[@]}" -- "$scripts/claim.sh" --project deep
check "an agy opened two directories below the top claims" eval '[ "$status" -eq 0 ] && contains "project deep claimed by agy session agy-"'
mkdir "$repo/deep/.agents"
printf '{}' > "$repo/deep/.agents/hooks.json"
in_agy "$deep_jobs" "${deep[@]}" -- "$scripts/waiting.sh"
check "and is told when a workspace between there and the top changes what agy loads" eval '[ "$status" -eq 0 ] &&
  contains "agy-deep (agy hook or agent configuration changed since it claimed the role" && contains "$repo/deep/.agents/hooks.json"'
rm -rf "$repo/deep/.agents"
mkdir -p "$repo/deep/er/.agents"
chmod 000 "$repo/deep/er/.agents"
cd "$repo/deep/er"
plain_agy w9:p83 ANDERTON_AGY_NAME=agy-closed -- "$scripts/claim.sh" --project closed
cd "$repo"
chmod 755 "$repo/deep/er/.agents"
check "a claim from where agy's workspace hooks cannot be read is refused" eval '[ "$status" -eq 1 ] && contains "cannot read"'

# A herdr answer about the holder's pane that says nothing usable is no evidence the holder left.
session_agy w9:p87
in_agy "$agy_jobs" ANTIGRAVITY_CONVERSATION_ID=conv-steady ANDERTON_AGY_NAME=agy-steady "${herdr_env[@]}" HERDR_PANE_ID=w9:p87 -- \
  "$scripts/claim.sh" --project steady
steady_agy=$agy_pid
echo "not-a-pid" > "$FAKE/pid.w9:p87"
plain_agy w9:p86 ANDERTON_AGY_NAME=agy-other -- "$scripts/claim.sh" --project steady
check "a holder herdr gives no readable process for keeps its role" eval '[ "$status" -eq 3 ] && contains "held by agy session agy-$steady_agy-"'
echo empty > "$FAKE/pid.w9:p87"
plain_agy w9:p86 ANDERTON_AGY_NAME=agy-other -- "$scripts/claim.sh" --project steady
check "nor an empty list of the pane's processes" eval '[ "$status" -eq 3 ] && contains "held by agy session agy-$steady_agy-"'
echo "noname:$steady_agy" > "$FAKE/pid.w9:p87"
plain_agy w9:p86 ANDERTON_AGY_NAME=agy-other -- "$scripts/claim.sh" --project steady
check "nor a listing of the holder's process with no name" eval '[ "$status" -eq 3 ] && contains "held by agy session agy-$steady_agy-"'
echo "$steady_agy" > "$FAKE/pid.w9:p87"
jq -c 'del(.result.agent.cwd)' "$FAKE/agent-get.w9:p87" > "$FAKE/agent-get.tmp"
mv "$FAKE/agent-get.tmp" "$FAKE/agent-get.w9:p87"
plain_agy w9:p86 ANDERTON_AGY_NAME=agy-other -- "$scripts/claim.sh" --project steady
check "nor an answer about the pane that leaves out its directory" eval '[ "$status" -eq 3 ] && contains "held by agy session agy-$steady_agy-"'
agent_in w9:p87 agy idle conv-w9:p87 "$repo" "$steady_agy"

# One agy process holds one role through every path to its herdr socket, and is the role's only while herdr shows it in
# the role's pane.
session_agy w9:p76
single_agy=$agy_pid single_jobs=$agy_jobs
ln -s "$tmp" "$tmp/socket-link"
in_agy "$single_jobs" ANTIGRAVITY_CONVERSATION_ID=conv-single ANDERTON_AGY_NAME=agy-single "${herdr_env[@]}" HERDR_PANE_ID=w9:p76 -- \
  "$scripts/claim.sh" --project single-a
in_agy "$single_jobs" ANTIGRAVITY_CONVERSATION_ID=conv-single ANDERTON_AGY_NAME=agy-single HERDR_ENV=1 HERDR_WORKSPACE_ID=w9 \
  "HERDR_SOCKET_PATH=$tmp/socket-link/herdr.sock" HERDR_PANE_ID=w9:p76 -- "$scripts/claim.sh" --project single-b
check "one agy process holds one role, by whichever path it names its herdr socket" eval '[ "$status" -eq 3 ] &&
  contains "already holds project single-a"'
single_record=$(grep -l '"scope":"single-a"' "$CLAUDE_CONFIG_DIR"/anderton/*.json)
# A claim an earlier version wrote may name the socket by a link; it is the same socket.
jq --arg socket "$tmp/socket-link/herdr.sock" '.socket = $socket' "$single_record" > "$tmp/claim.tmp"
mv "$tmp/claim.tmp" "$single_record"
in_agy "$single_jobs" ANTIGRAVITY_CONVERSATION_ID=conv-single ANDERTON_AGY_NAME=agy-single "${herdr_env[@]}" HERDR_PANE_ID=w9:p76 -- \
  "$scripts/claim.sh" --project single-c
check "and by whichever path its claim names it" eval '[ "$status" -eq 3 ] && contains "already holds project single-a"'
# Its reclaim keeps the claim's id and a direction waiting for it, though an earlier version named the session otherwise.
# The pane shows agy busy, so the role's watch holds the direction rather than typing it.
agent_in w9:p76 agy working conv-w9:p76 "$repo" "$single_agy"
jq '.sessionId = "earlier-session-name" | .peerMessage = {id: "peer-1", from: "example", text: "DIRECTION: example."}' \
  "$single_record" > "$tmp/claim.tmp"
mv "$tmp/claim.tmp" "$single_record"
single_claim_id=$(jq -r .claimId "$single_record")
in_agy "$single_jobs" ANTIGRAVITY_CONVERSATION_ID=conv-single ANDERTON_AGY_NAME=agy-single "${herdr_env[@]}" HERDR_PANE_ID=w9:p76 -- \
  "$scripts/claim.sh" --project single-a
check "the same agy process's reclaim keeps the claim's id and its waiting direction" eval '[ "$status" -eq 0 ] &&
  [ "$(jq -r "\"\(.claimId) \(.peerMessage.id)\"" "$single_record")" = "$single_claim_id peer-1" ]'
agent_in w9:p76 agy idle conv-w9:p76 "$repo" "$single_agy"
echo $$ > "$FAKE/pid.w9:p76"
in_agy "$single_jobs" --stdin "$tmp/brief.md" ANTIGRAVITY_CONVERSATION_ID=conv-single ANDERTON_AGY_NAME=agy-single "${herdr_env[@]}" \
  HERDR_PANE_ID=w9:p76 -- "$scripts/spawn.sh" --provider claude --effort low single-worker
check "once herdr shows another process in the role's pane, its agy cannot act as the Anderton" eval '[ "$status" -ne 0 ] &&
  [ ! -e "$CLAUDE_CONFIG_DIR/anderton/workers/single-worker.json" ]'
echo "$single_agy" > "$FAKE/pid.w9:p76"

# What the role's watch runs reads and sweeps as the claim, and nothing else acts as it.
session_agy w9:p88
watched_agy=$agy_pid watched_jobs=$agy_jobs
watched=(ANTIGRAVITY_CONVERSATION_ID=conv-watched ANDERTON_AGY_NAME=agy-watched "${herdr_env[@]}" HERDR_PANE_ID=w9:p88)
in_agy "$watched_jobs" "${watched[@]}" -- "$scripts/claim.sh" --project watched
watched_record=$(grep -l '"scope":"watched"' "$CLAUDE_CONFIG_DIR"/anderton/*.json)
in_agy "$watched_jobs" --stdin "$tmp/brief.md" "${watched[@]}" -- "$scripts/spawn.sh" --provider claude --effort low watched-worker
check "an agy Anderton starts a worker" [ "$status" -eq 0 ]
# Its watch is replaced by a stand-in this test controls, recorded as the watch is.
eventually [ -s "${watched_record%.json}.watch" ]
kill "$(cut -d' ' -f1 "${watched_record%.json}.watch")"
eventually [ ! -e "${watched_record%.json}.watch" ]
start_agy
watch_sim=$agy_pid watch_jobs=$agy_jobs
watch_start=$(
  # shellcheck source=SCRIPTDIR/../skills/anderton/scripts/session-lib.sh
  . "$scripts/session-lib.sh"
  proc_start "$watch_sim"
)
printf '%s %s 0 %s\n' "$watch_sim" "$(agy_id "$watched_record")" "$watch_start" > "${watched_record%.json}.watch"
watched_id=$(jq -r .claimId "$watched_record")
in_agy "$watch_jobs" "ANDERTON_AGY_WATCH_CLAIM=$watched_record" ANDERTON_AGY_WATCH_CLAIM_ID=earlier-claim -- "$scripts/waiting.sh" --workers
check "a shell under a watch that served an earlier claim of the role lists nothing" eval '[ "$status" -eq 0 ] && [ -z "$out" ]'
in_agy "$watch_jobs" "ANDERTON_AGY_WATCH_CLAIM=$watched_record" "ANDERTON_AGY_WATCH_CLAIM_ID=$watched_id" -- "$scripts/waiting.sh" --workers
check "a shell under the role's watch lists the role's workers" eval '[ "$status" -eq 0 ] && contains "workers/watched-worker.json"'
in_agy "$watch_jobs" --stdin "$tmp/brief.md" "ANDERTON_AGY_WATCH_CLAIM=$watched_record" "ANDERTON_AGY_WATCH_CLAIM_ID=$watched_id" -- "$scripts/spawn.sh" --provider claude --effort low watch-spawned
check "but cannot start one" eval '[ "$status" -ne 0 ] && [ ! -e "$CLAUDE_CONFIG_DIR/anderton/workers/watch-spawned.json" ]'
in_agy "$watch_jobs" "ANDERTON_AGY_WATCH_CLAIM=$watched_record" "ANDERTON_AGY_WATCH_CLAIM_ID=$watched_id" -- "$scripts/claim.sh" --project watched
check "nor claim as the holder" eval '[ "$status" -ne 0 ] && [ "$(jq -r .agyPid "$watched_record")" = "$watched_agy" ]'
as "ANDERTON_AGY_WATCH_CLAIM=$watched_record" "ANDERTON_AGY_WATCH_CLAIM_ID=$watched_id" -- "$scripts/waiting.sh" --workers
check "and a shell not under the watch, naming the claim, lists nothing" eval '[ "$status" -eq 0 ] && [ -z "$out" ]'
# A watch an earlier version started, which records no start time, is named for a restart.
printf '%s %s 0\n' "$watch_sim" "$(agy_id "$watched_record")" > "${watched_record%.json}.watch"
in_agy "$watched_jobs" "${watched[@]}" -- "$scripts/waiting.sh"
check "a watch an earlier version started is named, with the restart" eval 'contains "agy-watched (its watch started before these scripts were updated" &&
  contains "run claim.sh again"'
rm -f "${watched_record%.json}.watch"

# agy loads workspace hooks from each directory between its working directory and the top of the checkout.
mkdir -p "$repo/sub/.agents"
printf '{"agent-anderton-agy-guard":{}}' > "$repo/sub/.agents/hooks.json"
cd "$repo/sub"
plain_agy w9:p97 -- "$scripts/claim.sh" --project nested
check "a plain agy session opened in a subdirectory whose workspace hooks would switch the guard off cannot claim" eval '[ "$status" -eq 1 ] &&
  contains "$repo/sub/.agents/hooks.json could override"'
rm "$repo/sub/.agents/hooks.json"
plain_agy w9:p97 -- "$scripts/claim.sh" --project nested
check "and claims once they would not" eval '[ "$status" -eq 0 ] && contains "project nested claimed by agy session agy-"'
cd "$repo"

# Once agy's /anderton is registered, a copy of these scripts elsewhere on disk, such as an older checkout, cannot claim.
"$scripts/agy-hooks.sh" skill >/dev/null
mkdir -p "$tmp/stale/skills"
cp -R "$scripts/.." "$tmp/stale/skills/anderton"
registered_msg="agy's /anderton runs $(cd "$scripts/.." && pwd -P): use $(cd "$scripts/.." && pwd -P)/scripts instead."
plain_agy w9:p89 -- "$tmp/stale/skills/anderton/scripts/claim.sh" --project stale
check "a stale copy of the scripts elsewhere on disk refuses to claim, naming the registered one" eval '[ "$status" -eq 1 ] &&
  contains "$registered_msg"'
plain_agy w9:p89 -- "$scripts/claim.sh" --project stale
check "while the registered copy claims" eval '[ "$status" -eq 0 ] && contains "project stale claimed by agy session agy-"'
"$scripts/agy-hooks.sh" skill --remove >/dev/null
# A link in the registered copy's folder to another copy runs that copy: the script that runs is what counts.
mkdir -p "$tmp/registered/skills"
cp -R "$scripts/.." "$tmp/registered/skills/anderton"
registered=$(cd "$tmp/registered/skills/anderton" && pwd -P)
"$registered/scripts/agy-hooks.sh" skill >/dev/null
ln -s "$tmp/stale/skills/anderton/scripts/claim.sh" "$registered/scripts/claim-linked.sh"
plain_agy w9:p89 ANDERTON_AGY_NAME=agy-linked-copy -- "$registered/scripts/claim-linked.sh" --project linked-copy
check "a link to another copy, from inside the registered folder, refuses to claim" eval '[ "$status" -eq 1 ] &&
  contains "agy'"'"'s /anderton runs $registered"'
# A registration that is unreadable or not one agy-hooks.sh wrote does not lift the check.
printf -- '---\nname: anderton\n---\nExample skill.\n' > "$HOME/.gemini/config/skills/anderton/SKILL.md"
plain_agy w9:p89 ANDERTON_AGY_NAME=agy-unmarked -- "$tmp/stale/skills/anderton/scripts/claim.sh" --project unmarked
check "an anderton skill agy-hooks.sh did not write refuses every copy's claim" eval '[ "$status" -eq 1 ] &&
  contains "not one agy-hooks.sh skill wrote"'
rm -rf "$HOME/.gemini/config/skills/anderton"

if [ "$failures" -gt 0 ]; then
  echo "$failures agy-anderton check(s) failed"
  exit 1
fi
echo "agy-anderton: ok"
