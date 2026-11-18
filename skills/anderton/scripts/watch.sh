#!/usr/bin/env bash
# The plugin's Stop hook, which Claude Code runs in the background in every session. In a session holding an
# Anderton role, the repository's or a named project's, it keeps running, and exits 2 when a session that role
# answers for newly blocks on a person: Claude Code then wakes the holder with this script's stderr, and the next
# Stop runs it again. It only reports. waiting.sh --blocked decides what counts as blocked and which role answers
# for it, and nothing here can answer a prompt. When the role's claim names a probe (claim.sh --probe), it also runs
# that probe on its interval and wakes the holder with whatever it prints, or after ANDERTON_PROBE_FAILURES (default
# 3) failed runs in a row with "probe failing". Anywhere else, and on any failure, it exits 0 and prints nothing.
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
# The record follows the session, not only its process: after /clear the process has a new session id,
# and after a resume or restart the session has a new process or start time. claim.sh --rebind brings
# the record up to date under the claim lock, and never takes a role from a live holder or another session.
rebind() { # rebind <record>: as this session; true once this session's process holds it
  local p scope args
  p=$(session_pid "$sid")
  [ -n "$p" ] || return 1
  scope=$(jq -r '.scope // empty' "$1" 2>/dev/null) || return 1
  args=(--rebind)
  if [ -n "$scope" ]; then args+=(--project "$scope"); fi
  (cd "$cwd" && CLAUDE_CODE_SESSION_ID="$sid" CLAUDE_PID="$p" "$(dirname "$0")/claim.sh" "${args[@]}") >/dev/null 2>&1 &&
    is_holder "$sessions/$p.json" "$1" && record=$1 pid=$p reg="$sessions/$p.json"
}
if [ -n "$record" ]; then
  if [ "$(jq -r '.sessionId // empty' "$record" 2>/dev/null)" != "$sid" ]; then rebind "$record" || true; fi
else
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    if [ "$(jq -r '.sessionId // empty' "$r" 2>/dev/null)" = "$sid" ] && rebind "$r"; then break; fi
  done <<EOF
$(project_holders "$(project_root "$cwd")")
EOF
fi
[ -n "$record" ] || exit 0

