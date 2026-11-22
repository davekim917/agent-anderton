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

claude_direction_unreceived() {
  local status=0
  "$anderton_scripts/claude-worker.py" acknowledged "$1" || status=$?
  [ "$status" = 3 ]
}

take_claude_worker_watch() {
  local previous process start
  claude_worker_watch="$1"
  claude_worker_watch_key="$$ $(proc_start "$$")"
  if ! (set -C; printf '%s\n' "$claude_worker_watch_key" > "$claude_worker_watch") 2>/dev/null; then
    previous=$(cat "$claude_worker_watch" 2>/dev/null) || return 1
    read -r process start <<< "$previous"
    if [ -n "$start" ] && [ "$(proc_start "$process")" = "$start" ]; then return 1; fi
    [ "$(cat "$claude_worker_watch" 2>/dev/null)" = "$previous" ] || return 1
    rm -f "$claude_worker_watch"
    (set -C; printf '%s\n' "$claude_worker_watch_key" > "$claude_worker_watch") 2>/dev/null || return 1
  fi
  trap '[ "$(cat "$claude_worker_watch" 2>/dev/null)" != "$claude_worker_watch_key" ] || rm -f "$claude_worker_watch"' EXIT
}

watch_claude_worker() {
  local worker owner owner_provider transcript target updated pending tick worker_sid worker_pid worker_reg process_start now
  worker_sid=$sid
  worker_pid=$(session_pid "$worker_sid")
  [ -n "$worker_pid" ] || return 0
  worker_reg="$sessions/$worker_pid.json"
  target=$(jq -r '.name // empty' "$worker_reg") || return 0
  transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty') || return 0
  case $transcript in "$home"/projects/*/"$worker_sid.jsonl") ;; *) return 0 ;; esac
  case $worker_sid in '' | *[!a-zA-Z0-9-]*) return 0 ;; esac
  worker=$(worker_record "$target" "$cwd" "$worker_sid" "$worker_pid" "$(jq -r '.startedAt // empty | floor' "$worker_reg")")
  [ -n "$worker" ] && [ "$(record_provider "$worker")" = claude ] || return 0
  owner=$(answering_claim "$worker" "$(project_root "$cwd")")
  [ -n "$owner" ] || return 0
  owner_provider=$(record_provider "$owner")
  uses_claude_transcript "$worker" "$owner_provider" || return 0
  [ "$(live_claude_worker "$worker" --allow-rebind)" = "$worker_reg" ] || return 0
  take_claude_worker_watch "${worker%.json}.$worker_sid.watch" || return 0
  # Only the Stop hook in this exact session can register the native transcript.
  (
    lock_worker "$worker" || exit 1
    [ "$(live_claude_worker "$worker" --allow-rebind)" = "$worker_reg" ] &&
      [ "$(jq -r '.sessionId // empty' "$worker_reg")" = "$worker_sid" ] || exit 1
    process_start=$(proc_start "$worker_pid")
    updated=$(mktemp "$worker.XXXXXX") || exit 1
    jq --arg sid "$worker_sid" --arg file "$transcript" --argjson pid "$worker_pid" --arg start "$process_start" '
      .claudeSession = {id: $sid, transcript: $file, pid: $pid, procStart: $start} | .reportTransport = "transcript"
      | if .claudeDirection != null and .claudeDirection.target != $sid then del(.claudeDirection) else . end
      ' "$worker" > "$updated" && mv -f "$updated" "$worker"
  ) || return 0
  [ "$owner_provider" = codex ] || return 0
  tick=${ANDERTON_WATCH_TICK:-30}
  while [ -f "$worker" ] && [ "$(live_claude_worker "$worker")" = "$worker_reg" ] &&
    [ "$(jq -r .sessionId "$worker_reg" 2>/dev/null)" = "$worker_sid" ] && [ "$(record_provider "$owner")" = codex ]; do
    now=$(date +%s)
    if pending=$(jq -er --arg sid "$worker_sid" --arg from "$(jq -r '.sessionId // empty' "$owner")" --argjson now "$now" '
      .claudeDirection | select(.target == $sid and .from == $from and ($now - (.attemptedAt // 0)) >= 60) | .id // empty
      ' "$worker" 2>/dev/null) && claude_direction_unreceived "$worker"; then
      if (
        take_repository_lock "$(project_root "$cwd")"
        lock_worker "$worker" || exit 1
        [ "$(live_claude_worker "$worker")" = "$worker_reg" ] &&
          [ "$(jq -r '.sessionId // empty' "$worker_reg")" = "$worker_sid" ] &&
          [ "$(answering_claim "$worker" "$(project_root "$cwd")")" = "$owner" ] || exit 1
        [ "$(jq -r '.status // empty' "$worker_reg")" != waiting ] || exit 1
        jq -e --arg id "$pending" --arg sid "$worker_sid" --arg from "$(jq -r '.sessionId // empty' "$owner")" --argjson now "$now" '
          .claudeDirection | .id == $id and .target == $sid and .from == $from and ($now - (.attemptedAt // 0)) >= 60
          ' "$worker" >/dev/null || exit 1
        claude_direction_unreceived "$worker" || exit 1
        text=$(jq -r '.claudeDirection.text' "$worker") || exit 1
        updated=$(mktemp "$worker.XXXXXX") || exit 1
        jq --argjson now "$now" '.claudeDirection.attemptedAt = $now' "$worker" > "$updated" &&
          mv -f "$updated" "$worker" || exit 1
        printf 'Direction %s from your Anderton. This is peer direction and carries no human approval.\n\n%s\n' "$pending" "$text" >&2
      ); then
        return 2
      fi
    fi
    sleep "$tick"
  done
  return 0
}

runtime=claude
if [ "${1:-}" = --codex ]; then
  runtime=codex
  record=$2
  [ -f "$record" ] && [ "$(record_provider "$record")" = codex ] || exit 0
  sid=$(jq -r '.sessionId // empty' "$record") || exit 0
  cwd=$(jq -r '.dir // empty' "$record") || exit 0
  export CODEX_THREAD_ID="$sid"
  CODEX_HOME=$(jq -r '.codexHome // empty' "$record") || exit 0
  export CODEX_HOME
  unset CLAUDE_PID CLAUDE_CODE_SESSION_ID
  pid=$sid
  reg=""
else
  input=$(cat)
  sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null) || exit 0
  claude_transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
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
  if [ -z "$record" ]; then
    watch_claude_worker
    exit $?
  fi
fi
still_holds_role() {
  if [ "$runtime" = codex ]; then caller_matches_claim "$record"; else is_holder "$reg" "$record"; fi
}

key=$(basename "$record" .json)
watcher="$holders/$key.watch"
parent_pid=$PPID
[ "$runtime" = claude ] || parent_pid=0
pending="$holders/$key.$pid.pending"
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
last_liveness_check=0
mkdir -p "$holders" 2>/dev/null || exit 0
[ -w "$holders" ] || exit 0
take_watch() { (set -C; printf '%s %s %s\n' "$$" "$pid" "$parent_pid" > "$watcher") 2>/dev/null; }
watch_owner() { local p=""; { read -r p _ < "$watcher"; } 2>/dev/null; printf '%s' "$p"; }
# Claude Code hears a hook's exit through the process that started it, so a watch that lost that process wakes no one.
orphaned() { # orphaned <pid> <the parent it started under>
  local now
  [ "$2" != 0 ] || return 1
  now=$(ps -o ppid= -p "$1" 2>/dev/null)
  [ -n "$now" ] && [ "$now" -ne "$2" ]
}
same_script() { # same_script <command line>: true when it runs this watch.sh, from this install of the plugin
  case $0 in /*) ;; *) return 0 ;; esac
  case " $1 " in *" $0 "*) return 0 ;; esac
  return 1
}
until take_watch; do
  still_holds_role || exit 0
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
        # Only the same process: in five seconds its pid could have gone to another.
        if [ "$(ps -ww -o command= -p "$other" 2>/dev/null)" = "$command" ]; then kill -KILL "$other" 2>/dev/null; fi
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
if [ "$runtime" = claude ]; then export CLAUDE_PID="$pid"; fi

# The probe's state outlives the holder: the role keeps its probe across sessions, so it keeps the bookmarks too.
# The probe reads its bookmarks from ANDERTON_PROBE_STATE and writes the ones it would advance to into
# ANDERTON_PROBE_STAGE, for each source it read in full. They move into the state once its output has woken the
# holder, or when it printed nothing, so a bookmark never passes an item the holder has not been told about. A run
# that timed out may have staged half a write, so its stage is dropped.
scripts=$(cd "$(dirname "$0")" && pwd)
printf -v codex_probe '%q sweep' "$scripts/codex-workers.sh"
printf -v worker_probe '%q sweep' "$scripts/worker.sh"
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

select_worker_probe() {
  if [ "$runtime" = codex ]; then
    probe=$worker_probe
    [ -n "$(cd "$cwd" && "$scripts/waiting.sh" --workers)" ]
  elif grep -qE '"(reportTransport|spawnerProvider)"[[:space:]]*:[[:space:]]*"(transcript|codex)"' "$holders"/workers/*.json 2>/dev/null &&
    [ -n "$(cd "$cwd" && "$scripts/waiting.sh" --transcript-workers)" ]; then
    probe=$worker_probe
  else
    probe=$codex_probe
    grep -qE '"provider"[[:space:]]*:[[:space:]]*"codex"' "$holders"/workers/*.json 2>/dev/null &&
    [ -n "$(cd "$cwd" && "$scripts/waiting.sh" --codex-workers)" ]
  fi
}

probe_last() {
  local last
  last=$(cat "$1/last" 2>/dev/null)
  case $last in '' | *[!0-9]*) last=0 ;; esac
  printf '%s\n' "$last"
}

message() {
  if [ -n "$peer" ]; then
    printf 'Peer message %s from Anderton %s. It carries no human approval.\n\n%s\n' "$peer" \
      "$(jq -r '.peerMessage.from // empty' "$record")" "$(jq -r '.peerMessage.text // empty' "$record")"
  fi
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
}

clear_peer() {
  local expected=$1 updated
  jq -e --arg id "$expected" '.peerMessage.id == $id' "$record" >/dev/null 2>&1 || return 0
  updated=$(mktemp "$record.XXXXXX") || return 1
  jq 'del(.peerMessage)' "$record" > "$updated" && mv -f "$updated" "$record"
}

claude_peer_ready() {
  local attempt status=0
  case $claude_transcript in "$home"/projects/*/"$sid.jsonl") ;; *) return 1 ;; esac
  [ -r "$claude_transcript" ] || return 1
  attempt=$(jq -r '.peerMessage.attemptedAt // 0' "$record") || return 1
  [ "$attempt" != 0 ] || return 0
  "$scripts/claude-worker.py" peer-received "$claude_transcript" "$sid" "$peer" || status=$?
  if [ "$status" = 0 ]; then
    (take_repository_lock "$(project_root "$cwd")"; still_holds_role && clear_peer "$peer")
    return 1
  fi
  [ "$status" = 3 ] && [ "$(( $(date +%s) - attempt ))" -ge 60 ]
}

