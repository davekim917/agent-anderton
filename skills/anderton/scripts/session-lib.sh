# shellcheck shell=bash
# Sourced by claim.sh and waiting.sh. Bash 3.2 and BSD userland: POSIX ps fields only.

# Seconds since process $1 started, from POSIX `ps -o etime` ([[dd-]hh:]mm:ss); nothing when it is gone.
proc_age() {
  local t d=0 h=0 m s a b c
  t=$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ') || true
  case $t in '' | *[!0-9:-]*) return 0 ;; esac
  case $t in *-*) d=${t%%-*}; t=${t#*-} ;; esac
  IFS=: read -r a b c <<EOF
$t
EOF
  if [ -n "$c" ]; then h=$a m=$b s=$c; else m=$a s=$b; fi
  echo $(( ((10#$d * 24 + 10#$h) * 60 + 10#$m) * 60 + 10#$s ))
}

# The start of process $1 in the form Claude Code records as procStart: field 22 of /proc/<pid>/stat
# where /proc exists, else ps lstart in the C locale and UTC. Nothing when it is gone.
proc_start() {
  local t
  if [ -r "/proc/$1/stat" ]; then
    t=$(cat "/proc/$1/stat" 2>/dev/null) || return 0
    # The command name in field 2 can hold spaces and parentheses; field 3 follows its last ")".
    printf '%s\n' "${t##*) }" | awk '{ print $20 }'
    return 0
  fi
  t=$(LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null) || return 0
  t=${t#"${t%%[![:space:]]*}"}
  printf '%s\n' "${t%"${t##*[![:space:]]}"}"
}

process_start_matches() {
  [ -n "$2" ] && [ "$(proc_start "$1")" = "$2" ]
}

# True when pid $1 is running and is the process the session registry names: its start equals the
# entry's procStart ($3) when it has one, else started when the entry's startedAt ($2, epoch ms) says.
# A registry file outlives a crashed session, and its pid can then belong to an unrelated process.
# /restart keeps the process but writes a new startedAt, so procStart, when present, decides alone.
# ps, not kill -0: a sandboxed shell can be denied signalling a live process (EPERM).
registered_alive() {
  local age drift
  age=$(proc_age "$1")
  [ -n "$age" ] || return 1
  if [ -n "${3:-}" ]; then
    process_start_matches "$1" "$3"
    return
  fi
  [ -n "$2" ] || return 0
  drift=$(( $(date +%s) - age - $2 / 1000 ))
  [ "$drift" -ge -60 ] && [ "$drift" -le 60 ]
}

# Exits unless jq, git and a ps that reports elapsed time are present. Without git every worktree
# would be its own project, and without etime (busybox ps, for one) every session would read as gone,
# so any claim would succeed.
require_tools() {
  local tool missing=""
  for tool in jq git; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  if [ -n "$missing" ]; then
    echo "$1 needs:$missing. Install with brew or your package manager, and rerun." >&2
    exit 1
  fi
  [ -n "$(proc_age $$)" ] || {
    echo "$1 needs a POSIX ps that supports: ps -o etime= -p <pid>" >&2
    exit 1
  }
}

home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
sessions="$home/sessions"
holders="$home/anderton"
legacy_holder="$home/anderton.json"
anderton_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

invoking_provider() {
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}${CLAUDE_PID:-}" ]; then printf 'claude\n'
  elif [ -n "${CODEX_THREAD_ID:-}" ]; then printf 'codex\n'
  else printf 'claude\n'; fi
}

invoking_session() {
  case $(invoking_provider) in
    codex) printf '%s\n' "${CODEX_THREAD_ID:-}" ;;
    *) printf '%s\n' "${CLAUDE_CODE_SESSION_ID:-}" ;;
  esac
}

invoking_pid() {
  if [ "$(invoking_provider)" = claude ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}${CLAUDE_PID:-}" ]; then
    printf '%s\n' "${CLAUDE_PID:-$(session_pid "${CLAUDE_CODE_SESSION_ID:-}")}"
  fi
}

invoking_codex_home() {
  (cd "${CODEX_HOME:-$HOME/.codex}" && pwd -P) 2>/dev/null
}

# An optional Codex account helper: $ANDERTON_CODEX_ACCOUNTS, else codex-accounts on PATH. `--start-home` with
# CODEX_HOME set prints the home a new session from that home starts on. `--move-thread <id> --message <text>` with
# CODEX_HOME set to a thread's home marks that account limited and prints the next home reading the same conversation
# store, where the thread resumes as it is; it exits non-zero when no account may take the thread, or a codex still
# has it open. Anderton runs a session on whatever home the
# helper prints, so the helper must print only a home that runs the same hook guards. Without a helper every session
# keeps its home.
codex_accounts() {
  local helper=${ANDERTON_CODEX_ACCOUNTS:-}
  if [ -z "$helper" ]; then helper=$(command -v codex-accounts 2>/dev/null) || return 1; fi
  [ -x "$helper" ] && printf '%s\n' "$helper"
}

codex_socket() {
  printf '%s/app-server-control/app-server-control.sock\n' "$1"
}

# The home a new Codex session from home $1 starts on, judged under the codex options after it: the account helper's
# choice, else $1.
codex_start_home() {
  local helper start from=$1
  shift
  # --same-store: a session started here may later move or resume, so only a home on $1's conversation store is named.
  if helper=$(codex_accounts) && start=$(CODEX_HOME=$from "$helper" --start-home --same-store -- "$@" </dev/null 2>/dev/null) &&
    start=$(cd "$start" 2>/dev/null && pwd -P); then
    printf '%s\n' "$start"
  else
    (cd "$from" && pwd -P)
  fi
}

# The home that last ran Codex thread $1, by the account helper: where a claim whose move was interrupted belongs.
# Fails when there is no helper, or it cannot say (no such thread, an older helper).
codex_thread_home() {
  local helper home
  helper=$(codex_accounts) || return 1
  home=$("$helper" --locate-thread "$1" </dev/null 2>/dev/null) || return 1
  (cd "$home" 2>/dev/null && pwd -P)
}

# Stops the watch of claim $1, if one runs, and waits until it has let go of the job: a watch for the same thread on
# another home would otherwise leave on finding it held. TERM runs the watch's EXIT trap, which a sleep between ticks
# delays; one that outlives that is killed and its job file removed.
stop_codex_watch() {
  local watcher pid owner command waited=0 limit=$(( ${ANDERTON_WATCH_TICK:-30} + 15 ))
  watcher="$holders/$(basename "$1" .json).watch"
  { read -r pid _ <"$watcher"; } 2>/dev/null || return 0
  command=$(ps -ww -o command= -p "$pid" 2>/dev/null) || return 0
  case $command in *watch.sh*) ;; *) return 0 ;; esac
  kill -TERM "$pid" 2>/dev/null || return 0
  while [ "$waited" -lt "$limit" ] && kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
  done
  if [ "$(ps -ww -o command= -p "$pid" 2>/dev/null)" = "$command" ]; then kill -KILL "$pid" 2>/dev/null; fi
  { read -r owner _ <"$watcher"; } 2>/dev/null && [ "$owner" = "$pid" ] && rm -f "$watcher"
  return 0
}

# Points claim or worker record $1 at home $2, atomically; the caller holds the repository lock.
set_codex_home() {
  local updated
  updated=$(mktemp "$1.XXXXXX") || return 1
  if jq --arg home "$2" '.codexHome = $home' "$1" >"$updated" && mv -f "$updated" "$1"; then return 0; fi
  rm -f "$updated"
  return 1
}

# Gives back the repository lock while this script keeps working; a worker lock it holds stays.
release_repository_lock() {
  if [ -n "${repository_directory_lock:-}" ]; then
    rm -f -- "$repository_directory_lock/pid"
    rmdir -- "$repository_directory_lock"
    repository_directory_lock=""
  fi
  exec 9>&-
}

# Starts the Codex daemon of home $1 unless its socket is there, waiting up to 10 seconds for it.
codex_daemon_up() {
  local socket tries=20
  socket=$(codex_socket "$1")
  [ -S "$socket" ] && return 0
  # The daemon outlives this script: it must not inherit the repository lock's descriptor.
  CODEX_HOME=$1 codex app-server daemon start </dev/null >/dev/null 2>&1 9>&- || return 1
  while [ "$tries" -gt 0 ]; do
    [ -S "$socket" ] && return 0
    tries=$((tries - 1))
    sleep 0.5
  done
  return 1
}

# The Codex worker's pane (launcher $1, socket $2, pane id $3, tmux server pid $4), wherever it now lives:
# "present <title>", gone, or unknown. A tmux pane id counts only in the server process it was opened in, since a
# restarted server reuses ids.
codex_pane() {
  local out
  case $1 in
    herdr)
      out=$(HERDR_SOCKET_PATH="$2" herdr pane get "$3" 2>&1) || true
      printf '%s' "$out" | jq -r 'if .error.code == "pane_not_found" or .error.code == "server_not_running" then "gone"
        elif (.result.pane.terminal_title | type) == "string" then "present " + .result.pane.terminal_title else "unknown" end' \
        2>/dev/null || echo unknown
      ;;
    tmux)
      if out=$(tmux -S "$2" list-panes -a -F '#{pid} #{pane_id} #{pane_title}' 2>&1); then
        printf '%s\n' "$out" | awk -v p="$4" -v id="$3" '
          $1 == p && $2 == id { sub(/^[^ ]* [^ ]* ?/, ""); print "present " $0; f = 1; exit }
          END { if (!f) print "gone" }'
      else
        case $out in *"no server running"* | *"No such file or directory"*) echo gone ;; *) echo unknown ;; esac
      fi
      ;;
    *) echo unknown ;;
  esac
}

