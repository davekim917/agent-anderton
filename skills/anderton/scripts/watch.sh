#!/usr/bin/env bash
# The plugin's Stop hook, which Claude Code runs in the background in every session. In a session holding an
# Anderton role, the repository's or a named project's, it keeps running, and exits 2 when a session that role
# answers for newly blocks on a person: Claude Code then wakes the holder with this script's stderr, and the next
# Stop runs it again. It only reports. waiting.sh --blocked decides what counts as blocked and which role answers
# for it, and nothing here can answer a prompt. Anywhere else, and on any failure, it exits 0 and prints nothing.
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null) || exit 0
if [ -z "$sid" ] || [ -z "$cwd" ]; then exit 0; fi

# The registry, not the record, says which session the holder's process runs now: /clear gives it a new id.
record="" pid="" reg=""
while IFS= read -r r; do
  [ -n "$r" ] || continue
  p=$(jq -r '.pid // empty' "$r" 2>/dev/null)
  [ -n "$p" ] || continue
  if [ "$(jq -r '.sessionId // empty' "$sessions/$p.json" 2>/dev/null)" = "$sid" ] && is_holder "$sessions/$p.json" "$r"; then
    record=$r pid=$p reg="$sessions/$p.json"
    break
  fi
done <<EOF
$(project_holders "$(project_root "$cwd")")
EOF
[ -n "$record" ] || exit 0

key=$(basename "$record" .json)
watcher="$holders/$key.watch"
# Per holder: an earlier holder's last pass must not record a block this holder has not heard about.
reported="$holders/$key.$pid.reported"
reported_keep=200
tick=${ANDERTON_WATCH_TICK:-30}
mkdir -p "$holders" 2>/dev/null || exit 0
[ -w "$holders" ] || exit 0
take_watch() { (set -C; printf '%s %s %s\n' "$$" "$pid" "$PPID" > "$watcher") 2>/dev/null; }
watch_owner() { local p=""; { read -r p _ < "$watcher"; } 2>/dev/null; printf '%s' "$p"; }
# Claude Code hears a hook's exit through the process that started it, so a watch that lost that process wakes no one.
orphaned() { # orphaned <pid> <the parent it started under>
  local now
  now=$(ps -o ppid= -p "$1" 2>/dev/null)
  [ -n "$now" ] && [ "$now" -ne "$2" ]
}
until take_watch; do
  is_holder "$reg" "$record" || exit 0
  other=""; owner=""; parent=""
  { read -r other owner parent < "$watcher"; } 2>/dev/null
  # -ww: ps cuts its output at COLUMNS even into a pipe, and a cut path makes a live watch look dead.
  case $(ps -ww -o command= -p "${other:-0}" 2>/dev/null) in
    *watch.sh*)
      if orphaned "$other" "${parent:-0}"; then
        rm -f "$watcher"
      else
        # A watch for this holder keeps the job. An earlier holder's leaves within a tick of losing the role.
        [ "$owner" != "$pid" ] || exit 0
        sleep "$tick"
      fi
      ;;
    *) rm -f "$watcher" ;;
  esac
done
trap '[ "$(watch_owner)" != "$$" ] || rm -f "$watcher"' EXIT

find "$holders" -maxdepth 1 -name "$key.*.reported" ! -path "$reported" -exec rm -f {} + 2>/dev/null
: >> "$reported" || exit 0
export CLAUDE_PID="$pid"
while is_holder "$reg" "$record"; do
  if orphaned "$$" "$PPID"; then exit 0; fi
  # Only the lock's owner watches: a watch that lost it leaves, and one whose lock vanished takes it back.
  if [ "$(watch_owner)" != "$$" ] && ! take_watch; then exit 0; fi
  now=$(cd "$cwd" 2>/dev/null && "$(dirname "$0")/waiting.sh" --blocked 2>/dev/null | grep '^=== ')
  new=$(printf '%s\n' "$now" | grep -vxF -f "$reported" | grep .)
  if [ -n "$new" ]; then
    # Append only, so a scan that misses a block cannot make it new again. A block that clears and returns has a
    # new start time in its header, so it is still reported.
    printf '%s\n' "$new" >> "$reported"
    tail -n "$reported_keep" "$reported" > "$reported.tmp" && mv "$reported.tmp" "$reported"
    {
      echo "Anderton watch: a session you answer for is blocked on a person. Nothing has been answered or approved."
      printf '%s\n' "$new"
      echo "Run waiting.sh to see what each one is asking."
    } >&2
    exit 2
  fi
  sleep "$tick"
done
exit 0
