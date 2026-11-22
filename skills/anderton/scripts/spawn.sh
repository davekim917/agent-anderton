#!/usr/bin/env bash
# Start a full worker in its own worktree of the caller's repository. Herdr and tmux open interactive workers
# in a tab or window. Only Claude Code supports a background launch.
# --bg asks for the background outside herdr; inside herdr it is refused, except once after spawn.sh itself failed to
# start that name in a herdr tab and said to rerun with it. $ANDERTON_START_WAIT (seconds, default 30) bounds the wait for a tmux worker to register.
# Claude workers run on Opus unless --model supplies another model. Codex workers use their configured model.
# Worktrees go under $ANDERTON_WORKTREES, default the folder that holds the repository, as wt-<name>.
# Portable to macOS's bash 3.2 and BSD userland.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

require_tools spawn.sh
usage="usage: spawn.sh --effort low|medium|high|xhigh|max [--provider claude|codex] [--bg (not inside herdr)] [--model M] [--mode MODE] [--base REF] <name: a-z 0-9 -> [brief-file]"
model="" effort="" mode="" base="" launcher="" provider="" codex_home="" baseline="" launch_token=""
while [ $# -gt 0 ]; do
  case $1 in
    --bg) launcher="bg"; shift ;;
    --model | --effort | --mode | --base | --provider)
      [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }
      case $1 in
        --model) model=$2 ;;
        --effort) effort=$2 ;;
        --mode) mode=$2 ;;
        --base) base=$2 ;;
        --provider) provider=$2 ;;
      esac
      shift 2
      ;;
    -*) echo "$usage" >&2; exit 2 ;;
    *) break ;;
  esac
done
root=$(invoking_root)
caller_provider=$(invoking_provider)
role=$(caller_claim "$root")
main=$(holder_record "$root")
if [ -z "$provider" ]; then
  if [ -n "$main" ]; then provider=$(record_provider "$main"); else provider=claude; fi
fi
case $provider in
  claude | codex) ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
if [ "$provider" = claude ] && ! command -v claude >/dev/null 2>&1; then
  echo "spawn.sh needs the claude CLI on PATH for a Claude worker." >&2
  exit 1
fi
if [ "$provider" = codex ] && { [ "$launcher" = bg ] || [ -n "$mode" ]; }; then
  echo "Codex workers need a herdr tab or tmux window and use their own approval policy." >&2
  exit 2
fi
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
if [ -n "${2:-}" ]; then brief=$(cat "$2"); else brief=$(cat); fi
# The user watches and types into every worker through its tab, so inside herdr a caller cannot hide one by choice:
# --bg there is admitted only by the marker a failed herdr start of the same name leaves, and only once.
herdr_failed="$holders/workers/$name.herdr-failed"
# Resolved once, so the marker's project and the worker's are the same one.
# Taken by renaming, so of two reruns only one gets it; it admits only a rerun from the same project within the hour.
admitted=""
if [ "$launcher" = bg ] && [ "${HERDR_ENV:-}" = 1 ] && mv "$herdr_failed" "$herdr_failed.$$" 2>/dev/null; then
  marker=$(cat "$herdr_failed.$$" 2>/dev/null || true)
  rm -f "$herdr_failed.$$"
  case ${marker%% *} in
    '' | *[!0-9]*) ;;
    *)
      age=$(($(date +%s) - ${marker%% *}))
      if [ "${marker#* }" = "$root" ] && [ "$age" -ge 0 ] && [ "$age" -lt 3600 ]; then admitted=1; fi
      ;;
  esac
fi
if [ "${HERDR_ENV:-}" = 1 ]; then
  if [ "$launcher" = bg ] && [ -z "$admitted" ]; then
    echo "spawn.sh: --bg is refused inside herdr; the worker opens in a tab the user can watch. It is accepted only for the rerun spawn.sh asks for after a herdr tab fails to start." >&2
    exit 2
  fi
  # herdr refuses an agent name that does not start with a letter or is over 32 characters.
  case $name in
    [a-z]*) [ ${#name} -le 32 ] || { echo "spawn.sh: inside herdr a worker name is at most 32 characters." >&2; exit 2; } ;;
    *) echo "spawn.sh: inside herdr a worker name starts with a letter." >&2; exit 2 ;;
  esac
fi
rm -f "$herdr_failed"
if [ -z "$launcher" ]; then
  if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_WORKSPACE_ID:-}" ] && [ -n "${HERDR_SOCKET_PATH:-}" ] &&
    command -v herdr >/dev/null 2>&1; then
    launcher=herdr
  elif [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    launcher=tmux
  else
    launcher="bg"
    [ "${HERDR_ENV:-}" != 1 ] ||
      echo "spawn.sh: inside herdr but without its workspace, socket or CLI here, so the worker starts in the background: open it with claude attach $name." >&2
  fi
fi
if [ "$provider" = codex ]; then
  if [ "$launcher" = bg ] || ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    echo "Codex workers need a Git worktree and a herdr tab or tmux window." >&2
    exit 2
  fi
  if ! command -v codex >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo "Codex workers need the codex CLI, its running local daemon, and python3." >&2
    exit 2
  fi
  codex_home=$(cd "${CODEX_HOME:-$HOME/.codex}" && pwd -P)
  if [ ! -S "$codex_home/app-server-control/app-server-control.sock" ]; then
    echo "Start the local Codex daemon before launching a Codex worker." >&2
    exit 2
  fi
fi
if [ -z "$(printf '%s' "$brief" | tr -d '[:space:]')" ]; then
  echo "spawn.sh: the brief is empty." >&2
  exit 2
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

if [ -z "$role" ] && { [ "$provider" = codex ] || [ "$caller_provider" = codex ]; }; then
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
if [ "$provider" = codex ] || [ "$caller_provider" = codex ]; then
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
  local updated
  updated=$(mktemp "$record.XXXXXX")
  jq -nc --arg name "$name" --arg launcher "$launcher" --arg id "$id" --arg tab "$tab" --arg dir "$dir" --arg root "$root" \
    --arg socket "$socket" --arg server "$server" --arg base "$base" --arg spawner "$me" --arg label "$label" --argjson worktree "$worktree" \
    --arg pane "$pane" --arg spawner_session "$sid" --arg spawner_provider "$caller_provider" \
    --arg spawner_scope "$role_scope" --arg role "$role" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg provider "$provider" --arg codex "$codex_home" --arg baseline "$baseline" --arg token "$launch_token" \
    '{name: $name, launcher: $launcher, id: $id, tab: $tab, socket: $socket, server: $server, dir: $dir, root: $root,
      base: $base, worktree: $worktree, spawner: $spawner, spawnerSession: $spawner_session, label: $label, startedAt: $at}
      + if $pane != "" then {pane: $pane} else {} end
      + if $role != "" then {spawnerProvider: $spawner_provider, spawnerScope: (if $spawner_scope == "" then null else $spawner_scope end)} else {} end
      + if $provider == "codex" then {provider: $provider, codexHome: $codex, codexBaseline: $baseline, codexLaunchToken: $token} else {} end' > "$updated"
  mv -f "$updated" "$record"
  reserved=""
}

