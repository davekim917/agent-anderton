#!/usr/bin/env bash
# Start a full worker in its own worktree of the caller's repository, in a herdr tab or tmux window.
# $ANDERTON_START_WAIT (seconds, default 30) bounds the wait for a tmux worker to register.
# Claude workers run on Opus unless --model supplies another model. Codex and agy workers use their configured model.
# agy workers start only inside herdr, through the sandbox launcher install-agy.sh put under $ANDERTON_AGY_ROOT
# (default /opt/agy); Linux only.
# Worktrees go under $ANDERTON_WORKTREES, default the folder that holds the repository, as wt-<name>.
# Portable to macOS's bash 3.2 and BSD userland.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

require_tools spawn.sh
usage="usage: spawn.sh --effort low|medium|high|xhigh|max [--provider claude|codex|agy] [--model M] [--mode MODE] [--base REF] <name: a-z 0-9 -> [brief-file]"
model="" effort="" mode="" base="" provider="" codex_home="" launched_at="" launch_token="" claude_launch=""
while [ $# -gt 0 ]; do
  case $1 in
    --bg) echo "spawn.sh: --bg is unsupported. Start workers inside herdr or tmux." >&2; exit 2 ;;
    --model | --effort | --mode | --base | --provider)
      [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }
      case $1 in
        --model) model=$2 ;;
        --effort) effort=$2 ;;
        --mode) mode=$2 ;;
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
if [ -z "$provider" ]; then
  if [ -n "$main" ]; then
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
if [ "$provider" = agy ]; then
  if [ "$launcher" != herdr ]; then
    echo "agy workers start only inside herdr, whose agy kind runs the sandbox launcher." >&2
    exit 2
  fi
  if [ -n "$mode" ]; then
    echo "agy workers run in their sandbox without permission prompts. Omit --mode." >&2
    exit 2
  fi
  if [ "$effort" = max ]; then
    echo "agy's models stop at xhigh effort. Use low, medium, high or xhigh." >&2
    exit 2
  fi
  # Absolute, since the tab resolves its PATH from the worktree, not from here.
  agy_install=$(cd "$(agy_root)" 2>/dev/null && pwd -P) || agy_install=$(agy_root)
  # The launcher repeats these checks inside its sandbox and owns the refusal; here they give an early, plain error.
  if [ "$(uname -s)" != Linux ] || [ ! -x "$agy_install/bin/agy" ] || [ ! -f "$agy_install/etc/pin" ]; then
    echo "agy is not installed at $agy_install (Linux only). The operator installs it with install-agy.sh." >&2
    exit 1
  fi
  if [ "$(sha256sum "$HOME/.gemini/config/hooks.json" 2>/dev/null | cut -d' ' -f1)" != \
    "$(sed -n 's/^hooks_sha256=//p' "$agy_install/etc/pin" | head -n 1)" ]; then
    echo "$HOME/.gemini/config/hooks.json is not the guard registration install-agy.sh wrote; agy would run unguarded." >&2
    exit 1
  fi
  if [ ! -f "$HOME/.gemini/antigravity-cli/antigravity-oauth-token" ]; then
    echo "agy has no stored login, and without one it starts its own sign-in. The owner signs in first." >&2
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
if [ "$provider" = agy ] && ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  echo "agy workers need a Git worktree." >&2
  exit 2
fi
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
role_scope=""
if [ -n "$role" ]; then role_scope=$(jq -r '.scope // empty' "$role"); fi
if [ "$caller_provider" = codex ]; then
  me=$(claim_name "${role:-/dev/null}")
else
  me=$(jq -r '.name // empty' "$sessions/$pid.json" 2>/dev/null || true)
fi
if [ -z "$me" ]; then
  echo "This session has no name for the worker to report to. Name it with /rename, then rerun." >&2
  exit 1
fi

if [ -z "$role" ] && { [ "$provider" != claude ] || [ "$caller_provider" = codex ]; }; then
  echo "Only the Anderton holding this repository or project can start this worker." >&2
  exit 1
fi

# A peer in another permission mode holds this session's messages for its user's approval, so the worker
# runs in this session's mode, which its transcript records on each prompt.
if [ "$provider" = claude ] && [ -z "$mode" ] && [ "$caller_provider" = codex ]; then
  mode=default
