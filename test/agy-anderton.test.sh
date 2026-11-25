#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034 # check runs its eval strings later, so they must not expand here, and they read what is set for them
# An agy Anderton against fake herdr and agy CLIs: the launcher, the claim, the watch that tells it things through its
# pane, and the workers it starts.
# Runs under macOS's bash 3.2 as well as Linux: bash test/agy-anderton.test.sh
set -euo pipefail

scripts="$(cd "$(dirname "$0")/../skills/anderton/scripts" && pwd)"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/agy-anderton-test.XXXXXX")
tmp=$(cd "$tmp" && pwd -P)
cleanup() {
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
unset CLAUDE_PID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID TMUX ANDERTON_AGY_SESSION ANDERTON_AGY_NAME ANDERTON_AGY_DIR
mkdir -p "$HOME/.gemini/config" "$HOME/.gemini/antigravity-cli" "$tmp/bin" "$FAKE" "$CLAUDE_CONFIG_DIR/sessions" \
  "$tmp/guard/plugins/workflow-agents/hooks" "$tmp/repo"
export PATH="$tmp/bin:$PATH"

# A fake herdr: one tab per create, its root pane w9:p5. agent get answers from $FAKE/agent-get.<pane>, else
# agent_not_found; pane get from $FAKE/panes; prompts are logged one per line as "<pane> <text>".
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
  "pane close") rm -f "$FAKE/agent-get.$3"; grep -vx "$3" "$FAKE/panes" > "$FAKE/panes.tmp" || true; mv "$FAKE/panes.tmp" "$FAKE/panes" ;;
  *) exit 1 ;;
esac
FAKEHERDR
# A fake agy that records how it was started, and a claude that lists no sessions.
cat > "$tmp/bin/agy" <<'FAKEAGY'
#!/usr/bin/env bash
{
  echo "session=${ANDERTON_AGY_SESSION:-} name=${ANDERTON_AGY_NAME:-} claude=${CLAUDE_CODE_SESSION_ID:-}${CLAUDE_PID:-}"
  echo "dir=${ANDERTON_AGY_DIR:-} cwd=$(pwd -P)"
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
lead=(ANDERTON_AGY_SESSION=agy-lead-1 ANDERTON_AGY_NAME=agy-lead "ANDERTON_AGY_DIR=$repo" "${herdr_env[@]}" HERDR_PANE_ID=w9:p77)
as() { # as <env...> -- <command...>: sets $out and $status
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  set +e
  out=$(env "${envs[@]}" "$@" 2>&1)
  status=$?
  set -e
}
agent_in() { # agent_in <pane> <agent> [status] [conversation] [dir]: what herdr's agent get shows in <pane>: the agent, in
  # <dir> (the repository), in the conversation herdr's agy integration names (conv-<pane>; "" for none)
  jq -nc --arg pane "$1" --arg kind "$2" --arg status "${3:-idle}" --arg conv "${4-conv-$1}" --arg cwd "${5:-$repo}" \
    '{result: {agent: {agent: $kind, agent_status: $status, pane_id: $pane, cwd: $cwd,
      agent_session: (if $conv == "" then null else {value: $conv} end)}}}' > "$FAKE/agent-get.$1"
  grep -qx "$1" "$FAKE/panes" || echo "$1" >> "$FAKE/panes"
}

