#!/usr/bin/env bash
# Start a full worker in its own worktree of the caller's repository, in a herdr tab or tmux window.
# $ANDERTON_START_WAIT (seconds, default 30) bounds the wait for a tmux worker to register; $ANDERTON_AGY_READY_WAIT
# (half-seconds, default 60) the wait for an agy worker's prompt before its brief is sent.
# Claude workers run on Opus unless --model supplies another model. Codex and agy workers use their configured model.
# agy workers start only inside herdr, run the agy on PATH, and only while agy-hooks.sh check passes.
# Worktrees go under $ANDERTON_WORKTREES, default the folder that holds the repository, as wt-<name>.
# Portable to macOS's bash 3.2 and BSD userland.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

require_tools spawn.sh

# The settings file that would start a Claude session in bypassPermissions mode when no --permission-mode is given.
# Only user and managed settings can choose that mode. Server-managed settings and MDM profiles are not read here.
claude_bypass_settings() {
  local managed f
  managed=${ANDERTON_CLAUDE_MANAGED_DIR:-}
  if [ -z "$managed" ]; then
    case $(uname -s) in
      Darwin) managed="/Library/Application Support/ClaudeCode" ;;
      *) managed=/etc/claude-code ;;
    esac
  fi
  for f in "$home/settings.json" "$managed/managed-settings.json" "$managed"/managed-settings.d/*.json; do
    [ -f "$f" ] || continue
    if jq -e '.permissions.defaultMode == "bypassPermissions"' "$f" >/dev/null 2>&1; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}
usage="usage: spawn.sh --effort low|medium|high|xhigh|max [--provider claude|codex|agy] [--model M] [--mode MODE] [--speed standard|fast|ultrafast] [--base REF] <name: a-z 0-9 -> [brief-file]"
model="" effort="" mode="" speed="" base="" provider="" codex_home="" launched_at="" launch_token="" claude_launch=""
while [ $# -gt 0 ]; do
  case $1 in
    --bg) echo "spawn.sh: --bg is unsupported. Start workers inside herdr or tmux." >&2; exit 2 ;;
    --model | --effort | --mode | --speed | --base | --provider)
      [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }
      case $1 in
        --model) model=$2 ;;
        --effort) effort=$2 ;;
        --mode) mode=$2 ;;
        --speed)
          case $2 in
            standard | fast | ultrafast) speed=$2 ;;
            *) echo "$usage" >&2; exit 2 ;;
          esac
          ;;
        --base) base=$2 ;;
        --provider)
          case $2 in
            claude | codex | agy) provider=$2 ;;
            *) echo "$usage" >&2; exit 2 ;;
          esac
          ;;
      esac
      shift 2
      ;;
    -*) echo "$usage" >&2; exit 2 ;;
    *) break ;;
  esac
done
name="${1:-}"
case $name in
  '' | -* | *[!a-z0-9-]*) echo "$usage" >&2; exit 2 ;;
esac
# Required so a worker never runs at the default just because nobody chose: the user's level, else the caller's
# judgment of the work.
case $effort in
  low | medium | high | xhigh | max) ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_WORKSPACE_ID:-}" ] && [ -n "${HERDR_SOCKET_PATH:-}" ] &&
  command -v herdr >/dev/null 2>&1; then
  launcher=herdr
  # herdr refuses an agent name that does not start with a letter or is over 32 characters.
  case $name in
    [a-z]*) [ ${#name} -le 32 ] || { echo "spawn.sh: inside herdr a worker name is at most 32 characters." >&2; exit 2; } ;;
    *) echo "spawn.sh: inside herdr a worker name starts with a letter." >&2; exit 2 ;;
  esac
elif [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
  launcher=tmux
else
  echo "spawn.sh: Start workers inside herdr or tmux." >&2
  exit 2
fi

root=$(invoking_root)
caller_provider=$(invoking_provider)
role=$(caller_claim "$root")
main=$(holder_record "$root")
# An Anderton's workers run on its own runtime unless --provider names another. A Codex caller's claim names the
# caller's own home (caller_matches_claim), which the Codex setup below resolves.
if [ -z "$provider" ]; then
  if [ -n "$role" ]; then
    provider=$caller_provider
  elif [ -n "$main" ]; then
    provider=$(record_provider "$main")
    if [ "$provider" = codex ]; then
      codex_home=$(jq -er '.codexHome | select(type == "string" and length > 0)' "$main") || {
        echo "The repository's Codex Anderton has no registered daemon home." >&2
        exit 1
      }
    fi
  else
    provider=claude
  fi
fi
case $provider in
  claude | codex | agy) ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
if [ "$provider" != codex ] && [ -n "$speed" ]; then
  echo "Only Codex workers support --speed. Omit --speed for $provider workers." >&2
  exit 2
fi
if [ "$provider" = agy ]; then
  if [ "$launcher" != herdr ]; then
    echo "agy workers start only inside herdr, whose pane carries their status and directions." >&2
    exit 2
  fi
  # herdr's agy kind runs agy by name, from the same PATH.
  if ! command -v agy >/dev/null 2>&1; then
    echo "spawn.sh needs the agy CLI on PATH for an agy worker." >&2
    exit 1
  fi
  if ! out=$("$anderton_scripts/agy-hooks.sh" check 2>&1); then
    echo "$out
agy would run unguarded, so no agy worker was started." >&2
    exit 1
  fi
fi
if [ "$provider" = claude ] && ! command -v claude >/dev/null 2>&1; then
  echo "spawn.sh needs the claude CLI on PATH for a Claude worker." >&2
  exit 1
fi
if [ "$provider" = codex ] && [ -n "$mode" ]; then
  echo "Codex workers use their own approval policy. Omit --mode." >&2
  exit 2
fi
if [ -n "${2:-}" ]; then brief=$(cat "$2"); else brief=$(cat); fi
if [ "$provider" = codex ]; then
  if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    echo "Codex workers need a Git worktree." >&2
    exit 2
  fi
  if ! command -v codex >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo "Codex workers need the codex CLI, its running local daemon, and python3." >&2
    exit 2
  fi
  base_home=$(cd "${codex_home:-${CODEX_HOME:-$HOME/.codex}}" && pwd -P)
  codex_home=$(codex_start_home "$base_home")
  if codex_accounts >/dev/null && ! codex_daemon_up "$codex_home"; then
    echo "Could not start the Codex daemon of $codex_home, the account new Codex sessions start on." >&2
    exit 2
  fi
  if [ ! -S "$(codex_socket "$codex_home")" ]; then
    echo "Start the local Codex daemon before launching a Codex worker." >&2
    exit 2
  fi
fi
if [ -z "$(printf '%s' "$brief" | tr -d '[:space:]')" ]; then
  echo "spawn.sh: the brief is empty." >&2
  exit 2
fi
if [ "$provider" = claude ]; then
  if command -v uuidgen >/dev/null 2>&1; then
    claude_launch=$(uuidgen | tr '[:upper:]' '[:lower:]')
  elif command -v python3 >/dev/null 2>&1; then
    claude_launch=$(python3 -c 'import uuid; print(uuid.uuid4())')
  else
    echo "spawn.sh needs uuidgen or python3 to assign a Claude session ID." >&2
    exit 2
  fi
fi

sid=$(invoking_session)
pid=$(invoking_pid)
role_scope="" role_claim=""
if [ -n "$role" ]; then
  role_scope=$(jq -r '.scope // empty' "$role")
  role_claim=$(jq -r '.claimId // empty' "$role")
fi
if [ "$caller_provider" != claude ]; then
  me=$(claim_name "${role:-/dev/null}")
else
  me=$(jq -r '.name // empty' "$sessions/$pid.json" 2>/dev/null || true)
fi
if [ -z "$me" ]; then
  echo "This session has no name for the worker to report to. Name it with /rename, then rerun." >&2
  exit 1
fi

if [ -z "$role" ] && { [ "$provider" != claude ] || [ "$caller_provider" != claude ]; }; then
  echo "Only the Anderton holding this repository or project can start this worker." >&2
  exit 1
fi

# A peer in another permission mode holds this session's messages for its user's approval, so a Claude Anderton's
# worker runs in that session's mode, which its transcript records on each prompt. A Codex or agy Anderton directs
# its Claude workers through their Stop hook and pane, not those messages: they start in the mode Claude itself
# picks from its settings, unless that could be bypassPermissions, which only --mode may choose.
if [ "$provider" = claude ] && [ -z "$mode" ] && [ "$caller_provider" != claude ]; then
  if configured=$(claude_bypass_settings); then
    echo "$configured sets Claude's default permission mode to bypassPermissions. Pass --mode bypassPermissions to start this worker so, or --mode with another mode." >&2
    exit 2
  fi
elif [ "$provider" = claude ] && [ -z "$mode" ]; then
  for t in "$home"/projects/*/"$sid".jsonl; do
    [ -e "$t" ] || continue
    mode=$(tail -n 2000 "$t" | jq -r 'select(.permissionMode != null) | .permissionMode' 2>/dev/null | tail -n 1)
    break
  done