# True when codex_pane's answer $1 is the pane titled as Codex titles thread $2: its id cut to 29 characters and
# "...", after "Action Required | " while it waits on the user.
shows_thread() {
  [ ${#2} -ge 29 ] || return 1
  case $1 in "present $(printf '%.29s' "$2")..." | "present "*" | $(printf '%.29s' "$2")...") return 0 ;; esac
  return 1
}

record_provider() {
  jq -er '.provider // "claude"' "$1" 2>/dev/null
}

caller_matches_claim() {
  local p codex
  [ -f "$1" ] && [ "$(record_provider "$1")" = "$(invoking_provider)" ] || return 1
  if [ "$(invoking_provider)" = codex ]; then
    # The claim names the conversation and the home it runs on: the same thread opened on another account's home does
    # not hold it until codex-anderton.sh --move hands the claim over.
    codex=$(invoking_codex_home) || return 1
    jq -e --arg sid "${CODEX_THREAD_ID:-}" --arg codex "$codex" '
      $sid != "" and .sessionId == $sid and .codexHome == $codex' "$1" >/dev/null 2>&1
  else
    p=$(invoking_pid)
    [ -n "$p" ] && is_holder "$sessions/$p.json" "$1"
  fi
}

caller_claim() {
  local record
  while IFS= read -r record; do
    if [ -n "$record" ] && caller_matches_claim "$record"; then
      printf '%s\n' "$record"
      return
    fi
  done <<EOF
$(project_holders "$1")
EOF
}

# A Codex thread remains resumable while the server is down or the thread is unloaded.
claim_state() {
  local p state
  case $(record_provider "$1") in
    claude)
      p=$(jq -r '.pid // empty' "$1" 2>/dev/null)
      if [ -n "$p" ] && is_holder "$sessions/$p.json" "$1"; then echo live; else echo gone; fi ;;
    codex)
      if state=$("$anderton_scripts/codex-worker.py" claim-state "$1" 2>/dev/null); then echo "$state"
      else echo unknown; fi ;;
    *) echo unknown ;;
  esac
}

claim_name() {
  local p
  if [ "$(record_provider "$1")" = codex ]; then
    jq -r '.name // .sessionId // empty' "$1" 2>/dev/null
  else
    p=$(jq -r '.pid // empty' "$1" 2>/dev/null)
    jq -r '.name // empty' "$sessions/$p.json" 2>/dev/null || true
  fi
}

