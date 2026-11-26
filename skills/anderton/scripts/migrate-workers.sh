#!/usr/bin/env bash
# One run settles the worker records written before session identities were recorded. claim.sh, adopt.sh, retire.sh
# and the sweeps tell a session is a worker only by an identity its record holds: a Claude session id or process (pid
# and start time together), a Codex thread, an agy instance. A record with none cannot be told apart from any session,
# so in its repository every claim, adoption and rebind refuses until this stamps it with its live session's identity,
# or marks it as naming none.
# usage: migrate-workers.sh [--dry-run | --apply]
#   --dry-run, the default, prints what each record would get and changes nothing: no file, lock or daemon.
#   --apply stamps or marks each record under its repository's lock and its worker lock, after reading it again there.
# Only unambiguous evidence stamps a record; anything else is printed and left for a person. A second run changes nothing
# the first settled. It removes no record and no worktree: retire.sh does that, behind its own checks.
# Exit 0: nothing is left for a person. 1: something is, or a record could not be written. 2: bad usage.
# Portable to macOS's bash 3.2 and BSD userland.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

require_tools migrate-workers.sh
apply=""
case "${1:-}:$#" in
  :0 | --dry-run:1) ;;
  --apply:1) apply=1 ;;
  *) echo "usage: migrate-workers.sh [--dry-run | --apply]" >&2; exit 2 ;;
esac
# git status refreshes a checkout's index unless told not to, which a dry run must not do.
export GIT_OPTIONAL_LOCKS=0

