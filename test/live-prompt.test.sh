#!/usr/bin/env bash
# shellcheck disable=SC2016 # check runs its eval strings later, so they must not expand here
# Drives prompt.sh against real Claude Code sessions blocked on real prompts, each in a pane of a private tmux server.
# Not part of CI: it needs a logged-in claude and tmux, and spends a little usage. Run it by hand before changing
# prompt.sh. PROMPT_SH picks the script under test, so a check can be removed from a copy to see this suite fail.
#   bash test/live-prompt.test.sh
# Bash 3.2 and BSD userland, like the scripts it drives.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
scripts="$here/../skills/anderton/scripts"
prompt_sh="${PROMPT_SH:-$scripts/prompt.sh}"
for tool in claude tmux jq git; do command -v "$tool" >/dev/null 2>&1 || { echo "needs $tool"; exit 1; }; done

work=$(mktemp -d "${TMPDIR:-/tmp}/anderton-live.XXXXXX")
work=$(cd "$work" && pwd -P)
sock="anderton-live-$$"
home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
holder_record="" herdr_tabs=""
cleanup() {
  tmux -L "$sock" kill-server 2>/dev/null || true
  if [ -n "$holder_record" ]; then rm -f "$holder_record"; fi
  for tab in $herdr_tabs; do herdr tab close "$tab" >/dev/null 2>&1 || true; done
  rm -rf "$work"
}
trap cleanup EXIT

repo="$work/repo"
git init -q "$repo"
git -C "$repo" -c user.name=t -c user.email=t@example.test commit -q --allow-empty -m init
# A hook that asks is how a session with permissions bypassed still blocks on a person.
cat > "$work/hook.sh" <<'HOOK'
#!/usr/bin/env bash
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"live test"}}'
HOOK
chmod +x "$work/hook.sh"
jq -n '{permissions: {ask: ["Bash(*rule-marker*)", "Bash(*node_modules/.bin/vitest*)"]}}' > "$work/ask-settings.json"
jq -n --arg c "$work/hook.sh" '{hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: $c}]}]}}' > "$work/hook-settings.json"

failures=0
check() { # check <description> <command...>
  local what=$1
  shift
  if "$@"; then
    echo "ok   $what"
  else
    echo "FAIL $what"
    failures=$((failures + 1))
    if [ -n "${LIVE_FAIL_FAST:-}" ]; then exit 1; fi
  fi
}
# The server's environment reaches panes, and $TMUX reaches prompt.sh, so nothing here touches the user's own tmux.
t() { tmux -L "$sock" "$@"; }

start_session() { # start_session <name> [mode] [claude args...]: a real interactive session in a new window, ready for input
  local name=$1 mode=${2:-default} trusted="" reg
  shift 2 || shift
  t new-window -d -n "$name" -c "$repo" "claude -n $name --permission-mode $mode --model haiku $*"
  for _ in $(seq 1 60); do
    sleep 1
    pane_text=$(t capture-pane -p -t "live:$name" 2>/dev/null || true)
    case $pane_text in
      *"Yes, I trust"* | *"trust this folder"*)
        if [ -z "$trusted" ]; then
          t send-keys -t "live:$name" Down
          sleep 1
          t send-keys -t "live:$name" Enter
          trusted=1
        fi
        ;;
    esac
    reg=$(registry_of "$name")
    if [ -n "$reg" ] && [ "$(jq -r '.status // empty' "$reg")" = idle ]; then return 0; fi
  done
  echo "session $name never became ready"
  exit 1
}