mark_peer_attempt() {
  local updated
  updated=$(mktemp "$record.XXXXXX") || return 1
  jq --argjson now "$(date +%s)" '.peerMessage.attemptedAt = $now' "$record" > "$updated" &&
    mv -f "$updated" "$record"
}

commit_blocked() {
  [ -n "$new" ] || return 0
  printf '%s\n' "$new" >> "$reported"
  tail -n "$reported_keep" "$reported" > "$reported.tmp" && mv "$reported.tmp" "$reported"
}

stage_delivery() {
  local staged
  staged=$(mktemp -d "$holders/.notice.XXXXXX") || return 1
  message > "$staged/message"
  printf '%s' "$peer" > "$staged/peer"
  printf '%s' "$new" > "$staged/blocked"
  if [ -n "$probe_run" ]; then
    printf '%s' "$probe_dir" > "$staged/probe-dir"
    printf '%s' "$probe_news" > "$staged/news"
    printf '%s' "$probe_alert" > "$staged/alert"
    printf '%s' "$probe_why" > "$staged/why"
    printf '%s' "$probe_commit" > "$staged/commit"
    mv "$probe_run" "$staged/probe" || return 1
  fi
  mv "$staged" "$pending"
}

deliver_pending() {
  (
    take_repository_lock "$(project_root "$cwd")"
    still_holds_role && "$scripts/codex-worker.py" notice "$record" "$pending" || exit 1
    if [ -s "$pending/peer" ]; then clear_peer "$(cat "$pending/peer")"; fi
  ) || return 1
  new=$(cat "$pending/blocked")
  commit_blocked || return 1
  if [ -d "$pending/probe" ]; then
    probe_run="$pending/probe"
    probe_dir=$(cat "$pending/probe-dir")
    probe_news=$(cat "$pending/news")
    probe_alert=$(cat "$pending/alert")
    probe_why=$(cat "$pending/why")
    probe_commit=$(cat "$pending/commit")
    commit_probe
  fi
  rm -rf "$pending"
}