# The one transcript file of Claude session $1, or nothing.
transcript_of() {
  local found="" f
  case $1 in '' | *[!a-zA-Z0-9-]*) return 0 ;; esac
  for f in "$home"/projects/*/"$1.jsonl"; do
    [ -f "$f" ] || continue
    [ -z "$found" ] || return 0
    found=$f
  done
  if [ -n "$found" ]; then printf '%s\n' "$found"; fi
}

# True when Claude session $1, as process $2, holds a role in repository $3, or a claim there names its session.
holds_role() {
  local r
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    if is_holder "$sessions/$2.json" "$r" ||
      jq -e --arg sid "$1" '(.provider // "claude") == "claude" and .sessionId == $sid' "$r" >/dev/null 2>&1; then
      return 0
    fi
  done <<EOF
$(project_holders "$3")
EOF
  return 1
}

# What retire.sh would keep of record $1's worktree, said for the report.
work_note() {
  local dir work
  dir=$(jq -r '.dir // empty' "$1")
  if [ "$(jq -r '.worktree // false' "$1")" != true ] || [ ! -d "$dir" ]; then return 0; fi
  work=$(worktree_work "$dir" "$(jq -r '.base // empty' "$1")")
  case $work in
    '') printf '; its worktree %s has nothing retire.sh would keep' "$dir" ;;
    unreadable) printf '; git could not read its worktree %s, so retire.sh will keep it' "$dir" ;;
    *) printf '; its worktree %s has %s work, so retire.sh will keep it' "$dir" "$work" ;;
  esac
}

# The patch that marks record $1 as naming no session, for reason $2.
mark_patch() {
  jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg why "$1" '{migration: {at: $at, result: "names no session", why: $why}}'
}

# plan <record>: sets plan (ok, stamp, mark, register, leave), why, and patch, the JSON object merged into the record.
plan_claude() {
  local r=$1 dir launcher id root listed sid pid start reg count=0 live="" brief="" brief_id="" status=0 evidence="" now transcript
  dir=$(jq -r '.dir // empty' "$r") launcher=$(jq -r '.launcher // empty' "$r") id=$(jq -r '.id // empty' "$r")
  root=$(jq -r '.root // empty' "$r")
  if [ "$launcher" = bg ] && [ -n "$id" ]; then
    # A background launch is the session claude agents lists under the id claude --bg gave it.
    if ! listed=$(claude agents --json 2>/dev/null) || ! printf '%s' "$listed" | jq -e 'type == "array"' >/dev/null 2>&1; then
      plan=leave why="claude agents gave no listing to find background session $id in"
      return
    fi
    sid=$(printf '%s' "$listed" | jq -r --arg id "$id" '[.[] | select(.id == $id) | .sessionId // empty] | if length == 1 then .[0] else empty end')
    if [ -z "$sid" ]; then
      plan=mark why="claude agents lists no background session $id$(work_note "$r")" patch=$(mark_patch "no background session $id")
      return
    fi
    transcript=$(transcript_of "$sid")
    if [ -z "$transcript" ]; then plan=leave why="background session $id is session $sid, whose transcript is not found once"; return; fi
    plan=stamp why="background session $id, which claude agents lists as session $sid"
    patch=$(jq -nc --arg sid "$sid" --arg file "$transcript" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{claudeSession: {id: $sid, transcript: $file}, migration: {at: $at, result: "stamped", why: "its background id"}}')
    return
  fi
  if [ -z "$dir" ]; then plan=leave why="it names no checkout"; return; fi
  brief=$("$anderton_scripts/claude-worker.py" legacy-launch-transcript "$r" --home "$home" 2>/dev/null) || status=$?
  case $status in
    0) brief_id=$(printf '%s' "$brief" | jq -r .id) ;;
    3) brief="" ;;
    *) plan=leave why="its launch transcript could not be searched"; return ;;
  esac
  for reg in "$sessions"/*.json; do
    [ -f "$reg" ] || continue
    case $(jq -r '.cwd // empty' "$reg" 2>/dev/null) in "$dir" | "$dir"/*) ;; *) continue ;; esac
    pid=$(jq -r '.pid // empty' "$reg" 2>/dev/null)
    [ -n "$pid" ] || continue
    registered_alive "$pid" "$(jq -r '.startedAt // empty | floor' "$reg")" "$(jq -r '.procStart // empty' "$reg")" || continue
    count=$((count + 1))
    live=$reg
  done
  if [ "$count" -eq 0 ]; then
    if [ -n "$brief_id" ]; then
      transcript=$(printf '%s' "$brief" | jq -r .transcript)
      plan=mark why="no live session in $dir; its launch transcript, session $brief_id, is $transcript$(work_note "$r")"
      patch=$(mark_patch "no live session; its launch transcript is $transcript")
    else
      plan=mark why="no live session in $dir, and no one transcript opens with its launch brief$(work_note "$r")"
      patch=$(mark_patch "no live session, and no launch transcript")
    fi
    return
  fi
  if [ "$count" -gt 1 ]; then plan=leave why="$count live sessions run in $dir, so none is known to be the worker"; return; fi
  sid=$(jq -r '.sessionId // empty' "$live") pid=$(jq -r '.pid' "$live") start=$(proc_start "$pid")
  if [ -z "$sid" ] || [ -z "$start" ]; then plan=leave why="the live session in $dir has no session id or process start to record"; return; fi
  if [ "$sid" = "$brief_id" ]; then evidence="its transcript opens with this worker's launch brief"; fi
  now=$(claude_pane "$r")
  case $now in
    "session $sid") evidence="${evidence:+$evidence, and }herdr shows it in the worker's pane $(jq -r .pane "$r")" ;;
    "process "*) if has_ancestor "$pid" "${now#process }"; then evidence="${evidence:+$evidence, and }it runs in the worker's tmux pane $(jq -r .pane "$r")"; fi ;;
  esac
  if [ -z "$evidence" ]; then
    plan=leave why="one live session ($sid, pid $pid) runs in $dir, but neither its launch brief nor the worker's pane shows it is the worker"
    return
  fi
  if holds_role "$sid" "$pid" "$root"; then plan=leave why="the live session in $dir ($sid) holds an Anderton role"; return; fi
  reg=$(worker_record "$sid" "$pid")
  if [ -n "$reg" ] && [ "$reg" != "$r" ]; then plan=leave why="session $sid is already named by worker record $reg"; return; fi
  transcript=$(transcript_of "$sid")
  if [ -z "$transcript" ]; then plan=leave why="the transcript of live session $sid is not found once"; return; fi
  plan=stamp why="session $sid (pid $pid), the one live session in $dir: $evidence"
  patch=$(jq -nc --arg sid "$sid" --arg file "$transcript" --argjson pid "$pid" --arg start "$start" --arg why "$evidence" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson earlier "${brief:-null}" '
    {claudeSession: {id: $sid, transcript: $file, pid: $pid, procStart: $start},
     migration: {at: $at, result: "stamped", why: $why}}
    + if $earlier != null and $earlier.id != $sid then {claudePreviousSessions: [$earlier]} else {} end')
}

plan_adopted() {
  local r=$1 sid pid reg
  sid=$(jq -r '.sessionId // empty' "$r") pid=$(jq -r '.pid // empty' "$r")
  plan=ok why="adopted session $sid"
  [ -n "$pid" ] && [ -z "$(jq -r '.procStart // empty' "$r")" ] || return 0
  reg="$sessions/$pid.json"
  if [ "$(jq -r '.sessionId // empty' "$reg" 2>/dev/null)" = "$sid" ] &&
    registered_alive "$pid" "$(jq -r '.startedAt // empty | floor' "$reg")" "$(jq -r '.procStart // empty' "$reg")"; then
    plan=stamp why="adopted session $sid still runs as pid $pid: its process start is recorded beside it"
    patch=$(jq -nc --arg start "$(proc_start "$pid")" '{procStart: $start}')
  else
    why="adopted session $sid, named by its session id; its process no longer runs as pid $pid"
  fi
}

plan_codex() {
  local r=$1 home dir since token thread status=0
  home=$(jq -r '.codexHome // empty' "$r") dir=$(jq -r '.dir // empty' "$r") token=$(jq -r '.codexLaunchToken // empty' "$r")
  since=$(jq -r '.codexLaunchedAt // empty' "$r")
  if [ -z "$token" ]; then
    plan=leave why="no thread and no launch token: nothing can find its thread; retire it, or register it by hand"
    return
  fi
  plan=ok why="its launch waits for its thread; claim.sh and adopt.sh verify a thread by its launch token"
  if [ -z "$home" ] || [ -z "$since" ] || [ ! -S "$(codex_socket "$home")" ]; then return 0; fi
  thread=$("$anderton_scripts/codex-worker.py" find "$home" "$dir" --since "$since" --token "$token" 2>/dev/null) || status=$?
  if [ "$status" -eq 0 ] && [ -n "$thread" ]; then
    plan=register why="thread $thread, the one whose first message carries its launch token" patch=$thread
  fi
}

plan_agy() {
  local r=$1 pane socket dir out agent got cwd other
  pane=$(jq -r '.pane // empty' "$r") socket=$(jq -r '.socket // empty' "$r") dir=$(jq -r '.dir // empty' "$r")
  if [ -z "$pane" ] || [ -z "$socket" ]; then
    plan=mark why="it names no herdr pane$(work_note "$r")" patch=$(mark_patch "no herdr pane")
    return
  fi
  agy_check "$r"
  case $agy_state in
    gone) plan=mark why="its herdr pane $pane is gone$(work_note "$r")" patch=$(mark_patch "its pane is gone"); return ;;
    elsewhere) plan=mark why="its herdr pane $pane runs no agy in its checkout now$(work_note "$r")" patch=$(mark_patch "its pane runs no agy"); return ;;
    unidentified) ;;
    *) plan=leave why="herdr could not say what runs in pane $pane"; return ;;
  esac
  out=$(HERDR_SOCKET_PATH="$socket" herdr agent get "$pane" 2>/dev/null) || out=""
  IFS=$'\x1f' read -r agent got cwd <<EOF
$(printf '%s' "$out" | jq -r '(.result.agent // empty) | [.agent // "", (.agent_session.value // "" | tostring), .cwd // ""] | join("\u001f")' 2>/dev/null)
EOF
  if [ "$agent" != agy ] || [ -z "$got" ]; then plan=leave why="herdr shows an agy in pane $pane but not which instance"; return; fi
  for other in "$holders"/*.json "$holders"/workers/*.json; do
    if [ -f "$other" ] && [ "$other" != "$r" ] && jq -e --arg got "$got" --arg pane "$pane" '.provider == "agy" and
      (.agyInstance == $got or (.sessionId != null and .pane == $pane))' "$other" >/dev/null 2>&1; then
      plan=leave why="agy instance $got in pane $pane is also named by $other"
      return
    fi
  done
  plan=stamp why="agy instance $got, which herdr shows in its pane $pane, in $cwd"
  patch=$(jq -nc --arg got "$got" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{agyInstance: $got, migration: {at: $at, result: "stamped", why: "the agy herdr shows in its pane"}}')
}

plan() {
  plan="" why="" patch=""
  if ! jq -e 'type == "object"' "$1" >/dev/null 2>&1; then plan=leave why="it is not a JSON object"; return; fi
  if jq -e '.migration != null' "$1" >/dev/null 2>&1; then
    plan=ok why="settled by an earlier run: $(jq -r '.migration | "\(.result), \(.at)"' "$1")"
    return
  fi
  case $(record_provider "$1") in
    claude)
      if jq -e '.adopted == true' "$1" >/dev/null 2>&1; then plan_adopted "$1"
      elif unmigrated_worker "$1"; then plan_claude "$1"
      else plan=ok why="Claude session $(jq -r '.claudeSession.id // .claudeLaunchId' "$1")"; fi
      ;;
    codex)
      if [ -n "$(jq -r '.id // empty' "$1")" ]; then plan=ok why="Codex thread $(jq -r .id "$1")"; else plan_codex "$1"; fi
      ;;
    agy)
      if [ -n "$(jq -r '.agyInstance // empty' "$1")" ]; then plan=ok why="agy instance $(jq -r .agyInstance "$1")"; else plan_agy "$1"; fi
      ;;
    *) plan=leave why="its provider is not claude, codex or agy" ;;
  esac
}

# What the plan would write, without the time a patch records: a second read of the same record gives the same key.
plan_key() {
  printf '%s %s\n' "$plan" "$(printf '%s' "$patch" | jq -c 'del(.migration.at)' 2>/dev/null || printf '%s' "$patch")"
}

# Applies $plan to record $1 under its repository's lock and its worker lock, once the record plans the same there.
settle() {
  (
    local r=$1 expected updated
    expected=$(plan_key)
    take_repository_lock "$(jq -r '.root // empty' "$r")"
    lock_worker "$r" || exit 1
    plan "$r"
    if [ "$(plan_key)" != "$expected" ]; then
      echo "  it changed while it was read again; nothing written. Rerun." >&2
      exit 1
    fi
    if [ "$plan" = register ]; then
      bind_codex_worker "$r" "$patch" "$(jq -r '.codexLaunchToken' "$r")"
      exit
    fi
    updated=$(mktemp "$r.XXXXXX") || exit 1
    if jq --argjson patch "$patch" '. + $patch' "$r" >"$updated" && mv -f "$updated" "$r"; then exit 0; fi
    rm -f "$updated"
    exit 1
  )
}

count_ok=0 count_change=0 count_leave=0 failed=0
for r in "$holders"/workers/*.json; do
  [ -f "$r" ] || continue
  plan "$r"
  name=$(jq -r '.name // empty' "$r" 2>/dev/null || true)
  case $plan in
    ok)
      count_ok=$((count_ok + 1))
      printf '%s: identified: %s\n' "${name:-$r}" "$why"
      ;;
    leave)
      count_leave=$((count_leave + 1))
      printf '%s: left for a person: %s\n' "${name:-$r}" "$why"
      ;;
    *)
      count_change=$((count_change + 1))
      case $plan in stamp) verb="stamped with" ;; register) verb="registered to" ;; *) verb="marked as naming no session:" ;; esac
      if [ -n "$apply" ]; then
        if settle "$r"; then printf '%s: %s %s\n' "${name:-$r}" "$verb" "$why"
        else failed=1; printf '%s: not written (see above): would be %s %s\n' "${name:-$r}" "$verb" "$why"; fi
      else
        printf '%s: would be %s %s\n' "${name:-$r}" "$verb" "$why"
      fi
      ;;
  esac
done
if [ -n "$apply" ]; then done_word="changed"; else done_word="to change (dry run: nothing was written)"; fi
echo "$((count_ok + count_change + count_leave)) worker records: $count_ok identified, $count_change $done_word, $count_leave left for a person."
[ "$count_leave" -eq 0 ] && [ "$failed" -eq 0 ]