answering_claim() {
  local worker=$1 root=$2 main r scope spawner spawner_session spawner_provider by
  main=$(holder_record "$root")
  if jq -e 'has("spawnerScope")' "$worker" >/dev/null 2>&1; then
    scope=$(jq -r '.spawnerScope // empty' "$worker")
    if [ -n "$scope" ]; then
      r=$(holder_record "$root" "$scope")
      if [ -n "$r" ] && [ "$(claim_state "$r")" != gone ]; then printf '%s\n' "$r"; return; fi
    fi
  else
    spawner=$(jq -r '.spawner // empty' "$worker" 2>/dev/null || true)
    spawner_session=$(jq -r '.spawnerSession // empty' "$worker" 2>/dev/null || true)
    spawner_provider=$(jq -r '.spawnerProvider // "claude"' "$worker" 2>/dev/null || true)
    for by in ${spawner_session:+session} ${spawner:+name}; do
      while IFS= read -r r; do
        if [ -z "$r" ] || [ "$r" = "$main" ] || [ "$(record_provider "$r")" != "$spawner_provider" ]; then continue; fi
        case $by in
          session) [ "$(jq -r '.sessionId // empty' "$r" 2>/dev/null || true)" = "$spawner_session" ] ;;
          name) [ "$(claim_name "$r")" = "$spawner" ] ;;
        esac || continue
        if [ "$(claim_state "$r")" != gone ]; then printf '%s\n' "$r"; return; fi
      done <<EOF
$(project_holders "$root")
EOF
    done
  fi
  printf '%s\n' "$main"
}

worker_belongs() {
  jq -e --arg root "$2" '.root == $root' "$1" >/dev/null 2>&1 &&
    [ -n "$3" ] && [ "$(answering_claim "$1" "$2")" = "$3" ]
}

uses_claude_transcript() {
  jq -e --arg owner "$2" '(.provider // "claude") == "claude" and
    ($owner == "codex" or .reportTransport == "transcript" or .spawnerProvider == "codex")' "$1" >/dev/null 2>&1
}

# Call under the repository lock. Only a conclusive mismatch clears a candidate pending launch.
codex_worker_record() {
  local codex=$1 thread=$2 dir=$3 exclude=${4:-} r kind status
  for r in "$holders"/workers/*.json; do
    if [ ! -f "$r" ] || [ "$r" = "$exclude" ]; then continue; fi
    kind=$(jq -r --arg home "$codex" --arg id "$thread" --arg dir "$dir" '
      select(.provider == "codex" and .codexHome == $home)
      | if .id == $id then "registered"
        elif .id == "" and .dir == $dir and (.codexLaunchToken // "") != "" then "pending"
        else empty end' "$r" 2>/dev/null) || continue
    case $kind in
      registered) printf '%s\n' "$r"; return ;;
      pending)
        status=0
        "$anderton_scripts/codex-worker.py" launch-matches "$r" "$thread" >/dev/null 2>&1 || status=$?
        if [ "$status" -ne 3 ]; then printf '%s\n' "$r"; return; fi
        ;;
    esac
  done
  return 0
}

# The caller holds the repository lock and this worker's lock.
bind_codex_worker() {
  local record=$1 thread=$2 launch=$3 details codex dir conflict updated
  if ! details=$(jq -ce --arg id "$thread" --arg launch "$launch" '
    select(.provider == "codex" and (.codexLaunchToken // "") == $launch
      and $id != "" and (.id == "" or .id == $id))
    | {id, codexHome, dir}' "$record"); then
    echo "Codex worker record changed before registering thread $thread." >&2
    return 1
  fi
  codex=$(printf '%s' "$details" | jq -r .codexHome)
  dir=$(printf '%s' "$details" | jq -r .dir)
  conflict=$(codex_worker_record "$codex" "$thread" "$dir" "$record")
  if [ -n "$conflict" ]; then
    echo "Codex thread $thread already has a worker record at $conflict." >&2
    return 1
  fi
  if [ "$(printf '%s' "$details" | jq -r .id)" = "$thread" ]; then return 0; fi
  updated=$(mktemp "$record.XXXXXX") || return 1
  if jq --arg id "$thread" '.id = $id' "$record" > "$updated" && mv -f "$updated" "$record"; then return 0; fi
  rm -f "$updated"
  return 1
}

managed_invoker() {
  local root=$1 provider=$2 sid=$3 identity=$4 dir=$5 r p reg name cwd started file
  if [ "$provider" = codex ]; then codex_worker_record "$identity" "$sid" "$dir"; return; fi
  p=$identity
  reg="$sessions/$p.json"
  name=$(jq -r '.name // empty' "$reg" 2>/dev/null || true)
  cwd=$(jq -r '.cwd // empty' "$reg" 2>/dev/null || true)
  started=$(jq -r '.startedAt // empty | floor' "$reg" 2>/dev/null || true)
  for r in "$holders"/workers/*.json; do
    [ -f "$r" ] || continue
    [ "$(record_provider "$r")" = claude ] || continue
    if claude_worker_identity_matches "$r" "$sid" "$p" "$started"; then
      printf '%s\n' "$r"
      return
    fi
    # A launch predating session UUIDs cannot be identified by name after a rename.
    # Its dedicated checkout remains managed until it is retired.
    dir=$(jq -r --arg root "$root" 'select(.root == $root and .adopted != true and
      .claudeLaunchId == null and .claudeSession == null) | .dir // empty' "$r")
    [ -n "$dir" ] && [[ $cwd == "$dir" || $cwd == "$dir/"* ]] || continue
    if jq -e --arg name "$name" '.worktree == true or .name == $name' "$r" >/dev/null; then
      printf '%s\n' "$r"
      return
    fi
    case $sid in '' | *[!a-zA-Z0-9-]*) continue ;; esac
    for file in "$home"/projects/*/"$sid.jsonl"; do
      if [ -f "$file" ] && "$anderton_scripts/claude-worker.py" legacy-launch-matches "$r" "$file" >/dev/null 2>&1; then
        printf '%s\n' "$r"
        return
      fi
    done
  done
}

