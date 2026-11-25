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
codex_home="" codex_dir="" name="" agy_pane="" agy_socket="" agy_dir="" agy_instance=""
root=$(invoking_root)
if [ "$provider" = agy ]; then
  name=${ANDERTON_AGY_NAME:-}
  agy_pane=${HERDR_PANE_ID:-} agy_socket=${HERDR_SOCKET_PATH:-} agy_dir=${ANDERTON_AGY_DIR:-}
  if [ -z "$name" ] || [ -z "$agy_pane" ] || [ -z "$agy_socket" ] || [ -z "$agy_dir" ]; then
    echo "An agy Anderton claims only from a session agy-anderton.sh started inside herdr." >&2
    exit 1
  fi
  if [ "$(project_root "$agy_dir")" != "$root" ]; then
    echo "agy session $sid runs in another repository: $agy_dir." >&2
    exit 1
  fi
  # The agy conversation in the pane, which herdr's agy integration names: a relaunch or /clear there starts another.
  agy_instance=$(HERDR_SOCKET_PATH="$agy_socket" herdr agent get "$agy_pane" 2>/dev/null |
    jq -r '.result.agent.agent_session.value // empty | tostring' 2>/dev/null) || agy_instance=""
  if [ -z "$agy_instance" ]; then
    echo "herdr does not name the agy conversation in pane $agy_pane, so the role could not tell it from the next one there." >&2
    echo "Install herdr's agy integration (herdr integration install antigravity-cli), then claim again." >&2
    exit 1
  fi
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
if [ -n "$record" ] && [ "$(jq -r '.sessionId // empty' "$record")" = "$sid" ] &&
  { [ -n "$rebind" ] || caller_matches_claim "$record"; }; then
  peer=$(jq -c '.peerMessage // null' "$record")
fi
# The same session keeps its claim's id through a re-claim, a rebind and a resume; any other session gets a new one.
claim_id=""
if [ -n "$record" ] && [ "$(jq -r '.sessionId // empty' "$record")" = "$sid" ]; then
  claim_id=$(jq -r '.claimId // empty' "$record" 2>/dev/null || true)
fi
claim_id=${claim_id:-$(new_claim_id)} || { echo "Could not make a claim id." >&2; exit 1; }
jq -nc --arg root "$root" --arg scope "$scope" --arg pid "$pid" --arg started "$started" --arg sid "$sid" \
  --arg provider "$provider" --arg codex_home "$codex_home" --arg codex_dir "$codex_dir" --arg name "$name" \
  --arg claude_report_since "$claude_report_since" --argjson previous_claude "$previous_claude" \
  --arg agy_pane "$agy_pane" --arg agy_socket "$agy_socket" --arg agy_dir "$agy_dir" --arg agy_instance "$agy_instance" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson probe "${kept:-null}" --argjson peer "$peer" --arg claim_id "$claim_id" \
  '{root: $root, scope: (if $scope == "" then null else $scope end), provider: $provider,
    sessionId: $sid, claimId: $claim_id, claimedAt: $at}
   + (if $provider == "codex" then {codexHome: $codex_home, dir: $codex_dir, name: $name, claudeReportSince: $claude_report_since,
                                    claudeReportPreviousHolder: $previous_claude}
      elif $provider == "agy" then {dir: $agy_dir, name: $name, pane: $agy_pane, socket: $agy_socket, agyInstance: $agy_instance,
                                    claudeReportSince: $claude_report_since, claudeReportPreviousHolder: $previous_claude}
      else {pid: ($pid | tonumber), startedAt: ($started | tonumber? // null)} end)
   + (if $probe == null then {} else {probe: $probe} end)
   + (if $peer == null then {} else {peerMessage: $peer} end)' > "$state.tmp"
mv "$state.tmp" "$state"
# The machine-wide file now speaks for no project, so nothing reads a stale holder from it.
if [ "$record" = "$legacy_holder" ]; then mv "$legacy_holder" "$legacy_holder.migrated"; fi
# A rebind runs on every turn's end; only a claim starts the role's thread on the host.
if [ -z "$rebind" ]; then emit_event "$claim_id" "$scope" start; fi
if [ "$provider" = codex ]; then
  "$anderton_scripts/codex-worker.py" start-watch "$anderton_scripts/watch.sh" "$state"
  echo "$role claimed by Codex thread $sid."
elif [ "$provider" = agy ]; then
  # What agy loads hooks and agents from for this checkout, as the role is claimed: waiting.sh reports changes from it.
  agy_config_state "$agy_dir" > "${state%.json}.agy-config"
  # agy ends a tool's processes when its command returns, so the watch runs in a session of its own.
  python3 -c 'import subprocess, sys; subprocess.Popen(sys.argv[1:], start_new_session=True, stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)' "$anderton_scripts/watch.sh" --agy "$state"
  echo "$role claimed by agy session $sid ($name, herdr pane $agy_pane)."
else
  echo "$role claimed by session $sid (pid $pid)."
fi
if [ -n "$probe_set" ] && [ -n "$probe" ]; then
  echo "Probe set: the watch runs it every ${every:-60} seconds and wakes you when it prints."
elif [ -n "$probe_set" ]; then
  echo "Probe removed."
elif [ -n "$old_probe" ] && [ -z "$rebind" ]; then
  echo "Probe kept: $old_probe, every $(jq -r '.probe.every' "$state") seconds. --no-probe removes it."
fi