key=$(basename "$record" .json)
watcher="$holders/$key.watch"
# Per holder: an earlier holder's last pass must not record a block this holder has not heard about.
reported="$holders/$key.$pid.reported"
reported_keep=200
tick=${ANDERTON_WATCH_TICK:-30}
# Claude Code ends this hook at the timeout hooks.json gives it, and only the holder's next Stop starts it again, so a
# role that hears nothing that long would stop being watched without a word. The watch wakes the holder a day early.
limit=$(jq -r '.hooks.Stop[0].hooks[0].timeout // empty' "$(dirname "$0")/../../../hooks/hooks.json" 2>/dev/null)
case $limit in '' | *[!0-9]*) limit=1209600 ;; esac
renew=${ANDERTON_WATCH_RENEW:-$((limit - 86400))}
started=$(date +%s)
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
same_script() { # same_script <command line>: true when it runs this watch.sh, from this install of the plugin
  case $0 in /*) ;; *) return 0 ;; esac
  case " $1 " in *" $0 "*) return 0 ;; esac
  return 1
}
until take_watch; do
  is_holder "$reg" "$record" || exit 0
  other=""; owner=""; parent=""
  { read -r other owner parent < "$watcher"; } 2>/dev/null
  # -ww: ps cuts its output at COLUMNS even into a pipe, and a cut path makes a live watch look dead.
  command=$(ps -ww -o command= -p "${other:-0}" 2>/dev/null)
  case $command in
    *watch.sh*)
      if orphaned "$other" "${parent:-0}"; then
        rm -f "$watcher"
      elif ! same_script "$command"; then
        # A watch from another install of the plugin, one an update or a reload left running, would keep the job
        # forever and never run this version. It is replaced: TERM runs its EXIT trap, which ends its probe's group.
        kill -TERM "$other" 2>/dev/null
        for _ in $(seq 1 50); do
          kill -0 "$other" 2>/dev/null || break
          sleep 0.1
        done
        kill -KILL "$other" 2>/dev/null
        if [ "$(watch_owner)" = "$other" ]; then rm -f "$watcher"; fi
      else
        # A watch for this holder keeps the job. An earlier holder's leaves within a tick of losing the role.
        [ "$owner" != "$pid" ] || exit 0
        sleep "$tick"
      fi
      ;;
    *) rm -f "$watcher" ;;
  esac
done
probe_pid=""
# A probe runs in its own process group, so a watch that ends must end it too.
trap '[ -z "$probe_pid" ] || kill -TERM -- "-$probe_pid" 2>/dev/null; [ "$(watch_owner)" != "$$" ] || rm -f "$watcher"' EXIT

find "$holders" -maxdepth 1 -name "$key.*.reported" ! -path "$reported" -exec rm -f {} + 2>/dev/null
: >> "$reported" || exit 0
export CLAUDE_PID="$pid"

# The probe's state outlives the holder: the role keeps its probe across sessions, so it keeps the bookmarks too.
# The probe reads its bookmarks from ANDERTON_PROBE_STATE and writes the ones it would advance to into
# ANDERTON_PROBE_STAGE, for each source it read in full. They move into the state once its output has woken the
# holder, or when it printed nothing, so a bookmark never passes an item the holder has not been told about. A run
# that timed out may have staged half a write, so its stage is dropped.
probe_dir="$holders/$key.probe"
probe_out_max=6000
probe_timeout=${ANDERTON_PROBE_TIMEOUT:-120}
probe_fail_at=${ANDERTON_PROBE_FAILURES:-3}
probe_news="" probe_alert="" probe_why="" probe_run="" probe_commit=""
stage_moves() { # true when this run's stage would change a bookmark
  local f
  for f in "$probe_run/stage"/* "$probe_run/stage"/.[!.]*; do
    if [ -e "$f" ] && ! cmp -s "$f" "$probe_dir/bookmarks/$(basename "$f")"; then return 0; fi
  done
  return 1
}
run_probe() { # run_probe <command>: sets $probe_news, $probe_alert, $probe_why, $probe_run and $probe_commit
  local p d status=0 waited=0 fails=""
  probe_news="" probe_alert="" probe_why="" probe_commit=""
  mkdir -p "$probe_dir/bookmarks" 2>/dev/null || return 0
  # A run whose watch was killed outright: end what it started before clearing it away.
  for d in "$probe_dir"/run.*; do
    if [ -d "$d" ] && ! ps -p "${d##*.}" >/dev/null 2>&1; then
      { read -r p < "$d/group"; } 2>/dev/null && kill -KILL -- "-$p" 2>/dev/null
      rm -rf "$d"
    fi
  done
  probe_run="$probe_dir/run.$$"
  rm -rf "$probe_run"
  mkdir -p "$probe_run/stage" 2>/dev/null || return 0
  date +%s > "$probe_dir/last"
  # Its own process group, so a timeout ends whatever the probe started as well.
  set -m
  (cd "$cwd" && ANDERTON_PROBE_STATE="$probe_dir/bookmarks" ANDERTON_PROBE_STAGE="$probe_run/stage" \
    exec bash -c "$1") < /dev/null > "$probe_run/out" 2> "$probe_run/err" &
  p=$!
  set +m
  probe_pid=$p
  echo "$p" > "$probe_run/group"
  trap 'exit 143' TERM HUP INT
  # Tenths of a second: most probes take a second or two, and the holder should not wait on the poll.
  while kill -0 "$p" 2>/dev/null; do
    if [ "$waited" -ge "$((probe_timeout * 10))" ]; then
      kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null
      sleep 2
      kill -KILL -- "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null
      status=timeout
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  if [ "$status" = timeout ]; then
    wait "$p" 2>/dev/null
    probe_why="timed out after ${probe_timeout}s"
    # What it printed before it hung comes back unchanged next run, with its bookmark never moved: told once by the
    # failure alert rather than on every run.
    : > "$probe_run/out"
  elif [ -n "$(find "$probe_run/stage" -mindepth 1 ! -type f 2>/dev/null)" ]; then
    wait "$p" 2>/dev/null
    status=1
    probe_why="staged something other than a plain file; a bookmark is one flat file"
    : > "$probe_run/out"
  else
    # A probe killed by a signal makes bash report it on stderr, which is the wake's text.
    wait "$p" 2>/dev/null
    status=$?
    probe_why=$(grep . "$probe_run/err" 2>/dev/null | tail -n 1 | cut -c 1-300)
    probe_why=${probe_why#probe failing: }
    probe_why=${probe_why:-exit $status with no message}
    probe_commit=1
  fi
  probe_pid=""
  trap - TERM HUP INT
  if [ -s "$probe_run/out" ]; then
    probe_news=$(head -c "$probe_out_max" "$probe_run/out")
    if [ "$(wc -c < "$probe_run/out")" -gt "$probe_out_max" ]; then
      cp "$probe_run/out" "$probe_dir/last-output"
      probe_news="$probe_news
(cut at $probe_out_max bytes; the whole output is in $probe_dir/last-output)"
    fi
  fi
  # The same words with no bookmark to move is a probe repeating itself: the holder has heard it.
  if [ -n "$probe_news" ] && [ "$(printf '%s' "$probe_news" | cksum)" = "$(cat "$probe_dir/told" 2>/dev/null)" ] &&
    ! stage_moves; then
    probe_news=""
  fi
  if [ "$status" = 0 ]; then
    rm -f "$probe_dir/failures"
    return 0
  fi
  { read -r fails < "$probe_dir/failures"; } 2>/dev/null
  case $fails in '' | *[!0-9]*) fails=0 ;; esac
  fails=$((fails + 1))
  echo "$fails" > "$probe_dir/failures"
  [ "$fails" -ge "$probe_fail_at" ] || return 0
  # At most one alert an hour, kept across successes, so a probe that fails and recovers by turns cannot loop.
  if [ ! -e "$probe_dir/alerted" ] || [ -n "$(find "$probe_dir/alerted" -mmin +60 2>/dev/null)" ]; then
    probe_alert="probe failing: $probe_why ($fails runs in a row; at most one such alert an hour)"
  fi
}
commit_probe() {
  local f
  [ -n "$probe_run" ] || return 0
  if [ -n "$probe_news" ]; then printf '%s' "$probe_news" | cksum > "$probe_dir/told"; fi
  if [ -n "$probe_alert" ]; then printf '%s\n' "$probe_why" > "$probe_dir/alerted"; fi
  if [ -n "$probe_commit" ]; then
    for f in "$probe_run/stage"/* "$probe_run/stage"/.[!.]*; do
      if [ -e "$f" ]; then mv -f "$f" "$probe_dir/bookmarks/"; fi
    done
  fi
  rm -rf "$probe_run"
  probe_run=""
}

while is_holder "$reg" "$record"; do
  if orphaned "$$" "$PPID"; then exit 0; fi
  # Only the lock's owner watches: a watch that lost it leaves, and one whose lock vanished takes it back.
  if [ "$(watch_owner)" != "$$" ] && ! take_watch; then exit 0; fi
  now=$(cd "$cwd" 2>/dev/null && "$(dirname "$0")/waiting.sh" --blocked 2>/dev/null | grep '^=== ')
  new=$(printf '%s\n' "$now" | grep -vxF -f "$reported" | grep .)
  probe_news="" probe_alert="" probe_run=""
  probe=$(jq -r '.probe.command // empty' "$record" 2>/dev/null)
  if [ -n "$probe" ]; then
    every=$(jq -r '.probe.every // 60 | floor' "$record" 2>/dev/null)
    last=$(cat "$probe_dir/last" 2>/dev/null)
    case $last in '' | *[!0-9]*) last=0 ;; esac
    # The interval holds across watches, so a busy source wakes the holder at most once per interval.
    if [ "$(( $(date +%s) - last ))" -ge "${every:-60}" ]; then
      run_probe "$probe"
      # A run can take minutes: what it found is this holder's to hear only if the role and the watch are still its.
      if ! is_holder "$reg" "$record" || [ "$(watch_owner)" != "$$" ] || orphaned "$$" "$PPID"; then
        rm -rf "$probe_run"
        exit 0
      fi
      # And only if it is still the role's probe: a run of the one just replaced or removed tells nothing.
      if [ "$(jq -r '.probe.command // empty' "$record" 2>/dev/null)" != "$probe" ]; then
        rm -rf "$probe_run"
        rm -f "$probe_dir/failures" "$probe_dir/told"
        probe_news="" probe_alert=""
      fi
      # Nothing to tell, so nothing a bookmark could pass unheard.
      if [ -z "$probe_news" ] && [ -z "$probe_alert" ]; then commit_probe; fi
    fi
  fi
  if [ -n "$new" ] || [ -n "$probe_news" ] || [ -n "$probe_alert" ]; then
    if [ -n "$new" ]; then
      # Append only, so a scan that misses a block cannot make it new again. A block that clears and returns has a
      # new start time in its header, so it is still reported.
      printf '%s\n' "$new" >> "$reported"
      tail -n "$reported_keep" "$reported" > "$reported.tmp" && mv "$reported.tmp" "$reported"
    fi
    {
      if [ -n "$new" ]; then
        echo "Anderton watch: a session you answer for is blocked on a person. Nothing has been answered or approved."
        printf '%s\n' "$new"
        echo "Run waiting.sh to see what each one is asking."
      fi
      if [ -n "$probe_news" ]; then
        echo "Anderton watch: your probe found something new. Nothing has been answered or approved."
        printf '%s\n' "$probe_news"
      fi
      if [ -n "$probe_alert" ]; then
        echo "Anderton watch: $probe_alert. What it watches is not being checked; nothing new is not a quiet day."
      fi
    } >&2
    commit_probe
    exit 2
  fi
  if [ "$(( $(date +%s) - started ))" -ge "$renew" ]; then
    echo "Anderton watch: renewing before Claude Code's time limit on this watch. Nothing is new; end your turn and it starts again." >&2
    exit 2
  fi
  sleep "$tick"
done
exit 0