fi
if [ "$provider" = claude ] && [ -z "$mode" ] && [ "$caller_provider" = claude ]; then
  echo "Cannot read this session's permission mode from its transcript; pass --mode." >&2
  exit 1
fi

mkdir -p "$holders/workers"
record="$holders/workers/$name.json"
# Creating the record exclusively reserves the name, so two spawns of one name cannot both pass the checks below.
if ! (set -C && : > "$record") 2>/dev/null; then
  echo "A worker named '$name' was started before and not retired: run retire.sh $name first." >&2
  exit 1
fi
reserved=1
trap '[ -z "$reserved" ] || rm -f "$record"' EXIT
agy_instance="" agy_config="${record%.json}.agy-config"
if command -v claude >/dev/null 2>&1 &&
  claude agents --json 2>/dev/null | jq -e --arg n "$name" 'any(.[]; .name == $n)' >/dev/null; then
  echo "A live session is already named '$name'; pick another name." >&2
  exit 1
fi

dir=$root
worktree=false
if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  if [ -z "$base" ]; then
    for ref in "$(git -C "$root" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)" origin/main origin/master HEAD; do
      if [ -n "$ref" ] && git -C "$root" rev-parse -q --verify "$ref^{commit}" >/dev/null; then
        base=$ref
        break
      fi
    done
  fi
  case $base in origin/*) git -C "$root" fetch -q origin 2>/dev/null || echo "spawn.sh: could not fetch origin; starting from the cached $base." >&2 ;; esac
  parent="${ANDERTON_WORKTREES:-$(dirname "$root")}"
  mkdir -p "$parent"
  parent=$(cd "$parent" && pwd -P)
  dir="$parent/wt-$name"
  if [ -e "$dir" ]; then
    echo "$dir already exists; pick another name." >&2
    exit 1
  fi
  git -C "$root" worktree add -q --detach "$dir" "$base"
  worktree=true
  base=$(git -C "$dir" rev-parse HEAD)
fi

report_instructions="- Message \"$me\" by SendMessage"
report_footer="  Never send acknowledgements, \"still waiting\" or \"holding\", restated instructions, or FYIs that change nothing: each message wakes \"$me\" and re-reads its whole context. A hook holds any message to \"$me\" without one of those four kinds, or one that repeats your last. Nobody reads this session, so a question left only in your reply is never answered."
if [ "$provider" != claude ] || [ "$caller_provider" != claude ]; then
  report_instructions="- Put each milestone in your final reply. Anderton reads those replies"
  report_footer="  Skip acknowledgements, \"still waiting\" or \"holding\", restated instructions, and repeated reports. Each report wakes \"$me\"."
fi
brief="$brief

---
You are a worker the Anderton session \"$me\" started for the task above, in $dir.
$report_instructions only when it changes what they do, one message per milestone, the kind as its first word:
  RESULT: a milestone done (PR ready, task finished), with its link and what you verified.
  QUESTION: a decision you need, with your recommendation.
  BLOCKED: what stops you and what would unblock it.
  ANSWER: a reply to something \"$me\" asked you.
$report_footer
- Give every sub-agent you start an explicit effort that fits its task (low for lookups and mechanical edits). Prefer a one-shot sub-agent that returns its result over a named one you keep alive and message for days. /orchestrate, if installed, does both.
- Do not deploy, restart a service, or message anyone off this machine unless the task says to; \"$me\" owns those."

write_record() {
  if (write_launch_record); then reserved=""; else return 1; fi
}

write_launch_record() {
  local updated
  take_repository_lock "$root"
  lock_worker "$record" || return 1
  updated=$(mktemp "$record.XXXXXX")
  jq -nc --arg name "$name" --arg launcher "$launcher" --arg id "$id" --arg tab "$tab" --arg dir "$dir" --arg root "$root" \
    --arg socket "$socket" --arg server "$server" --arg base "$base" --arg spawner "$me" --arg label "$label" --argjson worktree "$worktree" \
    --arg pane "$pane" --arg spawner_session "$sid" --arg spawner_provider "$caller_provider" \
    --arg spawner_scope "$role_scope" --arg spawner_claim "$role_claim" --arg role "$role" --arg claude_launch "$claude_launch" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg provider "$provider" --arg codex "$codex_home" --arg launched "$launched_at" --arg token "$launch_token" \
    --arg agy_instance "$agy_instance" \
    --slurpfile previous "$record" '
      ($previous[0] // {}) + {name: $name, launcher: $launcher, id: ($previous[0].id // $id), tab: $tab, socket: $socket, server: $server, dir: $dir, root: $root,
      base: $base, worktree: $worktree, spawner: $spawner, spawnerSession: $spawner_session, label: $label, startedAt: ($previous[0].startedAt // $at)}
      + if $pane != "" then {pane: $pane} else {} end
      + if $role != "" then {spawnerProvider: $spawner_provider, spawnerScope: (if $spawner_scope == "" then null else $spawner_scope end)}
          + (if $spawner_claim != "" then {spawnerClaimId: $spawner_claim} else {} end) else {} end
      + if $provider == "claude" then {claudeLaunchId: $claude_launch} else {} end
      + if $provider == "claude" and $spawner_provider != "claude" then {reportTransport: "transcript"} else {} end
      + if $provider == "codex" then {provider: $provider, codexHome: $codex, codexLaunchedAt: ($launched | tonumber), codexLaunchToken: $token} else {} end
      + if $provider == "agy" then {provider: $provider} + if $agy_instance != "" then {agyInstance: $agy_instance} else {} end
        else {} end' > "$updated" || return 1
  mv -f "$updated" "$record"
}

failed() {
  [ -z "${1:-}" ] || echo "$1" >&2
  local work=""
  if [ "$worktree" = true ]; then
    work=$(worktree_work "$dir" "$base")
    [ -n "$work" ] || git -C "$root" worktree remove "$dir" || work="git could not remove it"
  fi
  if [ -n "$work" ]; then
    write_record
    echo "Kept $dir and its worker record because Git could not safely remove it ($work)." >&2
    exit 1
  fi
  rm -f "$record" "$agy_config"
  exit 1
}

# A named project's Anderton puts its own name on its workers' tabs, so the user can tell whose they are. herdr and
# tmux report a label as one whitespace-free field, so the name is folded to a-z, 0-9 and hyphens.
label=$name
if [ -n "$role_scope" ]; then
  label="$(printf '%s' "$me" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-*//; s/-*$//')/$name"