claude_binding_process_matches() {
  local file=$1 pid=$2 start
  start=$(proc_start "$pid")
  [ -n "$start" ] || return 1
  jq -e --arg pid "$pid" --arg start "$start" '
    .claudeSession | (.pid | tostring) == $pid and .procStart == $start' "$file" >/dev/null
}

claude_worker_identity_matches() {
  [ -n "$(claude_worker_identities "$2" "$3" "$4" "$1")" ]
}

claude_worker_identities() {
  local sid=$1 pid=$2 started=$3 process_start="" result file
  local -a args
  shift 3
  [ "$#" -gt 0 ] || return 0
  if [ "$#" -eq 1 ] && [ ! -f "$1" ]; then return 0; fi
  if [ -n "$pid" ]; then process_start=$(proc_start "$pid"); fi
  # shellcheck disable=SC2016 # jq expands the filter variables.
  args=(-r --arg sid "$sid" --arg pid "$pid" --arg start "$started" --arg process "$process_start" '
    select(type == "object" and (.provider // "claude") == "claude")
    | select(($sid != "" and (.claudeLaunchId == $sid or .claudeSession.id == $sid or
        (.adopted == true and .sessionId == $sid))) or
      (.adopted == true and $pid != "" and $start != "" and
        (.pid | tostring) == $pid and ((.sessionStartedAt // "") | tostring | split(".")[0]) == $start) or
      ($process != "" and (.claudeSession.pid | tostring) == $pid and .claudeSession.procStart == $process))
    | input_filename
    ')
  if result=$(jq "${args[@]}" "$@" 2>/dev/null); then
    if [ -n "$result" ]; then printf '%s\n' "$result"; fi
    return
  fi
  # jq stops at the first malformed input, including one unrelated to this session.
  for file; do jq "${args[@]}" "$file" 2>/dev/null || true; done
}

live_claude_worker() {
  local file=$1 binding=${2:-} transcript=${3:-} reg dir sid pid started bound worker_dir
  [ "$(record_provider "$file")" = claude ] || return 1
  worker_dir=$(jq -r '.dir // empty' "$file")
  [ -n "$worker_dir" ] || return 1
  bound=$(jq -r '.claudeSession.id // empty' "$file")
  for reg in "$sessions"/*.json; do
    [ -f "$reg" ] || continue
    dir=$(jq -r '.cwd // empty' "$reg" 2>/dev/null) || continue
    case $dir in "$worker_dir" | "$worker_dir"/*) ;; *) continue ;; esac
    sid=$(jq -r '.sessionId // empty' "$reg")
    pid=$(jq -r '.pid // empty' "$reg")
    started=$(jq -r '.startedAt // empty | floor' "$reg")
    [ -n "$sid" ] && [ -n "$pid" ] || continue
    if ! claude_worker_identity_matches "$file" "$sid" "$pid" "$started"; then
      legacy_claude_stop_matches "$file" "$sid" "$pid" "$transcript" || continue
    fi
    if [ -n "$bound" ] && [ "$sid" != "$bound" ]; then
      [ "$binding" = --allow-rebind ] || continue
      claude_binding_process_matches "$file" "$pid" || continue
    fi
    if registered_alive "$pid" "$started" "$(jq -r '.procStart // empty' "$reg")"; then
      printf '%s\n' "$reg"
    fi
  done
}

claude_stop_matches() {
  local registry="$sessions/$3.json"
  process_start_matches "$3" "$4" &&
    [ "$(live_claude_worker "$1" --allow-rebind "${5:-}")" = "$registry" ] &&
    jq -e --arg sid "$2" --arg pid "$3" '
      .sessionId == $sid and (.pid | tostring) == $pid' "$registry" >/dev/null
}

with_claude_worker_lock() {
  local root=$1 worker=$2 session_id=$3 process=$4 start=$5 transcript=$6 attempt status
  shift 6
  for attempt in 1 2 3; do
    claude_stop_matches "$worker" "$session_id" "$process" "$start" "$transcript" || return 3
    if (
      take_repository_lock "$root" 75 || exit 1
      lock_worker "$worker" || exit 75
      claude_stop_matches "$worker" "$session_id" "$process" "$start" "$transcript" || exit 3
      "$@"
    ); then
      return 0
    else
      status=$?
    fi
    [ "$status" = 75 ] || return "$status"
    if [ "$attempt" -lt 3 ]; then sleep 1; fi
  done
  return 1
}

bind_claude_worker() {
  local worker=$1 session_id=$2 process=$3 start=$4 transcript=$5 updated
  updated=$(mktemp "$worker.XXXXXX") || return 1
  if jq --arg sid "$session_id" --arg file "$transcript" --argjson pid "$process" --arg start "$start" '
    if .claudeSession.id != null and .claudeSession.id != $sid and .claudeSession.transcript != null then
      .claudeSession as $old
      | .claudePreviousSessions = ([.claudePreviousSessions[]? | select(.id != $sid and .id != $old.id)] +
        [$old | {id,transcript}])
    else . end
    | .claudeSession = {id: $sid, transcript: $file, pid: $pid, procStart: $start}
    | if .claudeDirection != null and .claudeDirection.target != $sid then del(.claudeDirection) else . end
    ' "$worker" > "$updated" && mv -f "$updated" "$worker"; then return 0; fi
  rm -f "$updated"
  return 1
}

claude_in_worker_pane() {
  local file=$1 sid=$2 pid=$3 launcher socket pane server listed pane_pid
  IFS=$'\x1f' read -r launcher socket pane server <<EOF
$(jq -r '[.launcher, .socket, .pane, .server] | map(. // "") | join("\u001f")' "$file")
EOF
  [ -n "$socket" ] && [ -n "$pane" ] || return 1
  case $launcher in
    herdr)
      listed=$(HERDR_SOCKET_PATH="$socket" herdr agent list 2>/dev/null) || return 1
      printf '%s' "$listed" | jq -e --arg sid "$sid" --arg pane "$pane" '
        [.result.agents[]? | select(.agent_session.value == $sid) | .pane_id] == [$pane]' >/dev/null ;;
    tmux)
      [ -n "$server" ] || return 1
      listed=$(tmux -S "$socket" list-panes -a -F '#{pid} #{pane_id} #{pane_pid}' 2>/dev/null) || return 1
      pane_pid=$(printf '%s\n' "$listed" | awk -v p="$server" -v id="$pane" '$1 == p && $2 == id {print $3}')
      [ -n "$pane_pid" ] && has_ancestor "$pid" "$pane_pid" ;;
    *) return 1 ;;
  esac
}

legacy_claude_stop_matches() {
  local file=$1 sid=$2 pid=$3 transcript=$4 launched age drift
  case $transcript in "$home"/projects/*/"$sid.jsonl") ;; *) return 1 ;; esac
  launched=$(jq -er 'select(.claudeLaunchId == null and .claudeSession == null and .adopted != true and
    .spawnerProvider == "codex") | .startedAt | fromdateiso8601' "$file" 2>/dev/null) || return 1
  age=$(proc_age "$pid")
  [ -n "$age" ] || return 1
  drift=$(( $(date +%s) - age - launched ))
  # The old launcher reserved the record before opening the pane and waited up to 120 seconds for readiness.
  [ "$drift" -ge -2 ] && [ "$drift" -le 120 ] && claude_in_worker_pane "$file" "$sid" "$pid" &&
    "$anderton_scripts/claude-worker.py" legacy-launch-matches "$file" "$transcript"
}

has_ancestor() {
  local p=$1
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    [ "$p" != "$2" ] || return 0
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
  return 1
}

# The pid of the session whose id is $1, from its registration file, or nothing. A resumed session
# runs as a new process under the same id, and a crashed one's file can outlive it, so a live entry wins.
session_pid() {
  local f p first=""
  for f in "$sessions"/*.json; do
    [ -e "$f" ] || continue
    if [ "$(jq -r '.sessionId // empty' "$f" 2>/dev/null)" = "$1" ]; then
      p=$(jq -r '.pid // empty' "$f" 2>/dev/null)
      [ -n "$p" ] || continue
      if registered_alive "$p" "$(jq -r '.startedAt // empty | floor' "$f" 2>/dev/null)" "$(jq -r '.procStart // empty' "$f" 2>/dev/null)"; then
        echo "$p"
        return
      fi
      [ -n "$first" ] || first=$p
    fi
  done
  if [ -n "$first" ]; then echo "$first"; fi
}

# The project directory $1 belongs to: its repository, named by the main checkout or, for a bare
# repository or a separate git dir, by the git dir itself, so every worktree of one repository shares
# a project. Outside a repository, the directory.
project_root() {
  local common top
  if common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    case $common in
      */.git) dirname "$common" ;;
      *) printf '%s\n' "$common" ;;
    esac
  elif top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null); then
    printf '%s\n' "$top"
  else
    (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
  fi
}

# The project of the calling Claude Code session: the cwd its registry entry records, else this shell's.
invoking_root() {
  local pid cwd=""
  pid=$(invoking_pid)
  if [ -n "$pid" ]; then cwd=$(jq -r '.cwd // empty' "$sessions/$pid.json" 2>/dev/null || true); fi
  project_root "${cwd:-$PWD}"
}

# A fixed-length file name for project root $1: the root itself can exceed the 255-byte limit on
# one path component. The record keeps the full root.
project_key() {
  printf '%s' "$1" | git hash-object --stdin
}

# The holder file for project $1, or for named scope $2 within it.
holder_path() {
  local key=$1
  if [ -n "${2:-}" ]; then key=$(printf '%s\nscope=%s' "$1" "$2"); fi
  printf '%s/%s.json\n' "$holders" "$(project_key "$key")"
}

# True when registry entry $1 is the live process that holder record $2 names. A pid alone would
# also match a later process given the same pid, so the start times must agree; a record written by
# an earlier version has none, and then the process must have started before the claim.
is_holder() {
  if [ ! -f "$1" ] || [ ! -f "$2" ]; then return 1; fi
  jq -en --slurpfile reg "$1" --slurpfile rec "$2" '
    $reg[0] as $s | $rec[0] as $r
    | ($r.provider // "claude") == "claude" and $s.pid == $r.pid
      and (if $s.startedAt == null then true
           elif $r.startedAt != null then ($s.startedAt | floor) == ($r.startedAt | floor)
           else (($r.claimedAt // "") | fromdateiso8601? // null) as $at | $at == null or $at * 1000 >= $s.startedAt
           end)' >/dev/null 2>&1 &&
    registered_alive "$(jq -r .pid "$1")" "$(jq -r '.startedAt // empty | floor' "$1")" "$(jq -r '.procStart // empty' "$1")"
}

# The record of project $1's holder, or of scope $2's: its own file, else, for the project's role,
# the machine-wide file earlier versions wrote, while that holder's session belongs to this project.
# Prints the path, or nothing.
holder_record() {
  local f lpid lcwd
  f=$(holder_path "$1" "${2:-}")
  if [ -f "$f" ]; then
    printf '%s\n' "$f"
    return
  fi
  if [ -n "${2:-}" ] || [ ! -f "$legacy_holder" ]; then return 0; fi
  lpid=$(jq -r '.pid // empty' "$legacy_holder" 2>/dev/null || true)
  [ -n "$lpid" ] || return 0
  lcwd=$(jq -r '.cwd // empty' "$sessions/$lpid.json" 2>/dev/null || true)
  if [ -n "$lcwd" ] && [ "$(project_root "$lcwd")" = "$1" ]; then printf '%s\n' "$legacy_holder"; fi
}

# Every holder record in project $1: the project's role and each named scope's.
project_holders() {
  local f
  holder_record "$1"
  for f in "$holders"/*.json; do
    [ -f "$f" ] || continue
    if [ "$(jq -r 'select(.scope != null) | .root' "$f" 2>/dev/null || true)" = "$1" ]; then printf '%s\n' "$f"; fi
  done
}

# True once `claude agents` lists no session named $1, after waiting up to 5 seconds for one that is exiting.
session_gone() {
  local listed _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if listed=$(claude agents --json 2>/dev/null) &&
      printf '%s' "$listed" | jq -e --arg n "$1" 'all(.[]; .name != $n)' >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# Whether worker $4's tab or window stands in its server: prints present, absent, or unknown when the server's
# answer cannot be read. $1 herdr|tmux, $2 the server's socket, $3 the tab or window id, $5 the tmux server's pid.
# A restarted server reuses ids, so the tab or window must also carry the worker's name (the herdr label, the
# tmux window name) and, for tmux, belong to the same server process; an id holding anything else is absent.
place_state() {
  local out
  if [ -z "$2" ] || [ -z "$3" ]; then
    echo unknown
    return
  fi
  case $1 in
    herdr)
      if ! command -v herdr >/dev/null 2>&1; then
        echo unknown
      elif out=$(HERDR_SOCKET_PATH="$2" herdr tab get "$3" 2>&1); then
        printf '%s' "$out" | jq -r --arg n "$4" '.result.tab.label as $l
          | if $l == $n then "present" elif ($l | type) == "string" then "absent" else "unknown" end' 2>/dev/null ||
          echo unknown
      elif printf '%s' "$out" | jq -e '.error.code == "tab_not_found" or .error.code == "server_not_running"' >/dev/null 2>&1; then
        echo absent
      else
        echo unknown
      fi
      ;;
    tmux)
      if ! command -v tmux >/dev/null 2>&1; then
        echo unknown
      elif out=$(tmux -S "$2" list-windows -a -F '#{pid} #{window_id} #{window_name}' 2>&1); then
        if printf '%s\n' "$out" | awk -v p="${5:-}" -v w="$3" -v n="$4" '$2 == w && $3 == n && (p == "" || $1 == p) { f = 1 } END { exit !f }'; then
          echo present
        else
          echo absent
        fi
      else
        # A dead server leaves its socket file behind; tmux then says no server is running there.
        case $out in
          *"no server running"* | *"No such file or directory"*) echo absent ;;
          *) echo unknown ;;
        esac
      fi
      ;;
    *) echo unknown ;;
  esac
}

# Where agy worker record $1 stands, from one herdr snapshot of its pane. Sets:
#   agy_state: running (herdr shows agy in the recorded pane, in the worktree, and as the agy session the record bound,
#     when it bound one), gone (herdr says the pane is gone), elsewhere (the pane shows no agent, another one, or another
#     session) or unknown (herdr gave no answer these scripts can read);
#   agy_status: herdr's status for the pane (idle, working, blocked, done), or nothing;
#   agy_agent, agy_cwd: what that snapshot shows in the pane, or nothing.
# shellcheck disable=SC2034 # the scripts that source this file read what it sets
agy_check() {
  local socket pane dir instance out got_instance got_pane
  agy_state=unknown agy_status="" agy_agent="" agy_cwd=""
  socket=$(jq -r '.socket // empty' "$1") pane=$(jq -r '.pane // empty' "$1") dir=$(jq -r '.dir // empty' "$1")
  instance=$(jq -r '.agyInstance // empty' "$1")
  [ -n "$socket" ] && [ -n "$pane" ] && command -v herdr >/dev/null 2>&1 || return 0
  # herdr exits non-zero, with its error on stderr, for a pane with no agent and for a missing pane.
  out=$(HERDR_SOCKET_PATH="$socket" herdr agent get "$pane" 2>&1) || true
  if printf '%s' "$out" | jq -e '.error.code == "agent_not_found"' >/dev/null 2>&1; then
    out=$(HERDR_SOCKET_PATH="$socket" herdr pane get "$pane" 2>&1) || true
    if printf '%s' "$out" | jq -e '.error.code == "pane_not_found"' >/dev/null 2>&1; then
      agy_state=gone
    elif printf '%s' "$out" | jq -e '.result.pane.pane_id' >/dev/null 2>&1; then
      agy_state=elsewhere
    fi
    return 0
  fi
  # A separator that is not whitespace, so an empty field stays a field.
  IFS=$'\x1f' read -r agy_agent agy_status agy_cwd got_instance got_pane <<EOF
$(printf '%s' "$out" | jq -r '(.result.agent // empty) | [.agent // "", .agent_status // "", .cwd // "", (.agent_session.value // "" | tostring), .pane_id // ""] | join("\u001f")' 2>/dev/null)
EOF
  [ -n "$got_pane" ] || return 0
  if [ "$got_pane" = "$pane" ] && [ "$agy_agent" = agy ] && { [ -z "$instance" ] || [ "$got_instance" = "$instance" ]; } &&
    { [ "$agy_cwd" = "$dir" ] || case $agy_cwd in "$dir"/*) true ;; *) false ;; esac; }; then
    agy_state=running
  else
    agy_state=elsewhere
  fi
}

# The settings for an agy session that trusts folder $1: agy asks whether to trust each new folder, and extends the
# trust saved for a parent no further than home. --settings is never saved, but it replaces what settings.json says
# for each key it names, so this is the saved settings with $1 added to their trust. Prints why when it cannot.
agy_session_settings() {
  local saved="$HOME/.gemini/antigravity-cli/settings.json"
  if [ ! -e "$saved" ]; then
    jq -nc --arg dir "$1" '{trustedWorkspaces: [$dir]}'
  elif ! jq -ce --arg dir "$1" 'if type == "object" then . + {trustedWorkspaces: (((.trustedWorkspaces // []) + [$dir]) | unique)}
    else error("not an object") end' "$saved" 2>/dev/null; then
    echo "$saved is not a JSON object, so agy's own settings could not be kept for this session."
    return 1
  fi
}

# The SHA-256 of standard input, by whichever of the two common tools this system has.
sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# The hook, plugin and agent configuration an agy session in worktree $1 loads: its global files and directories, and
# the same names in each of the four workspace roots agy reads. agy reloads hooks mid-session, so any of these can turn
# the guard off or start an unhooked subagent while the worker runs.
agy_config_paths() {
  local g="$HOME/.gemini" root name
  for name in config/hooks.json config/hooks config/plugins config/plugins.json config/config.json config/agents hooks.json \
    antigravity-cli/hooks.json antigravity-cli/plugins antigravity-cli/plugins.json antigravity-cli/agents \
    antigravity-cli/agents.json antigravity-cli/secplugins; do
    printf '%s\n' "$g/$name"
  done
  for root in .agents .agent _agents _agent; do
    for name in hooks.json plugins plugins.json agents; do printf '%s\n' "$1/$root/$name"; done
  done
}

# One line per path agy_config_paths names for worktree $1: the path, a tab, and the digest of what is there now (every
# entry beneath a directory, a link's target, a file's bytes) or "absent". Of config/config.json, which also keeps agy's
# other settings, only the plugins it enables.
agy_config_state() {
  local path entry
  while IFS= read -r path; do
    # No config.json enables no plugins, as one without the key does; one jq cannot read is digested whole.
    if [ "$path" = "$HOME/.gemini/config/config.json" ]; then
      entry=null
      if [ -e "$path" ] || [ -L "$path" ]; then entry=$(jq -cS '.plugins // null' "$path" 2>/dev/null) || entry=""; fi
      if [ -n "$entry" ]; then
        printf '%s\tplugins %s\n' "$path" "$(printf '%s' "$entry" | sha256_stdin)"
        continue
      fi
    fi
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
      printf '%s\tabsent\n' "$path"
      continue
    fi
    printf '%s\t%s\n' "$path" "$(
      find "$path" -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r entry; do
        if [ -L "$entry" ]; then printf 'L %s %s\n' "$entry" "$(readlink "$entry")"
        elif [ -d "$entry" ]; then printf 'D %s\n' "$entry"
        elif [ -f "$entry" ]; then printf 'F %s %s\n' "$entry" "$(sha256_stdin < "$entry" 2>/dev/null || echo unreadable)"
        else printf 'O %s\n' "$entry"; fi
      done | sha256_stdin)"
  done <<EOF
$(agy_config_paths "$1")
EOF
}

# True once worker $4's tab or window ($1 herdr|tmux, socket $2, id $3, tmux server pid $5) is absent from its
# server, waiting up to 5 seconds, and no session named $4 is listed. A worker held at a startup prompt never
# registers, so the session list alone would call it gone while its tab or window still runs.
worker_gone() { # worker_gone <launcher> <socket> <tab> <name> [server] [label]: the label defaults to the name
  local _ label="${6:-$4}"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ "$(place_state "$1" "$2" "$3" "$label" "${5:-}")" = absent ]; then break; fi
    sleep 0.5
  done
  [ "$(place_state "$1" "$2" "$3" "$label" "${5:-}")" = absent ] && session_gone "$4"
}

# Native identity survives display renames. A launch without an identity can only be found by its old name
# and directory, which lets its Stop hook recheck the original pane before assigning identity.
worker_record() {
  local f dir
  if [ -n "${3:-}${4:-}" ]; then
    f=$(claude_worker_identities "${3:-}" "${4:-}" "${5:-}" "$holders"/workers/*.json)
    if [ -n "$f" ]; then printf '%s\n' "${f%%$'\n'*}"; return; fi
  fi
  f="$holders/workers/$1.json"
  if [ -n "$1" ] && [ -f "$f" ]; then
    case $(record_provider "$f") in codex | agy) return 0 ;; esac
    dir=$(jq -r '.dir // empty' "$f" 2>/dev/null || true)
    case $2 in
      "$dir" | "$dir"/*)
        if [ -n "$dir" ] && jq -e '
          .adopted != true and .claudeLaunchId == null and .claudeSession == null' "$f" >/dev/null 2>&1; then
          printf '%s\n' "$f"
          return
        fi
        ;;
    esac
  fi
}

# True when that session is a worker: it reports to its spawner, not the user.
is_worker() {
  [ -n "$(worker_record "$@")" ]
}

# What in worktree $1, started at commit $2, retire.sh must keep: prints uncommitted, flagged (files git marks
# assume-unchanged or skip-worktree), unpushed (commits no remote branch has) or unreadable, or nothing. Untracked files
# count whatever status.showUntrackedFiles says, since git worktree remove deletes the ones status leaves out, and a git
# command that fails is never read as "nothing to keep".
worktree_work() {
  local out
  out=$(git -C "$1" status --porcelain --untracked-files=normal 2>/dev/null) || { echo unreadable; return; }
  if [ -n "$out" ]; then echo uncommitted; return; fi
  # Status hides edits to a file tagged assume-unchanged (lower case in ls-files -v) or skip-worktree (S), and removal
  # deletes them. Only the tags are read, never the paths, and every reader takes its whole input.
  out=$(set -o pipefail; git -C "$1" ls-files -v 2>/dev/null | cut -c1 | LC_ALL=C sort -u) || { echo unreadable; return; }
  case $out in *[abcdefghijklmnopqrstuvwxyzS]*) echo flagged; return ;; esac
  out=$(git -C "$1" rev-list -1 HEAD --not --remotes "$2" 2>/dev/null) || { echo unreadable; return; }
  if [ -n "$out" ]; then echo unpushed; fi
}

cleanup_anderton_locks() {
  if [ -n "${worker_lock:-}" ]; then rmdir -- "$worker_lock"; fi
  if [ -n "${repository_directory_lock:-}" ]; then
    rm -f -- "$repository_directory_lock/pid"
    rmdir -- "$repository_directory_lock"
  fi
}

lock_worker() {
  codex_worker_lock="$1.lock"
  if ! mkdir -- "$codex_worker_lock" 2>/dev/null; then
    echo "A worker operation already holds $codex_worker_lock." >&2
    return 1
  fi
  worker_lock=$codex_worker_lock
  trap 'cleanup_anderton_locks' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# The claim lock is flock where the system has it: the kernel releases it when the claim exits, so it
# cannot go stale, and it holds on filesystems where two concurrent mkdirs can both succeed (seen on
# a CI runner). macOS has no flock, so there it is a directory. Only the claim that made that removes
# it: deleting one whose owner looks dead races a concurrent claim that has just made a fresh one.
take_repository_lock() {
  mkdir -p "$holders" || exit 1
  repository_lock="$(holder_path "$1").lock"
  local tries=0 owner status timeout_status=${2:-1}
  if command -v flock >/dev/null 2>&1; then
    exec 9>>"$repository_lock.flock" || exit 1
    if flock -w 10 9; then return; else status=$?; fi
    if [ "$status" = 1 ]; then
      echo "Could not take $repository_lock.flock within 10 seconds: another claim in this repository is running." >&2
      exit "$timeout_status"
    fi
    exit 1
  fi
  until mkdir "$repository_lock" 2>/dev/null; do
    # Not there, so mkdir failed for another reason: retry once and let it say why.
    if [ ! -e "$repository_lock" ]; then
      mkdir "$repository_lock" && break
      exit 1
    fi
    owner=$(cat "$repository_lock/pid" 2>/dev/null || true)
    if [ -n "$owner" ] && [ -z "$(proc_age "$owner")" ]; then
      echo "$repository_lock was left by claim process $owner, which is gone. Remove it and rerun." >&2
      exit 1
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge 50 ]; then
      echo "Could not take $repository_lock within 10 seconds. If no other claim is running, remove it and rerun." >&2
      if [ -n "$owner" ]; then exit "$timeout_status"; fi
      exit 1
    fi
    sleep 0.2
  done
  repository_directory_lock=$repository_lock
  trap 'cleanup_anderton_locks' EXIT
  trap 'exit 1' INT TERM HUP
  echo $$ > "$repository_lock/pid"
}

# One event about this role or one of its workers, for the host: ANDERTON_EVENT_COMMAND, when the host sets it, runs
# in the background with the event as JSON on stdin. It never delays a hook: it is detached, killed after
# ANDERTON_EVENT_TIMEOUT seconds (default 3), and its output and exit status are ignored. Unset, nothing runs.
# emit_event <claim id> <scope> <kind> [field=value ...], fields being status, milestoneKind and worker, plus
# link=<url> repeated. Nothing is sent without a claim id or for a scope other than workgroup:<id>[/<project>].
event_scope_re='^workgroup:[a-z][a-z0-9-]{0,62}(/[a-z0-9][a-z0-9.-]{0,63})?$'
event_link_re='^https://github\.com/[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}/(pull|issues)/[0-9]{1,9}$'
emit_event() {
  local claim=$1 scope=$2 kind=$3 json field cmd=${ANDERTON_EVENT_COMMAND:-} timeout=${ANDERTON_EVENT_TIMEOUT:-3}
  shift 3
  [ -n "$cmd" ] && [ -n "$claim" ] || return 0
  # Only a role claimed for a workgroup has anywhere on the host to show, and only a scope of plain ids is passed on.
  [[ $scope =~ $event_scope_re ]] || return 0
  case $timeout in '' | *[!0-9]*) timeout=3 ;; esac
  # Base 10: a leading zero would make bash read 08 as a bad octal number and the watchdog would never fire.
  timeout=$((10#$timeout))
  json=$(jq -nc --arg claim "$claim" --arg scope "$scope" --arg kind "$kind" '{claimId: $claim, scope: $scope, kind: $kind}') || return 0
  for field in "$@"; do
    case $field in
      link=*)
        [[ ${field#link=} =~ $event_link_re ]] || continue
        json=$(printf '%s' "$json" | jq -c --arg v "${field#link=}" '.links = ((.links // []) + [$v])') || return 0
        ;;
      status=* | milestoneKind=* | worker=*)
        json=$(printf '%s' "$json" | jq -c --arg k "${field%%=*}" --arg v "${field#*=}" '.[$k] = $v') || return 0 ;;
    esac
  done
  (
    # Its own process group, so the timeout ends whatever the command started too.
    set -m
    bash -c "$cmd" <<< "$json" >/dev/null 2>&1 &
    p=$!
    set +m
    # A wall-clock deadline: counting short sleeps drifts on a loaded machine.
    deadline=$((SECONDS + timeout))
    while kill -0 -- "-$p" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
      sleep 0.1
    done
    if kill -0 -- "-$p" 2>/dev/null; then
      kill -TERM -- "-$p" 2>/dev/null
      sleep 1
      kill -KILL -- "-$p" 2>/dev/null
    fi
    wait "$p" 2>/dev/null
    # The caller's descriptors, such as the repository lock on fd 9, stay with the caller: a slow command holds none.
  ) </dev/null >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
  return 0
}

# The host's last event about a worker leaving its Anderton: retired, or released and no longer reporting.
emit_worker_done() {
  emit_event "$(jq -r '.spawnerClaimId // empty' "$1" 2>/dev/null)" "$(jq -r '.spawnerScope // empty' "$1" 2>/dev/null)" "done" \
    "worker=$(jq -r '.name // empty' "$1" 2>/dev/null)"
}

# A session's turn starting (working) or ending (idle), to ANDERTON_EVENT_COMMAND: as the role it holds in its
# repository, or as the worker a role started. Turn boundaries, not the watch, own these two: no watch runs mid-turn.
emit_turn() {
  local status=$1 sid=$2 cwd=$3 r w
  [ -n "${ANDERTON_EVENT_COMMAND:-}" ] && [ -n "$sid" ] || return 0
  if [ -n "$cwd" ]; then
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      if [ "$(jq -r '.sessionId // empty' "$r" 2>/dev/null)" = "$sid" ]; then
        emit_event "$(jq -r '.claimId // empty' "$r")" "$(jq -r '.scope // empty' "$r")" status "status=$status"
        return 0
      fi
    done <<EOF
$(project_holders "$(project_root "$cwd")")
EOF
  fi
  for w in "$holders"/workers/*.json; do
    [ -f "$w" ] || continue
    [ "$(jq -r '.claudeSession.id // .claudeLaunchId // empty' "$w" 2>/dev/null)" = "$sid" ] || continue
    emit_event "$(jq -r '.spawnerClaimId // empty' "$w")" "$(jq -r '.spawnerScope // empty' "$w")" status \
      "status=$status" "worker=$(jq -r '.name // empty' "$w")"
    return 0
  done
}

# A fresh id for a new claim: the host binds a claim, not a scope, so a later session claiming the same scope is not
# bound by an earlier one's approval.
new_claim_id() {
  local id
  id=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null) || return 1
  printf '%s\n' "$id" | tr '[:upper:]' '[:lower:]'
}
