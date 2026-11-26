#!/usr/bin/env bash
# Claim the Anderton role for the calling Claude Code or Codex session, in that session's repository, or with
# --project <name> the role for one named project within it, which has its own Anderton. --scope is the
# earlier name of --project and still works. --rebind, which watch.sh runs, only takes back a role this
# session already had: it refuses unless the record names this process, or names this session's id and a
# holder that is no longer live (a resumed session runs as a new process; a restarted one has a new start time).
# --probe <command> names a script watch.sh runs every --probe-every seconds (default 60) for this role, waking
# the holder when it prints something; --no-probe removes it. A claim that names neither keeps the role's probe.
# Each claim has a claimId, kept by the same session and new for any other; a project role's claim emits a start
# event to ANDERTON_EVENT_COMMAND when the host sets one (see emit_event in session-lib.sh).
# Exit 0: claimed (or already held by this session). Exit 3: held by another live session, or this
# session already holds another role in the repository.
# Portable to macOS's bash 3.2 and BSD userland.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

require_tools claim.sh

agy_relaunch="quit agy and reopen it in this pane with: agy --dangerously-skip-permissions --conversation=${ANTIGRAVITY_CONVERSATION_ID:-<the id agy prints as it quits>}, which keeps this conversation"
if [ -n "${ANDERTON_AGY_SANDBOXED:-}" ]; then
  echo "This agy session runs its commands in agy's terminal sandbox (its auto mode), which hides herdr and the agy process from them, so it cannot hold an Anderton role. To make it an Anderton, $agy_relaunch, then run /anderton again." >&2
  exit 1
fi
sid=$(invoking_session)
[ -n "$sid" ] || { echo "Run claim.sh from the designated Claude Code, Codex or agy session." >&2; exit 1; }
usage="usage: claim.sh [--project <name>] [--take-over | --rebind] [--probe <command> [--probe-every <seconds>] | --no-probe]"
force="" scope="" rebind="" probe="" every="" probe_set=""
while [ $# -gt 0 ]; do
  case $1 in
    --take-over) force=1 ;;
    --rebind) rebind=1 ;;
    --project | --scope | --probe | --probe-every)
      if [ -z "${2:-}" ]; then echo "$usage" >&2; exit 2; fi
      case $1 in
        --probe) probe=$2 probe_set=1 ;;
        --probe-every) every=$2 ;;
        *) scope=$2 ;;
      esac
      shift
      ;;
    --no-probe) probe="" probe_set=1 ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
  shift
done
if [ -n "$every" ]; then
  case $every in
    *[!0-9]*) every=0 ;;
  esac
  if [ "$every" -lt 10 ] || [ -z "$probe" ]; then
    echo "--probe-every takes whole seconds, 10 or more, with --probe." >&2
    exit 2
  fi
fi