as HERDR_ENV= -- "$scripts/agy-anderton.sh" --name agy-lead
check "the launcher refuses outside herdr" eval '[ "$status" -eq 2 ] && contains "from a herdr pane"'
as "${herdr_env[@]}" HERDR_PANE_ID=w9:p77 CLAUDE_CODE_SESSION_ID=parent-1 CLAUDE_PID=1 -- "$scripts/agy-anderton.sh" --name agy-lead
check "the launcher starts the agy on PATH, as an Anderton session of its own, not the session it was started from" eval '[ "$status" -eq 0 ] &&
  grep -qE "^session=[0-9a-f-]{36} name=agy-lead claude=$" "$FAKE/agy-run"'
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
agent_in w9:p77 agy
as "${lead[@]}" -- "$scripts/claim.sh"
record=$(ls "$CLAUDE_CONFIG_DIR"/anderton/*.json)
check "an agy session claims the repository's role" eval '[ "$status" -eq 0 ] && contains "claimed by agy session agy-lead-1 (agy-lead, herdr pane w9:p77)"'
check "recorded with its pane and name" [ "$(jq -r '"\(.provider) \(.sessionId) \(.pane) \(.name) \(.dir)"' "$record")" = "agy agy-lead-1 w9:p77 agy-lead $repo" ]
check "and the agy conversation herdr names in that pane" [ "$(jq -r .agyInstance "$record")" = conv-w9:p77 ]
check "and its watch runs" eventually [ -s "${record%.json}.watch" ]
agent_in w9:p78 agy
as ANDERTON_AGY_SESSION=agy-other-1 ANDERTON_AGY_NAME=agy-other "ANDERTON_AGY_DIR=$repo" "${herdr_env[@]}" HERDR_PANE_ID=w9:p78 -- "$scripts/claim.sh"
check "another agy session cannot take it while herdr shows the holder in its pane" eval '[ "$status" -eq 3 ] && contains "held by agy session agy-lead-1"'
as "${herdr_env[@]}" ANDERTON_AGY_SESSION=agy-lead-1 "ANDERTON_AGY_DIR=$repo" HERDR_PANE_ID=w9:p77 -- "$scripts/claim.sh"
check "a claim without the launcher's name is refused" eval '[ "$status" -eq 1 ] && contains "agy-anderton.sh started"'

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
as "${lead[@]}" -- "$scripts/spawn.sh" --provider claude --effort low lead-claude <<'BRIEF'
Tidy the example module.
BRIEF
check "an agy Anderton starts a Claude worker in herdr" eval '[ "$status" -eq 0 ] && grep -qx -- default "$FAKE/start" &&
  grep -qx -- --plugin-dir "$FAKE/start"'
check "which reports in its final replies, to the agy Anderton" [ "$(jq -r '"\(.reportTransport) \(.spawnerProvider) \(.spawner)"' "$CLAUDE_CONFIG_DIR/anderton/workers/lead-claude.json")" = "transcript agy agy-lead" ]
check "and the brief says so" grep -qF "w9:p5 Tidy the example module." "$FAKE/prompts"
mv "$CLAUDE_CONFIG_DIR/anderton/workers/lead-claude.json" "$tmp/lead-claude.json"
git -C "$repo" worktree remove --force "$ANDERTON_WORKTREES/wt-lead-claude"
agent_in w9:p5 agy
as "${lead[@]}" -- "$scripts/spawn.sh" --provider agy --effort low lead-agy <<'BRIEF'
Tidy the example module.
BRIEF
jq -c --arg cwd "$ANDERTON_WORKTREES/wt-lead-agy" '.result.agent.cwd = $cwd' "$FAKE/agent-get.w9:p5" > "$FAKE/agent-get.tmp"
mv "$FAKE/agent-get.tmp" "$FAKE/agent-get.w9:p5"
check "and an agy worker" eval '[ "$status" -eq 0 ] && grep -qx -- agy "$FAKE/start" &&
  [ "$(jq -r .spawnerProvider "$CLAUDE_CONFIG_DIR/anderton/workers/lead-agy.json")" = agy ]'
: > "$FAKE/prompts"
as "${lead[@]}" -- "$scripts/worker.sh" message lead-agy "Rebase on main."
check "which it directs through the worker's pane" eval '[ "$status" -eq 0 ] && grep -qx "w9:p5 Rebase on main." "$FAKE/prompts"'
as "${lead[@]}" -- "$scripts/retire.sh" lead-agy
check "and retires once it has read the pane" eval '[ "$status" -eq 4 ] && contains "agy keeps no transcript"'
as "${lead[@]}" -- "$scripts/retire.sh" lead-agy --reviewed-through "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
check "then retires" eval '[ "$status" -eq 0 ] && [ ! -e "$CLAUDE_CONFIG_DIR/anderton/workers/lead-agy.json" ]'

# A named project's Anderton on agy is the same claim, scoped.
agent_in w9:p78 agy
as ANDERTON_AGY_SESSION=agy-proj-1 ANDERTON_AGY_NAME=agy-proj "ANDERTON_AGY_DIR=$repo" "${herdr_env[@]}" HERDR_PANE_ID=w9:p78 -- "$scripts/claim.sh" --project example
check "an agy session claims a named project's role" eval '[ "$status" -eq 0 ] && contains "project example claimed by agy session agy-proj-1"'

# A workgroup's role on agy is a workgroup-scoped claim, which tells the host it started as any holder's does.
agent_in w9:p80 agy
printf '#!/bin/sh\ncat >> "%s"\n' "$FAKE/events" > "$tmp/bin/event-log"
chmod +x "$tmp/bin/event-log"
as ANDERTON_AGY_SESSION=agy-wg-1 ANDERTON_AGY_NAME=agy-wg "ANDERTON_AGY_DIR=$repo" "${herdr_env[@]}" HERDR_PANE_ID=w9:p80 \
  "ANDERTON_EVENT_COMMAND=$tmp/bin/event-log" -- "$scripts/claim.sh" --project workgroup:example/demo
check "an agy session claims a workgroup project's role" eval '[ "$status" -eq 0 ] && contains "project workgroup:example/demo claimed by agy session agy-wg-1"'
check "and the host hears it started" eventually grep -q '"scope":"workgroup:example/demo","kind":"start"' "$FAKE/events"

# A claim needs herdr's agy integration, which names the conversation in the pane.
agent_in w9:p83 agy idle ""
as ANDERTON_AGY_SESSION=agy-plain-1 ANDERTON_AGY_NAME=agy-plain "ANDERTON_AGY_DIR=$repo" "${herdr_env[@]}" HERDR_PANE_ID=w9:p83 -- "$scripts/claim.sh" --project plain
check "a claim is refused where herdr names no agy conversation" eval '[ "$status" -eq 1 ] && contains "herdr integration install antigravity-cli"'

# A new agy conversation in the holder's pane, after a relaunch or /clear there, is another holder: the role is free.
agent_in w9:p77 agy idle conv-new
as ANDERTON_AGY_SESSION=agy-lead-2 ANDERTON_AGY_NAME=agy-lead "ANDERTON_AGY_DIR=$repo" "${herdr_env[@]}" HERDR_PANE_ID=w9:p77 -- "$scripts/claim.sh"
check "a new agy conversation in the holder's pane claims the role without taking it over" eval '[ "$status" -eq 0 ] &&
  contains "claimed by agy session agy-lead-2" && [ "$(jq -r .agyInstance "$record")" = conv-new ]'

# Once herdr no longer shows the holder in its pane, the role is free, and its watch leaves.
rm -f "$FAKE/agent-get.w9:p77"
grep -vx w9:p77 "$FAKE/panes" > "$FAKE/panes.tmp" || true
mv "$FAKE/panes.tmp" "$FAKE/panes"
agent_in w9:p79 agy
as ANDERTON_AGY_SESSION=agy-other-1 ANDERTON_AGY_NAME=agy-other "ANDERTON_AGY_DIR=$repo" "${herdr_env[@]}" HERDR_PANE_ID=w9:p79 -- "$scripts/claim.sh"
check "another agy session claims a role whose holder's pane is gone" eval '[ "$status" -eq 0 ] && contains "claimed by agy session agy-other-1"'

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
check "and starts agy at the top of that checkout, which its tool shells are told" eval '[ "$status" -eq 0 ] &&
  grep -qxF "dir=$linked cwd=$linked" "$FAKE/agy-run" && grep -qF "for $linked." "$FAKE/agy-run" &&
  grep -qxF "{\"exampleSetting\":true,\"trustedWorkspaces\":[\"$linked\"]}" "$FAKE/agy-run"'
agent_in w9:p81 agy idle conv-linked "$linked"
cd "$linked/sub"
as ANDERTON_AGY_SESSION=agy-linked-1 ANDERTON_AGY_NAME=agy-linked "ANDERTON_AGY_DIR=$linked" "${herdr_env[@]}" HERDR_PANE_ID=w9:p81 -- \
  "$scripts/claim.sh" --project linked
cd "$repo"
check "an agy session in a linked worktree claims the repository's role, recorded in its own checkout" eval '[ "$status" -eq 0 ] &&
  [ "$(jq -r "select(.scope == \"linked\") | .dir" "$CLAUDE_CONFIG_DIR"/anderton/*.json)" = "$linked" ]'
agent_in w9:p82 agy
as ANDERTON_AGY_SESSION=agy-other-2 ANDERTON_AGY_NAME=agy-other "ANDERTON_AGY_DIR=$repo" "${herdr_env[@]}" HERDR_PANE_ID=w9:p82 -- \
  "$scripts/claim.sh" --project linked
check "where herdr shows it live, so another session cannot take it" eval '[ "$status" -eq 3 ] && contains "held by agy session agy-linked-1"'
as ANDERTON_AGY_SESSION=agy-other-2 ANDERTON_AGY_NAME=agy-other "ANDERTON_AGY_DIR=$tmp" "${herdr_env[@]}" HERDR_PANE_ID=w9:p82 -- \
  "$scripts/claim.sh" --project elsewhere
check "a claim from a session opened in another directory is refused" eval '[ "$status" -eq 1 ] && contains "runs in another repository"'

if [ "$failures" -gt 0 ]; then
  echo "$failures agy-anderton check(s) failed"
  exit 1
fi
echo "agy-anderton: ok"