registry_of() { # registry_of <name>: prints the path of the live session's registry entry
  local f
  for f in "$home"/sessions/*.json; do
    if [ "$(jq -r '.name // empty' "$f" 2>/dev/null)" = "$1" ] && [ "$(jq -r '.cwd // empty' "$f" 2>/dev/null)" = "$repo" ]; then
      printf '%s\n' "$f"
      return
    fi
  done
}

wait_blocked() { # wait_blocked <name>: until its registry says it waits on a permission prompt
  local f
  for _ in $(seq 1 90); do
    f=$(registry_of "$1")
    if [ -n "$f" ] && [ "$(jq -r '.waitingFor // empty' "$f")" = "permission prompt" ]; then return 0; fi
    sleep 1
  done
  echo "session $1 never blocked on a prompt"
  exit 1
}

ask_for() { # ask_for <name> <command>: makes the session run <command>, which stops at a permission prompt
  t send-keys -t "live:$1" -l "Use the Bash tool to run exactly this command and nothing else, with no commentary: $2"
  sleep 1
  t send-keys -t "live:$1" Enter
  wait_blocked "$1"
}

inspect() { # inspect [args...]: runs prompt.sh as the holder; sets $out and $status
  set +e
  out=$(cd "$repo" && env TMUX="$tmux_env" CLAUDE_PID="$lead_pid" CLAUDE_CODE_SESSION_ID="$lead_sid" "$prompt_sh" "$@" 2>&1)
  status=$?
  set -e
}
contains() { case $out in *"$1"*) return 0 ;; *) return 1 ;; esac; }
screen_of() { t capture-pane -p -t "live:$1"; }
still_blocked() {
  local f
  f=$(registry_of "$1")
  [ -n "$f" ] && [ "$(jq -r '.waitingFor // empty' "$f")" = "permission prompt" ]
}
check_old_answers() {
  local target=$1 marker=${2:-} answer
  for answer in yes no; do
    inspect "$target" "$answer" 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    check "$target: the old $answer form tells the user to open the pane" \
      eval '[ "$status" -eq 2 ] && contains "inspection-only" && contains "directly in the session"'
    check "$target: the old $answer form leaves the prompt open" still_blocked "$target"
  done
  if [ -n "$marker" ]; then check "$target: its command did not run" [ ! -e "$repo/$marker" ]; fi
}

# A window keeps the server alive for the whole run.
t -f /dev/null new-session -d -s live -n idle -x 130 -y 50 "sleep 3600"
tmux_env="$(t display-message -p -t live '#{socket_path},#{pid},0')"

start_session live-lead
lead_reg=$(registry_of live-lead)
lead_pid=$(jq -r .pid "$lead_reg")
lead_sid=$(jq -r .sessionId "$lead_reg")
(cd "$repo" && env CLAUDE_PID="$lead_pid" CLAUDE_CODE_SESSION_ID="$lead_sid" "$scripts/claim.sh" >/dev/null)
# shellcheck source=SCRIPTDIR/../skills/anderton/scripts/session-lib.sh
holder_record=$(. "$scripts/session-lib.sh"; holder_path "$(project_root "$repo")")

start_session live-a
start_session live-b

ask_for live-a 'touch marker-a'
inspect live-a
check "reading names the session and shows the prompt's exact text" eval 'contains "Session: live-a" && contains "touch marker-a"'
check "the visible prompt remains open" eval 'screen_of live-a | grep -qF "touch marker-a"'
check_old_answers live-a marker-a

set +e
out=$(cd "$repo" && env TMUX="$tmux_env" CLAUDE_PID="$(jq -r .pid "$(registry_of live-b)")" CLAUDE_CODE_SESSION_ID="$(jq -r .sessionId "$(registry_of live-b)")" "$prompt_sh" live-a 2>&1)
status=$?
set -e
check "a session holding no role is refused inspection" [ "$status" -eq 3 ]
inspect live-b
check "a session that isn't blocked is refused" eval '[ "$status" -eq 3 ] && contains "not blocked"'

t send-keys -t live:live-a Down
sleep 1
inspect live-a
check "a wider option can be inspected without selecting it" eval '[ "$status" -eq 0 ] && contains "❯ 2."'
check "the command is still waiting in its own pane" still_blocked live-a

ask_for live-b 'touch marker-b'
inspect live-b
check "the second pane's prompt reads its own text" eval 'contains "touch marker-b" && ! contains "touch marker-a"'
check_old_answers live-b marker-b
check "the first pane is still waiting" still_blocked live-a

# The visible pane lacks the first lines. The native transcript supplies the full Bash command.
start_session live-tall
t resize-window -t live:live-tall -x 40 -y 16
sleep 1
ask_for live-tall "touch $(seq -f 'tall-marker-%02g' 1 40 | tr '\n' ' ')"
check "a tall dialog's first lines are off the screen" eval '! screen_of live-tall | grep -qF "tall-marker-01"'
inspect live-tall
check "it reads in full from the transcript" eval '[ "$status" -eq 0 ] && contains "tall-marker-01" && contains "tall-marker-40"'
check_old_answers live-tall tall-marker-01

# A permission rule or hook gives its reason between the command and the question.
start_session live-rule default --settings "$work/ask-settings.json"
t resize-window -t live:live-rule -x 40 -y 16
sleep 1
ask_for live-rule "touch $(seq -f 'rule-marker-%02g' 1 30 | tr '\n' ' ')"
inspect live-rule
check "a tall dialog with a permission rule's reason reads in full" eval '[ "$status" -eq 0 ] && contains "rule-marker-01" && contains "rule-marker-30" && contains "Permission rule"'
check_old_answers live-rule rule-marker-01

start_session live-hook bypassPermissions --settings "$work/hook-settings.json"
t resize-window -t live:live-hook -x 40 -y 16
sleep 1
ask_for live-hook "touch $(seq -f 'hook-marker-%02g' 1 30 | tr '\n' ' ')"
inspect live-hook
check "a tall dialog with a hook's reason reads in full" eval '[ "$status" -eq 0 ] && contains "hook-marker-01" && contains "hook-marker-30" && contains "live test"'
check_old_answers live-hook hook-marker-01

# A sub-agent asks through the session's screen, and its command is in its own transcript.
start_session live-sub
t resize-window -t live:live-sub -x 40 -y 16
sleep 1
t send-keys -t live:live-sub -l "Use the Agent tool once, with subagent_type general-purpose. Tell it to run exactly this Bash command and nothing else, with no commentary: touch $(seq -f 'sub-marker-%02g' 1 30 | tr '\n' ' ')"
sleep 1
t send-keys -t live:live-sub Enter
wait_blocked live-sub
sleep 2
inspect live-sub
check "a sub-agent's tall dialog reads in full" eval '[ "$status" -eq 0 ] && contains "sub-marker-01" && contains "sub-marker-30"'
check_old_answers live-sub sub-marker-01

# A real herdr tab, when this runs inside herdr.
if [ -n "${HERDR_SOCKET_PATH:-}" ] && [ -n "${HERDR_WORKSPACE_ID:-}" ] && [ -z "${LIVE_TMUX_ONLY:-}" ]; then
  created=$(herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$repo" --label live-h --no-focus)
  herdr_tabs=$(printf '%s' "$created" | jq -r '.result.tab.tab_id')
  herdr agent start live-h --kind claude --pane "$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id')" \
    --timeout 120000 -- -n live-h --permission-mode default --model haiku >/dev/null
  herdr agent prompt live-h "Use the Bash tool to run exactly this command and nothing else, with no commentary: touch marker-herdr" >/dev/null
  wait_blocked live-h
  inspect live-h
  check "herdr: reading shows the prompt" contains "touch marker-herdr"
  check_old_answers live-h marker-herdr
  created=$(herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$repo" --label live-hr --no-focus)
  herdr_tabs="$herdr_tabs $(printf '%s' "$created" | jq -r '.result.tab.tab_id')"
  herdr agent start live-hr --kind claude --pane "$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id')" \
    --timeout 120000 -- -n live-hr --permission-mode default --model haiku --settings "$work/ask-settings.json" >/dev/null
  herdr agent prompt live-hr "Use the Bash tool once to run one single command: ./node_modules/.bin/vitest run followed by 90 test file arguments, tests/file-1.test.ts through tests/file-90.test.ts, one per line with backslash continuations, no loop and no commentary." >/dev/null
  wait_blocked live-hr
  sleep 2
  inspect live-hr
  check "herdr: a tall vitest command stopped by a rule reads in full" eval '[ "$status" -eq 0 ] && contains "vitest run" && contains "tests/file-1.test.ts" && contains "tests/file-90.test.ts"'
  check "herdr: and shows the rule's reason" contains "Permission rule"
  check_old_answers live-hr
fi

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed"; exit 1; }
echo "all live checks passed"