fi

config_env="CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-}"
provider_name="Claude Code"
id="" tab="" pane="" socket="" server=""
if [ "$provider" = codex ]; then
  provider_name=Codex
  codex_worker="$(dirname "$0")/codex-worker.py"
  # The worker's thread is the one created in its worktree since now; older ones there belong to an earlier worker.
  launched_at=$(date +%s)
  launch_token=$(python3 -c 'import uuid; print(uuid.uuid4())') || failed "Could not create the Codex launch token."
  brief="Anderton launch $launch_token

$brief"
  config_env="CODEX_HOME=$codex_home"
  mode="workspace-write, user approvals"
  # The thread id as the tab's title is how retire.sh tells that the tab still shows this worker's conversation.
  set -- --remote "unix://$(codex_socket "$codex_home")" \
    --sandbox workspace-write -a on-request -c 'approvals_reviewer="user"' -c "model_reasoning_effort=\"$effort\"" \
    -c 'tui.terminal_title=["thread-id"]'
  case $speed in
    fast | ultrafast) set -- "$@" -c "service_tier=\"$speed\"" ;;
  esac
  if [ -n "$model" ]; then set -- "$@" -m "$model"; fi
elif [ "$provider" = agy ]; then
  provider_name=agy
  # agy's prompting mode would stop on routine commands, as a Claude worker in auto mode does not: the guard, which sees
  # every tool call, is the gate. --mode names one of agy's own modes instead.
  if [ -n "$mode" ]; then
    set -- --mode "$mode"
  else
    mode="no permission prompts; the guard gates every tool call"
    set -- --dangerously-skip-permissions
  fi
  # An agy model id names its effort (gemini-4-neon-low), and agy rejects --effort beside one.
  if [ -n "$model" ]; then set -- "$@" --model "$model"; else set -- "$@" --effort "$effort"; fi
  # The worktree spawn.sh just made is trusted for this session alone (agy_session_settings).
  agy_settings=$(agy_session_settings "$dir") || failed "$agy_settings"
  set -- "$@" --settings "$agy_settings"
  out=$("$anderton_scripts/agy-hooks.sh" check --workspace "$dir" 2>&1) || failed "$out
