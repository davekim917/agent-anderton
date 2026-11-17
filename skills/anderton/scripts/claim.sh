#!/usr/bin/env bash
# Claim the Anderton role for the calling Claude Code session, in that session's repository, or with
# --project <name> the role for one named project within it, which has its own Anderton. --scope is the
# earlier name of --project and still works. --rebind, which watch.sh runs, only takes back a role this
# session already had: it refuses unless the record names this process, or names this session's id and a
# holder that is no longer live (a resumed session runs as a new process; a restarted one has a new start time).
# --probe <command> names a script watch.sh runs every --probe-every seconds (default 60) for this role, waking
# the holder when it prints something; --no-probe removes it. A claim that names neither keeps the role's probe.
# Exit 0: claimed (or already held by this session). Exit 3: held by another live session, or this
# session already holds another role in the repository.
# Portable to macOS's bash 3.2 and BSD userland.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

require_tools claim.sh

sid="${CLAUDE_CODE_SESSION_ID:?not running inside a Claude Code session}"
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

pid="${CLAUDE_PID:-$(session_pid "$sid")}"
if [ -z "$pid" ]; then
  echo "Cannot find the pid of session $sid under $sessions." >&2
  exit 1
fi
root=$(invoking_root)
role="Anderton for $root"
if [ -n "$scope" ]; then role="$role, project $scope"; fi
state=$(holder_path "$root" "$scope")
mkdir -p "$holders"
# One lock per repository, its projects included: the one-role check reads every role's record in it.
lock="$(holder_path "$root").lock"

# The claim lock is flock where the system has it: the kernel releases it when the claim exits, so it
# cannot go stale, and it holds on filesystems where two concurrent mkdirs can both succeed (seen on
# a CI runner). macOS has no flock, so there it is a directory. Only the claim that made that removes
# it: deleting one whose owner looks dead races a concurrent claim that has just made a fresh one.
take_lock() {
  local tries=0 owner
  if command -v flock >/dev/null 2>&1; then
    exec 9>>"$lock.flock"
    if ! flock -w 10 9; then
      echo "Could not take $lock.flock within 10 seconds: another claim in this repository is running." >&2
      exit 1
    fi
    return
  fi
  until mkdir "$lock" 2>/dev/null; do
    # Not there, so mkdir failed for another reason: retry once and let it say why.
    if [ ! -e "$lock" ]; then
      mkdir "$lock" && break
      exit 1
    fi
    owner=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$owner" ] && [ -z "$(proc_age "$owner")" ]; then
      echo "$lock was left by claim process $owner, which is gone. Remove it and rerun." >&2
      exit 1
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge 50 ]; then
      echo "Could not take $lock within 10 seconds. If no other claim is running, remove it and rerun." >&2
      exit 1
    fi
    sleep 0.2
  done
  trap 'rm -rf "$lock"' EXIT
  trap 'exit 1' INT TERM HUP
  echo $$ > "$lock/pid"
}
take_lock

# The holder is a Claude Code process, not a session id: /clear gives the same process a new one.
record=$(holder_record "$root" "$scope")
# One session holding two roles is the one control session doing two jobs again.
while IFS= read -r other; do
  if [ -n "$other" ] && [ "$other" != "$state" ] && [ "$other" != "$record" ] &&
    is_holder "$sessions/$pid.json" "$other"; then
    held=$(jq -r 'if .scope then "project \(.scope)" else "the repository role" end' "$other" 2>/dev/null || true)
    echo "This session already holds ${held:-another role} in $root. One session holds one role."
    exit 3
  fi
done <<EOF
$(project_holders "$root")
EOF

if [ -n "$rebind" ]; then
  rpid=$(jq -r '.pid // empty' "${record:-/dev/null}" 2>/dev/null || true)
  if [ -z "$record" ]; then
    exit 3
  elif is_holder "$sessions/$pid.json" "$record"; then
    : # This process holds it; the record takes its current session id.
  elif [ "$(jq -r '.sessionId // empty' "$record" 2>/dev/null || true)" != "$sid" ] ||
    { [ -n "$rpid" ] && is_holder "$sessions/$rpid.json" "$record"; }; then
    exit 3
  fi
fi

if [ -n "$record" ] && [ -z "$force" ]; then
  hpid=$(jq -r '.pid // empty' "$record" 2>/dev/null || true)
  if [ -n "$hpid" ] && [ "$hpid" != "$pid" ] && is_holder "$sessions/$hpid.json" "$record"; then
    name=$(jq -r '.name // empty' "$sessions/$hpid.json" 2>/dev/null || true)
    hsid=$(jq -r '.sessionId // empty' "$sessions/$hpid.json" 2>/dev/null || true)
    echo "$role is held by live session '${name:-unknown}' (pid $hpid, session ${hsid:-unknown})."
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
jq -nc --arg root "$root" --arg scope "$scope" --argjson pid "$pid" --arg started "$started" --arg sid "$sid" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson probe "${kept:-null}" \
  '{root: $root, scope: (if $scope == "" then null else $scope end), pid: $pid,
    startedAt: ($started | tonumber? // null), sessionId: $sid, claimedAt: $at}
   + (if $probe == null then {} else {probe: $probe} end)' > "$state.tmp"
mv "$state.tmp" "$state"
# The machine-wide file now speaks for no project, so nothing reads a stale holder from it.
if [ "$record" = "$legacy_holder" ]; then mv "$legacy_holder" "$legacy_holder.migrated"; fi
echo "$role claimed by session $sid (pid $pid)."
if [ -n "$probe_set" ] && [ -n "$probe" ]; then
  echo "Probe set: the watch runs it every ${every:-60} seconds from the end of this turn, and wakes you when it prints."
elif [ -n "$probe_set" ]; then
  echo "Probe removed."
elif [ -n "$old_probe" ] && [ -z "$rebind" ]; then
  echo "Probe kept: $old_probe, every $(jq -r '.probe.every' "$state") seconds. --no-probe removes it."
fi