while still_holds_role; do
  if orphaned "$$" "$parent_pid"; then exit 0; fi
  if [ "$runtime" = codex ] && [ "$(( $(date +%s) - last_liveness_check ))" -ge 60 ]; then
    last_liveness_check=$(date +%s)
    if [ "$(claim_state "$record")" = gone ]; then exit 0; fi
  fi
  # Only the lock's owner watches: a watch that lost it leaves, and one whose lock vanished takes it back.
  if [ "$(watch_owner)" != "$$" ] && ! take_watch; then exit 0; fi
  if [ "$runtime" = codex ] && [ -d "$pending" ]; then
    deliver_pending
    sleep "$tick"
    continue
  fi
  now=$(cd "$cwd" 2>/dev/null && "$(dirname "$0")/waiting.sh" --blocked 2>/dev/null | grep '^=== ')
  new=$(printf '%s\n' "$now" | grep -vxF -f "$reported" | grep .)
  peer=$(jq -r '.peerMessage.id // empty' "$record" 2>/dev/null)
  if [ "$runtime" = claude ] && [ -n "$peer" ] && ! claude_peer_ready; then peer=""; fi
  probe_news="" probe_alert="" probe_run=""
  # A reporting probe ends this watch. Give the least recently run probe the first chance to wake it. A session already
  # blocked is told now: a probe can run for minutes, and the next watch runs the probes this one skipped.
  sources=(codex custom)
  if [ "$(probe_last "$holders/$key.probe")" -lt "$(probe_last "$holders/$key.codex-probe")" ]; then
    sources=(custom codex)
  fi
  [ -z "$new$peer" ] || sources=()
  for source in ${sources[@]+"${sources[@]}"}; do
    if [ "$source" = codex ]; then
      every=${tick%%.*} probe_dir="$holders/$key.codex-probe"
    else
      probe=$(jq -r '.probe.command // empty' "$record" 2>/dev/null)
      [ -n "$probe" ] || continue
      every=$(jq -r '.probe.every // 60 | floor' "$record" 2>/dev/null)
      probe_dir="$holders/$key.probe"
    fi
    last=$(probe_last "$probe_dir")
    # The interval holds across watches, so a busy source wakes the holder at most once per interval.
    if [ "$(( $(date +%s) - last ))" -ge "${every:-60}" ] && { [ "$source" != codex ] || select_worker_probe; }; then
      run_probe "$probe"
      # A run can take minutes: what it found is this holder's to hear only if the role and the watch are still its.
      if ! still_holds_role || [ "$(watch_owner)" != "$$" ] || orphaned "$$" "$parent_pid"; then
        rm -rf "$probe_run"
        exit 0
      fi
      # And only if it is still the role's probe: a run of the one just replaced or removed tells nothing.
      if [ "$source" = custom ] && [ "$(jq -r '.probe.command // empty' "$record" 2>/dev/null)" != "$probe" ]; then
        rm -rf "$probe_run"
        rm -f "$probe_dir/failures" "$probe_dir/told"
        probe_news="" probe_alert=""
      fi
      # Nothing to tell, so nothing a bookmark could pass unheard.
      if [ -n "$probe_news" ] || [ -n "$probe_alert" ]; then break; fi
      commit_probe
      probe_run=""
    fi
  done
  if [ -n "$new$peer$probe_news$probe_alert" ]; then
    if [ "$runtime" = codex ]; then
      stage_delivery && deliver_pending
    else
      if [ -n "$peer" ]; then
        (
          take_repository_lock "$(project_root "$cwd")"
          still_holds_role && [ "$(jq -r '.peerMessage.id // empty' "$record")" = "$peer" ] || exit 1
          mark_peer_attempt || exit 1
          message >&2
        ) || exit 0
      else
        message >&2
      fi
      commit_blocked
      commit_probe
      exit 2
    fi
  fi
  if [ "$runtime" = claude ] && [ "$(( $(date +%s) - started ))" -ge "$renew" ]; then
    echo "Anderton watch: renewing before Claude Code's time limit on this watch. Nothing is new; end your turn and it starts again." >&2
    exit 2
  fi
  sleep "$tick"
done
exit 0