agy would run unguarded, so no agy worker was started."
else
  set -- -n "$name"
  if [ -n "$mode" ]; then set -- "$@" --permission-mode "$mode"; else mode="Claude's configured default permission mode"; fi
  set -- "$@" --effort "$effort" --model "${model:-opus}" --session-id "$claude_launch"
  if [ "$caller_provider" != claude ]; then
    set -- "$@" --plugin-dir "$(cd "$anderton_scripts/../../.." && pwd)"
  fi
fi
# A tab or window id is unique only within its server, so the record keeps which server it was opened in.
write_record
if [ "$launcher" = herdr ]; then
  socket="${HERDR_SOCKET_PATH:-}"
  # A tab's or window's process takes its environment from its multiplexer, not from this script: a non-default
  # Claude home is passed on, or the worker would register where neither the caller nor these scripts look.
  if [ -n "${config_env#*=}" ]; then
    out=$(herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$dir" --label "$label" --no-focus \
      --env "$config_env" 2>&1) || failed "Could not open a herdr tab: $out"
  else
    out=$(herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$dir" --label "$label" --no-focus 2>&1) ||
      failed "Could not open a herdr tab: $out"
  fi
  tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null || true)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null || true)
  if [ -z "$tab" ] || [ -z "$pane" ]; then failed "herdr opened no tab: $out"; fi
  # Recorded as soon as the tab exists, so a spawn cut short still leaves retire.sh something to stop.
  write_record
  # A startup prompt (folder trust, a new permission mode) leaves the agent blocked: show it, then undo.
  # The brief goes to the pane, whose id herdr never reuses, not to the name, which the user can rename and reuse.
  # What agy loads hooks and agents from, as it stands when agy starts: waiting.sh reports any change from it.
  if [ "$provider" = agy ]; then
    agy_config_state "$dir" > "$agy_config" || failed "Could not read what agy loads hooks from."
  fi
  if out=$(herdr agent start "$name" --kind "$provider" --pane "$pane" --timeout 120000 -- "$@" 2>&1); then
    started=0
  else
    started=1
  fi
  # herdr reports agy ready while agy still shows a screen only a person may answer: its terms (again after an update),
  # its sign-in, or anything else. The brief goes only once agy shows its prompt, whose footer is "? for shortcuts",
  # within $ANDERTON_AGY_READY_WAIT half-seconds (default 60).
  if [ "$provider" = agy ] && [ "$started" -eq 0 ]; then
    started=1 out="agy did not show its prompt: open its tab to see what it waits for."
    for _ in $(seq 1 "${ANDERTON_AGY_READY_WAIT:-60}"); do
      case $(herdr agent read "$pane" --source recent --lines 60 2>/dev/null || true) in
        *"Terms of Service"* | *"Data Use"*)
          out="agy is waiting for its terms screen: run agy once yourself and complete it."
          break
          ;;
        *"not signed in"* | *"Select login method"*)
          out="agy is not signed in: run agy once yourself and sign in."
          break
          ;;
        *"? for shortcuts"*)
          started=0
          break
          ;;
      esac
      sleep 0.5
    done
    # agy runs another model when it does not know the one named, and says so only in a warning it may draw after its
    # prompt, wrapped to the pane's width.
    if [ "$started" -eq 0 ] && [ -n "$model" ]; then
      sleep 1
      case $(herdr agent read "$pane" --source recent --lines 60 2>/dev/null | tr -s '[:space:]' ' ' || true) in
        *"is not recognized as a known model"*)
          started=1 out="agy does not know the model $model, so it would run another one: agy models lists the ids it knows." ;;
      esac
    fi
  fi
  if [ "$started" -ne 0 ] || ! out=$(herdr agent prompt "$pane" "$brief" 2>&1); then
    screen=$(herdr agent read "$pane" 2>/dev/null | tail -n 20 || true)
    if [ "$provider" = codex ]; then
      echo "Codex worker '$name' could not take the brief: $out