failed() {
  [ -z "${1:-}" ] || echo "$1" >&2
  if [ "$worktree" = true ] && { [ -n "$(worktree_work "$dir" "$base")" ] || ! git -C "$root" worktree remove "$dir"; }; then
    write_record
    echo "Kept $dir and its worker record because Git could not safely remove it." >&2
    exit 1
  fi
  rm -f "$record"
  # Written last, once the name is released, so a rerun it admits can reserve the name.
  if [ "$provider" = claude ] && [ "$launcher" = herdr ] && printf '%s %s\n' "$(date +%s)" "$root" 2>/dev/null >"$herdr_failed"; then
    echo "Rerun with --bg to start it in the background instead." >&2
  fi
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
  baseline=$("$codex_worker" find "$codex_home" "$dir" --baseline) || failed "Could not read the Codex daemon."
  launch_token=$(python3 -c 'import uuid; print(uuid.uuid4())') || failed "Could not create the Codex launch token."
  brief="Anderton launch $launch_token

$brief"
  config_env="CODEX_HOME=$codex_home"
  mode="workspace-write, user approvals"
  # The thread id as the tab's title is how retire.sh tells that the tab still shows this worker's conversation.
  set -- --remote "unix://$codex_home/app-server-control/app-server-control.sock" \
    --sandbox workspace-write -a on-request -c 'approvals_reviewer="user"' -c "model_reasoning_effort=\"$effort\"" \
    -c 'tui.terminal_title=["thread-id"]'
  if [ -n "$model" ]; then set -- "$@" -m "$model"; fi
else
  set -- -n "$name" --permission-mode "$mode" --effort "$effort" --model "${model:-opus}"
  if [ "$caller_provider" = codex ]; then
    set -- "$@" --plugin-dir "$(cd "$anderton_scripts/../../.." && pwd)"
  fi
fi
# A tab or window id is unique only within its server, so the record keeps which server it was opened in.
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
  if ! out=$(herdr agent start "$name" --kind "$provider" --pane "$pane" --timeout 120000 -- "$@" 2>&1) ||
    ! out=$(herdr agent prompt "$pane" "$brief" 2>&1); then
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
  where="herdr tab '$label' ($tab)"
elif [ "$launcher" = tmux ]; then
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
    if claude agents --json 2>/dev/null | jq -e --arg n "$name" 'any(.[]; .name == $n)' >/dev/null 2>&1; then
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
else
  if [ "$caller_provider" = codex ]; then write_record; fi
  out=$(cd "$dir" && claude --bg "$@" "$brief" 2>&1) || failed "$out"
  # `claude stop` and `claude rm` take the session's id, not its name.
  id=$(claude agents --json 2>/dev/null | jq -r --arg n "$name" 'first(.[] | select(.name == $n) | .id) // empty' 2>/dev/null || true)
  [ -n "$id" ] || id=$(printf '%s\n' "$out" | sed -n 's/^backgrounded · \([0-9a-f]*\) · .*/\1/p' | head -n 1)
  printf '%s\n' "$out"
  where="the background (${id:-id unknown})"
  if [ "$caller_provider" = codex ]; then
    lock_worker "$record"
    updated=$(mktemp "$record.XXXXXX")
    jq --arg id "$id" '.id = $id' "$record" > "$updated"
    mv -f "$updated" "$record"
  else
    write_record
  fi
fi

if [ "$provider" = codex ]; then
  tries=$(( ${ANDERTON_START_WAIT:-30} * 2 ))
  while [ "$tries" -gt 0 ]; do
    if id=$("$codex_worker" find "$codex_home" "$dir" --after "$baseline" --token "$launch_token"); then
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
  lock_worker "$record"
  updated=$(mktemp "$record.XXXXXX")
  jq -e --arg id "$id" --arg launch "$launch_token" '
    select(.codexLaunchToken == $launch and (.id == "" or .id == $id)) | .id = $id' "$record" > "$updated"
  mv -f "$updated" "$record"
fi
echo "Started worker '$name' in $where, in $dir ($mode). It reports to '$me'."
