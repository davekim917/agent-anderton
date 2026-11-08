#!/usr/bin/env bash
# Claim the Anderton role for the calling Claude Code session, in that session's repository, or with
# --project <name> the role for one named project within it, which has its own Anderton. --scope is the
# earlier name of --project and still works.
# Exit 0: claimed (or already held by this session). Exit 3: held by another live session, or this
# session already holds another role in the repository.
# Portable to macOS's bash 3.2 and BSD userland.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

require_tools claim.sh

sid="${CLAUDE_CODE_SESSION_ID:?not running inside a Claude Code session}"
force="" scope=""
while [ $# -gt 0 ]; do
  case $1 in
    --take-over) force=1 ;;
    --project | --scope)
      if [ -z "${2:-}" ]; then echo "usage: claim.sh [--project <name>] [--take-over]" >&2; exit 2; fi
      scope=$2
      shift
      ;;
    *) echo "usage: claim.sh [--project <name>] [--take-over]" >&2; exit 2 ;;
  esac
  shift
done

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

started=$(jq -r '.startedAt // empty | floor' "$sessions/$pid.json" 2>/dev/null || true)
jq -nc --arg root "$root" --arg scope "$scope" --argjson pid "$pid" --arg started "$started" --arg sid "$sid" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{root: $root, scope: (if $scope == "" then null else $scope end), pid: $pid,
    startedAt: ($started | tonumber? // null), sessionId: $sid, claimedAt: $at}' > "$state.tmp"
mv "$state.tmp" "$state"
# The machine-wide file now speaks for no project, so nothing reads a stale holder from it.
if [ "$record" = "$legacy_holder" ]; then mv "$legacy_holder" "$legacy_holder.migrated"; fi
echo "$role claimed by session $sid (pid $pid)."