$screen
The tab and worktree were kept. Inspect the tab. If it received the launch brief, register it; otherwise close the tab, retire the worker and retry once the startup issue is resolved." >&2
      exit 1
    fi
    herdr tab close "$tab" >/dev/null 2>&1 || true
    if ! worker_gone herdr "$socket" "$tab" "$name" "" "$label"; then
      echo "$provider_name in herdr tab '$name' did not take the brief: $out
$screen
It is not confirmed stopped, so $dir and its record are kept: close tab $tab, then run retire.sh $name." >&2
      exit 1
    fi
    failed "$provider_name in herdr tab '$name' did not take the brief: $out
$screen"
  fi
  # herdr learns an agy's session from its first prompt, when herdr's antigravity-cli integration is installed. Once
  # recorded, later steps act only on that session; without it, on the agy herdr shows in this pane and worktree.
  if [ "$provider" = agy ]; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      agy_instance=$(herdr agent get "$pane" 2>/dev/null |
        jq -r '.result.agent | select(.agent == "agy") | .agent_session.value // empty' 2>/dev/null) || agy_instance=""
      [ -z "$agy_instance" ] || break
      sleep 0.5
    done
    write_record
    present=$(grep -v '	absent$' "$agy_config" | cut -f1 | grep -F "$dir/" || true)
    if [ -n "$present" ]; then
      echo "agy loads hooks, plugins or agents from this worktree as it started; the watch reports changes only from here:
$present" >&2
    fi
  fi
  where="herdr tab '$label' ($tab)"
else
  socket="${TMUX%%,*}"
  server=$(printf '%s' "$TMUX" | cut -d, -f2)
  # Given as separate arguments, the window's command runs without a shell, so the brief needs no quoting. tmux still
  # parses each argument: one ending in ";" ends the command unless written "\;", and -c expands formats, so "#" is "##".
  set -- "$provider" "$@" "$brief"
  [ -z "${config_env#*=}" ] || set -- -e "$config_env" "$@"
  for arg; do
    shift
    case $arg in *';') arg="${arg%;}\\;" ;; esac
    set -- "$@" "$arg"
  done
  out=$(tmux new-window -d -P -F '#{window_id} #{pane_id}' -n "$label" -c "$(printf '%s' "$dir" | sed 's/#/##/g')" "$@" 2>&1) ||
    failed "Could not open a tmux window: $out"
  tab=$(printf '%s\n' "$out" | awk '$1 ~ /^@[0-9]+$/ && $2 ~ /^%[0-9]+$/ { t = $1; p = $2 } END { if (t != "") print t, p }' || true)
  pane=${tab#* } tab=${tab%% *}
  [ -n "$tab" ] || failed "tmux opened no window: $out"
  write_record
  # The window closes when claude exits, so a worker that never registers and has no window failed to start.
  listed="" tries=$(( ${ANDERTON_START_WAIT:-30} * 2 ))
  while [ "$provider" = claude ] && [ "$tries" -gt 0 ]; do
    if claude agents --json 2>/dev/null | jq -e --arg sid "$claude_launch" 'any(.[]; .sessionId == $sid)' >/dev/null 2>&1; then
      listed=1
      break
    fi
    if [ "$(place_state tmux "$socket" "$tab" "$label" "$server")" = absent ]; then
      failed "Claude Code exited at once in tmux window '$name'."
    fi
    tries=$((tries - 1))
    sleep 0.5
  done
  where="tmux window '$label' ($tab)"
  [ "$provider" = codex ] || [ -n "$listed" ] ||
    echo "Worker '$name' has not registered yet: it may be waiting at a startup prompt in its window." >&2
fi

if [ "$provider" = codex ]; then
  tries=$(( ${ANDERTON_START_WAIT:-30} * 2 ))
  while [ "$tries" -gt 0 ]; do
    if id=$("$codex_worker" find "$codex_home" "$dir" --since "$launched_at" --token "$launch_token"); then
      break
    else
      status=$?
    fi
    if [ "$status" -ne 3 ] || [ "$(place_state "$launcher" "$socket" "$tab" "$label" "$server")" != present ]; then break; fi
    tries=$((tries - 1))
    sleep 0.5
  done
  if [ -z "$id" ]; then
    echo "Codex worker '$name' has no verified thread ID. Inspect $where for a startup prompt; the tab and worktree were kept." >&2
    exit 1
  fi
  take_repository_lock "$root"
  lock_worker "$record"
  bind_codex_worker "$record" "$id" "$launch_token"
fi
emit_event "$role_claim" "$role_scope" start "worker=$name"
echo "Started worker '$name' in $where, in $dir ($mode). It reports to '$me'."