provider=$(invoking_provider)
pid=$(invoking_pid)
codex_home="" codex_dir="" name="" agy_pane="" agy_socket="" agy_dir="" agy_pid="" agy_start="" agy_home="" agy_dirs=()
root=$(invoking_root)
if [ "$provider" = agy ]; then
  agy_pane=${HERDR_PANE_ID:-} agy_socket=${HERDR_SOCKET_PATH:+$(resolve_path "$HERDR_SOCKET_PATH")} agy_dir=${ANDERTON_AGY_DIR:-}
  if [ -z "$agy_pane" ] || [ -z "$agy_socket" ] || [ -z "$agy_dir" ]; then
    echo "An agy Anderton claims only from an agy session inside herdr." >&2
    exit 1
  fi
  name=${ANDERTON_AGY_NAME:-agy-$(basename "$agy_dir")${scope:+-$scope}}
  name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-')
  if [ "$(project_root "$agy_dir")" != "$root" ]; then
    echo "agy session $sid runs in another repository: $agy_dir." >&2
    exit 1
  fi
  agy_pid=${ANDERTON_AGY_PID:-}
  case $agy_pid in '' | *[!0-9]*) agy_start="" ;; *) agy_start=$(proc_start "$agy_pid") ;; esac
  if [ -z "$agy_start" ]; then
    echo "An agy Anderton claims only from an agy session inside herdr, while it runs." >&2
    exit 1
  fi
  if ! descends_from "$agy_pid"; then
    echo "This shell does not run under agy process $agy_pid, so it cannot claim for that session." >&2
    exit 1
  fi
  # What agy loads comes from its own home, whatever this shell's HOME says.
  agy_home=$(proc_home "$agy_pid")
  if [ -z "$agy_home" ] || [ ! -d "$agy_home" ]; then
    echo "Could not read the home agy process $agy_pid runs with, so the configuration it loads could not be checked." >&2
    exit 1
  fi
  HOME=$agy_home require_registered_agy_copy
  # agy loads workspace hooks from each directory between its working directory and the top of the checkout.
  agy_cwd=$(proc_cwd "$agy_pid")
  case $agy_cwd in
    "$agy_dir" | "$agy_dir"/*) ;;
    *)
      echo "Could not place agy process $agy_pid's working directory (${agy_cwd:-unreadable}) in $agy_dir, so the hooks it loads could not be checked." >&2
      exit 1
      ;;
  esac
  agy_dirs=("$agy_cwd")
  while [ "$agy_cwd" != "$agy_dir" ]; do
    agy_cwd=$(dirname "$agy_cwd")
    agy_dirs+=("$agy_cwd")
  done
  workspaces=()
  for d in "${agy_dirs[@]}"; do workspaces+=(--workspace "$d"); done
  # The claim is live only while herdr shows this agy in this pane and checkout, so one it would read as gone is refused.
  probe_record=$(mktemp "${TMPDIR:-/tmp}/anderton-agy.XXXXXX") || exit 1
  jq -nc --arg socket "$agy_socket" --arg pane "$agy_pane" --arg dir "$agy_dir" --arg pid "$agy_pid" --arg start "$agy_start" \
    '{socket: $socket, pane: $pane, dir: $dir, agyPid: ($pid | tonumber), agyStart: $start}' > "$probe_record"
  agy_check "$probe_record"
  rm -f "$probe_record"
  if [ "$agy_state" = unknown ]; then
    echo "herdr gave no readable answer about the process in pane $agy_pane (herdr pane process-info, which herdr 0.9.5 has), so whether this agy holds the role could never be told: update herdr, then claim again." >&2
    exit 1
  elif [ "$agy_state" != running ]; then
    echo "herdr does not show this agy in pane $agy_pane, in $agy_dir (it shows ${agy_agent:-no agent}${agy_cwd:+ in $agy_cwd}), so the claim could not be held." >&2
    exit 1
  fi
  if ! out=$(HOME=$agy_home "$anderton_scripts/agy-hooks.sh" check "${workspaces[@]}" 2>&1); then
    echo "$out
agy would run unguarded, so this session cannot hold an Anderton role." >&2
    exit 1
  fi
  # How agy was started: without this flag it asks before commands it does not auto-approve.
  case $(ps -o args= -p "$agy_pid" 2>/dev/null) in
    *--dangerously-skip-permissions*) agy_prompts="" ;;
    *) agy_prompts=1 ;;
  esac
elif [ "$provider" = codex ]; then
  codex_home=$(invoking_codex_home) || { echo "Could not resolve the Codex home." >&2; exit 1; }
  identity=$("$anderton_scripts/codex-worker.py" identity "$codex_home" "$sid") || exit 1
  codex_dir=$(printf '%s' "$identity" | jq -r .dir)
  name=$(printf '%s' "$identity" | jq -r .name)
  if [ "$(project_root "$codex_dir")" != "$root" ]; then
    echo "Codex thread $sid belongs to another repository: $codex_dir." >&2
    exit 1
  fi
elif [ -z "$pid" ]; then
  echo "Cannot find the pid of session $sid under $sessions." >&2
  exit 1
fi
role="Anderton for $root"
if [ -n "$scope" ]; then role="$role, project $scope"; fi
state=$(holder_path "$root" "$scope")
mkdir -p "$holders"
take_repository_lock "$root"
worker=$(managed_invoker "$root" "$provider" "$sid" "${codex_home:-$pid}" "$codex_dir")
if [ -n "$worker" ]; then
  echo "This session is managed as worker '$(jq -r .name "$worker")'. Its Anderton must release it before it can claim a role."
  exit 3
fi

record=$(holder_record "$root" "$scope")
# One session holding two roles is the one control session doing two jobs again. A Codex thread is one session on
# whichever account's home it runs.
while IFS= read -r other; do
  if [ -n "$other" ] && [ "$other" != "$state" ] && [ "$other" != "$record" ] &&
    { caller_matches_claim "$other" || { [ "$provider" = codex ] && [ "$(record_provider "$other")" = codex ] &&
      [ "$(jq -r '.sessionId // empty' "$other")" = "$sid" ]; }; }; then
    held=$(jq -r 'if .scope then "project \(.scope)" else "the repository role" end' "$other" 2>/dev/null || true)
    echo "This session already holds ${held:-another role} in $root. One session holds one role."
    exit 3
  fi
done <<EOF
$(project_holders "$root")
EOF
# A claim whose move to another account stopped before handing it over follows its thread to the home that last ran
# it, once no other role is this session's.
if [ "$provider" = codex ] && [ -n "$record" ] && [ "$(record_provider "$record")" = codex ] &&
  [ "$(jq -r '.sessionId // empty' "$record")" = "$sid" ] && [ "$(jq -r '.codexHome // empty' "$record")" != "$codex_home" ] &&
  [ "$(codex_thread_home "$sid" || true)" = "$codex_home" ]; then
  # The old home's watch would keep the job this claim's new watch needs.
  stop_codex_watch "$record"
  set_codex_home "$record" "$codex_home" || exit 1
fi

if [ -n "$rebind" ]; then
  if [ -z "$record" ]; then
    exit 3
  elif caller_matches_claim "$record"; then
    :
  elif [ "$provider" != claude ] || [ "$(record_provider "$record")" != claude ] ||
    [ "$(jq -r '.sessionId // empty' "$record" 2>/dev/null || true)" != "$sid" ] ||
    [ "$(claim_state "$record")" != gone ]; then
    exit 3
  fi
fi

if [ -n "$record" ] && [ -z "$force" ] && ! caller_matches_claim "$record"; then
  health=$(claim_state "$record")
  if [ "$health" != gone ]; then
    hname=$(claim_name "$record")
    if [ "$(record_provider "$record")" = claude ]; then
      hpid=$(jq -r '.pid // empty' "$record")
      hsid=$(jq -r '.sessionId // empty' "$sessions/$hpid.json" 2>/dev/null || true)
      echo "$role is held by live session '${hname:-unknown}' (pid $hpid, session ${hsid:-unknown})."
    else
      hsid=$(jq -r '.sessionId // empty' "$record" 2>/dev/null || true)
      echo "$role is held by $(record_provider "$record") session ${hsid:-unknown} (${hname:-unknown}, liveness: $health)."
    fi
    echo "Rerun with --take-over only if the user says so."
    exit 3
  fi
fi

# The probe belongs to the role, not the session: a rebind, a take-over and a plain re-claim keep it.
old_probe=$(jq -r '.probe.command // empty' "${record:-/dev/null}" 2>/dev/null || true)
if [ -n "$probe_set" ]; then
  kept=$(jq -nc --arg c "$probe" --arg e "${every:-60}" 'if $c == "" then null else {command: $c, every: ($e | tonumber)} end')
  # A different probe starts with no failures or alerts of the old one's to inherit.
  if [ "$probe" != "$old_probe" ]; then
    rm -f "${state%.json}.probe/failures" "${state%.json}.probe/alerted" "${state%.json}.probe/told" "${state%.json}.probe/last"
  fi
else
  kept=$(jq -c '.probe // null' "${record:-/dev/null}" 2>/dev/null || true)
fi
started=$(jq -r '.startedAt // empty | floor' "$sessions/$pid.json" 2>/dev/null || true)
peer=null
claude_report_since=""
previous_claude=null
if [ "$provider" = codex ] || [ "$provider" = agy ]; then
  if [ -n "$record" ]; then
    if [ "$(record_provider "$record")" != claude ]; then
      claude_report_since=$(jq -r '.claudeReportSince // .claimedAt // empty' "$record")
      previous_claude=$(jq -c '.claudeReportPreviousHolder // null' "$record")
    else
      previous_claude=$(jq -c '{sessionId,pid}' "$record")
    fi
  fi
  claude_report_since=${claude_report_since:-$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())')}
fi
# The same holder: its session id, or for agy the same agy process, whatever session id an earlier version recorded.
same_holder=""
if [ -n "$record" ] && { [ "$(jq -r '.sessionId // empty' "$record")" = "$sid" ] ||
  { [ "$provider" = agy ] && [ "$(record_provider "$record")" = agy ] && caller_matches_claim "$record"; }; }; then
  same_holder=1
fi
if [ -n "$same_holder" ] && { [ -n "$rebind" ] || caller_matches_claim "$record"; }; then
  peer=$(jq -c '.peerMessage // null' "$record")
fi
# The same holder keeps its claim's id through a re-claim, a rebind and a resume; any other session gets a new one.
claim_id=""
if [ -n "$same_holder" ]; then
  claim_id=$(jq -r '.claimId // empty' "$record" 2>/dev/null || true)
fi
claim_id=${claim_id:-$(new_claim_id)} || { echo "Could not make a claim id." >&2; exit 1; }
# A take-over from another holder, whether or not it still runs, is logged once the claim has changed, so a mistaken
# one is seen and handed back. The displaced holder is the one the claim names: by now the registry may give its pid
# to another session.
displaced="" dprovider="" dsid="" dname=""
if [ -n "$record" ] && [ -n "$force" ] && [ -z "$same_holder" ]; then
  displaced=1
  dprovider=$(record_provider "$record")
  dsid=$(jq -r '.sessionId // empty' "$record" 2>/dev/null || true)
  dname=$(jq -r '.name // empty' "$record" 2>/dev/null || true)
  dfrom=$(jq -c --arg provider "$dprovider" '{provider: $provider, sessionId, pid, name, claimId} | with_entries(select(.value != null))' \
    "$record" 2>/dev/null) || dfrom="{\"provider\":\"$dprovider\"}"
  taker_name=$name
  if [ "$provider" = claude ]; then taker_name=$(jq -r '.name // empty' "$sessions/$pid.json" 2>/dev/null || true); fi
  hand_back="claim.sh${scope:+ --project $(printf '%q' "$scope")} --take-over"
fi
jq -nc --arg root "$root" --arg scope "$scope" --arg pid "$pid" --arg started "$started" --arg sid "$sid" \
  --arg provider "$provider" --arg codex_home "$codex_home" --arg codex_dir "$codex_dir" --arg name "$name" \
  --arg claude_report_since "$claude_report_since" --argjson previous_claude "$previous_claude" \
  --arg agy_pane "$agy_pane" --arg agy_socket "$agy_socket" --arg agy_dir "$agy_dir" --arg agy_pid "$agy_pid" --arg agy_start "$agy_start" \
  --arg agy_home "$agy_home" --argjson agy_dirs "$(jq -nc '$ARGS.positional' --args ${agy_dirs[@]+"${agy_dirs[@]}"})" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson probe "${kept:-null}" --argjson peer "$peer" --arg claim_id "$claim_id" \
  '{root: $root, scope: (if $scope == "" then null else $scope end), provider: $provider,
    sessionId: $sid, claimId: $claim_id, claimedAt: $at}
   + (if $provider == "codex" then {codexHome: $codex_home, dir: $codex_dir, name: $name, claudeReportSince: $claude_report_since,
                                    claudeReportPreviousHolder: $previous_claude}
      elif $provider == "agy" then {dir: $agy_dir, name: $name, pane: $agy_pane, socket: $agy_socket, agyPid: ($agy_pid | tonumber), agyStart: $agy_start,
                                    agyHome: $agy_home, agyWorkspaces: $agy_dirs,
                                    claudeReportSince: $claude_report_since, claudeReportPreviousHolder: $previous_claude}
      else {pid: ($pid | tonumber), startedAt: ($started | tonumber? // null)} end)
   + (if $probe == null then {} else {probe: $probe} end)
   + (if $peer == null then {} else {peerMessage: $peer} end)' > "$state.tmp"
mv "$state.tmp" "$state"
logged=""
if [ -n "$displaced" ]; then
  if jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg key "$(basename "$state" .json)" --arg role "$role" \
    --argjson from "$dfrom" --arg provider "$provider" --arg sid "$sid" --arg name "$taker_name" --arg claim_id "$claim_id" \
    '{at: $at, key: $key, role: $role, from: $from,
      to: ({provider: $provider, sessionId: $sid, name: $name, claimId: $claim_id} | with_entries(select(.value != "")))}' \
    >> "$holders/takeovers.log" 2>/dev/null; then
    logged=1
  else
    echo "Warning: could not log the take-over in $holders/takeovers.log." >&2
  fi
fi
# The machine-wide file now speaks for no project, so nothing reads a stale holder from it.
if [ "$record" = "$legacy_holder" ]; then mv "$legacy_holder" "$legacy_holder.migrated"; fi
# A rebind runs on every turn's end; only a claim starts the role's thread on the host.
if [ -z "$rebind" ]; then emit_event "$claim_id" "$scope" start; fi
if [ "$provider" = codex ]; then
  "$anderton_scripts/codex-worker.py" start-watch "$anderton_scripts/watch.sh" "$state"
  echo "$role claimed by Codex thread $sid."
elif [ "$provider" = agy ]; then
  # What agy loads hooks and agents from for this checkout, as the role is claimed: waiting.sh reports changes from it.
  HOME=$agy_home agy_config_state "${agy_dirs[@]}" > "${state%.json}.agy-config"
  # agy ends a tool's processes when its command returns, so the watch runs in a session of its own.
  python3 -c 'import subprocess, sys; subprocess.Popen(sys.argv[1:], start_new_session=True, stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)' "$anderton_scripts/watch.sh" --agy "$state"
  echo "$role claimed by agy session $sid ($name, herdr pane $agy_pane)."
  if [ -n "${agy_prompts:-}" ] && [ -z "$rebind" ]; then
    echo "This agy was started without --dangerously-skip-permissions, so it stops for your approval on commands it does not auto-approve, and workers' reports and its watch's messages wait behind those prompts. To run as agy workers do, with the guard as the gate, $agy_relaunch."
  fi
else
  echo "$role claimed by session $sid (pid $pid)."
fi
if [ -n "$displaced" ]; then
  echo "Took it over from $dprovider session ${dsid:-unknown}${dname:+ ($dname)}.${logged:+ Logged it in $holders/takeovers.log.} To hand it back, that session runs $hand_back once the user says so."
fi
if [ -n "$probe_set" ] && [ -n "$probe" ]; then
  echo "Probe set: the watch runs it every ${every:-60} seconds and wakes you when it prints."
elif [ -n "$probe_set" ]; then
  echo "Probe removed."
elif [ -n "$old_probe" ] && [ -z "$rebind" ]; then
  echo "Probe kept: $old_probe, every $(jq -r '.probe.every' "$state") seconds. --no-probe removes it."
fi