elif [ "$provider" = claude ] && [ -z "$mode" ]; then
  for t in "$home"/projects/*/"$sid".jsonl; do
    [ -e "$t" ] || continue
    mode=$(tail -n 2000 "$t" | jq -r 'select(.permissionMode != null) | .permissionMode' 2>/dev/null | tail -n 1)
    break
  done
fi
if [ "$provider" = claude ] && [ "$caller_provider" = codex ]; then
  case $mode in
    default | acceptEdits | plan) ;;
    *) echo "Claude workers under Codex use default, acceptEdits, or plan permission mode." >&2; exit 2 ;;
  esac
fi
if [ "$provider" = claude ] && [ -z "$mode" ]; then
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
agy_pid="" agy_start="" agy_instance="" agy_common="" agy_launch="${record%.json}.agy-launch"
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
if [ "$provider" != claude ] || [ "$caller_provider" = codex ]; then
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
    --arg spawner_scope "$role_scope" --arg role "$role" --arg claude_launch "$claude_launch" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg provider "$provider" --arg codex "$codex_home" --arg launched "$launched_at" --arg token "$launch_token" \
    --arg agy_pid "$agy_pid" --arg agy_start "$agy_start" --arg agy_instance "$agy_instance" --arg agy_common "$agy_common" \
    --slurpfile previous "$record" '
      ($previous[0] // {}) + {name: $name, launcher: $launcher, id: ($previous[0].id // $id), tab: $tab, socket: $socket, server: $server, dir: $dir, root: $root,
      base: $base, worktree: $worktree, spawner: $spawner, spawnerSession: $spawner_session, label: $label, startedAt: ($previous[0].startedAt // $at)}
      + if $pane != "" then {pane: $pane} else {} end
      + if $role != "" then {spawnerProvider: $spawner_provider, spawnerScope: (if $spawner_scope == "" then null else $spawner_scope end)} else {} end
      + if $provider == "claude" then {claudeLaunchId: $claude_launch} else {} end
      + if $provider == "claude" and $spawner_provider == "codex" then {reportTransport: "transcript"} else {} end
      + if $provider == "codex" then {provider: $provider, codexHome: $codex, codexLaunchedAt: ($launched | tonumber), codexLaunchToken: $token} else {} end
      + if $provider == "agy" then {provider: $provider}
          + (if $agy_common != "" then {agyCommon: $agy_common} else {} end)
          + if $agy_pid != "" then {agyPid: ($agy_pid | tonumber), agyProcStart: $agy_start, agyInstance: $agy_instance} else {} end
        else {} end' > "$updated" || return 1
  mv -f "$updated" "$record"
}

failed() {
  [ -z "${1:-}" ] || echo "$1" >&2
  local work=""
  if [ "$worktree" = true ]; then
    if [ "$provider" = agy ]; then
      # An agy that ran in the worktree, however briefly, could have written there: it is inspected only inside the
      # launcher's read-only sandbox, removed only while it points into its repository and nothing has a directory
      # in it, and with --force, so host git reads nothing in it.
      if ! agy_git_pointer_ok "$record"; then
        work="its .git no longer points into $root"
      elif ! worktree_unused "$dir"; then
        work="a process still has its directory there"
      else
        work=$(agy_worktree_work "$record")
      fi
      [ -n "$work" ] || git -C "$root" worktree remove --force "$dir" || work="git could not remove it"
    else
      work=$(worktree_work "$dir" "$base")
      [ -n "$work" ] || git -C "$root" worktree remove "$dir" || work="git could not remove it"
    fi
  fi
  if [ -n "$work" ]; then
    write_record
    echo "Kept $dir and its worker record because Git could not safely remove it ($work)." >&2
    exit 1
  fi
  rm -f "$record" "$agy_launch"
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
  if [ -n "$model" ]; then set -- "$@" -m "$model"; fi
elif [ "$provider" = agy ]; then
  provider_name=agy
  # herdr runs its agy kind by name, so the launcher's directory goes first on the tab's PATH.
  config_env="PATH=$agy_install/bin:$PATH"
  agy_bwrap=$(sed -n 's/^bwrap=//p' "$agy_install/etc/pin" | head -n 1)
  agy_common=$(cd "$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)
  mode="bwrap sandbox, no permission prompts"
  rm -f "$agy_launch"
  set -- --anderton-launch-file "$agy_launch" --effort "$effort"
  if [ -n "$model" ]; then set -- "$@" --model "$model"; fi
else
  set -- -n "$name" --permission-mode "$mode" --effort "$effort" --model "${model:-opus}" --session-id "$claude_launch"
  if [ "$caller_provider" = codex ]; then
    set -- "$@" --plugin-dir "$(cd "$anderton_scripts/../../.." && pwd)"
  fi
fi
# The launcher writes its pid to $agy_launch just before it becomes bwrap, and agent start has waited for agy to be
# ready, so a missing or foreign pid means something other than the launcher answered to "agy" on the tab's PATH.
agy_launch_verified() {
  local launched="" tries=20 snapshot kind
  while [ "$tries" -gt 0 ]; do
    launched=$(cat "$agy_launch" 2>/dev/null) || launched=""
    case $launched in '' | *[!0-9]*) ;; *) break ;; esac
    tries=$((tries - 1))
    sleep 0.25
  done
  case $launched in
    '' | *[!0-9]*)
      out="the agy that started is not the sandbox launcher at $agy_install/bin/agy."
      return 1
      ;;
  esac
  agy_start=$(proc_start "$launched")
  if [ -z "$agy_start" ] || [ "$(readlink "/proc/$launched/cwd" 2>/dev/null)" != "$dir" ] ||
    ! agy_sandbox_proven "$launched" "$agy_bwrap" "$pane"; then
    out="process $launched, which the launcher recorded, is not the pinned bwrap ($agy_bwrap) sandboxing $dir from herdr pane $pane."
    return 1
  fi
  # The agent herdr now shows in the pane must be agy: the sandbox proof says what started, not what will read the
  # brief. Its instance is what later scripts must still see before they act on it.
  snapshot=$(herdr agent get "$pane" 2>/dev/null) || snapshot=""
  kind=$(printf '%s' "$snapshot" | jq -r '(.result.agent // .result).agent // empty' 2>/dev/null) || kind=""
  if [ "$kind" != agy ]; then
    out="herdr reports ${kind:-no agent} in pane $pane, not agy, so the brief is not sent."
    return 1
  fi
  agy_instance=$(printf '%s' "$snapshot" | jq -r '(.result.agent // .result).agent_session.value // empty' 2>/dev/null) || agy_instance=""
  # Without it, nothing later could tell this agy from another one opened in the same pane and worktree.
  if [ -z "$agy_instance" ]; then
    out="herdr reports no agent session for the agy in pane $pane, so later directions could not be bound to it."
    return 1
  fi
  agy_pid=$launched
  write_record
}

# One start of agy in the pane, then its proof. 75 when herdr's start failed and the launcher wrote that it set up no
# sandbox, so nothing ran in the pane and the start may be tried again (agy_until_started); never after anything ran.
agy_start_attempt() {
  if [ "$(cat "$agy_launch" 2>/dev/null)" = unstarted ]; then rm -f "$agy_launch"; fi
  if ! out=$(herdr agent start "$name" --kind "$provider" --pane "$pane" --timeout 120000 -- "$@" 2>&1); then
    if [ "$(cat "$agy_launch" 2>/dev/null)" = unstarted ]; then
      out="the sandbox could not be set up (a path it masks changed as it started), so agy did not start."
      return 75
    fi
    return 1
  fi
  agy_launch_verified
}

# True once the pane is gone and any launcher process this launch recorded has exited, waiting up to 5 seconds.
agy_launch_undone() {
  local launched answer _
  launched=$(cat "$agy_launch" 2>/dev/null) || launched=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    # herdr exits non-zero for a missing pane, which pipefail would read as a failed check.
    answer=$(herdr pane get "$pane" 2>&1) || true
    if printf '%s' "$answer" | jq -e '.error.code == "pane_not_found"' >/dev/null 2>&1 &&
      { [ -z "$launched" ] || [ -z "$(proc_start "$launched")" ]; }; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

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
  if [ "$provider" = agy ]; then
    if agy_until_started agy_start_attempt "$@"; then started=0; else started=1; fi
  elif out=$(herdr agent start "$name" --kind "$provider" --pane "$pane" --timeout 120000 -- "$@" 2>&1); then
    started=0
  else
    started=1
  fi
  if [ "$started" -ne 0 ] || ! out=$(herdr agent prompt "$pane" "$brief" 2>&1); then
    screen=$(herdr agent read "$pane" 2>/dev/null | tail -n 20 || true)
    if [ "$provider" = agy ]; then
      herdr pane close "$pane" >/dev/null 2>&1 || true
      if ! agy_launch_undone; then
        echo "agy in herdr pane $pane did not take the brief: $out
$screen
It is not confirmed stopped, so $dir and its record are kept: close pane $pane, then run retire.sh $name." >&2
        exit 1
      fi
      failed "agy in herdr pane $pane did not take the brief: $out
$screen"
    fi
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
echo "Started worker '$name' in $where, in $dir ($mode). It reports to '$me'."
