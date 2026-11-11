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

# True when pid $1 is running and started when the session registry says it did ($2, epoch ms).
# A registry file outlives a crashed session, and its pid can then belong to an unrelated process.
# ps, not kill -0: a sandboxed shell can be denied signalling a live process (EPERM).
registered_alive() {
  local age drift
  age=$(proc_age "$1")
  [ -n "$age" ] || return 1
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

# The pid of the session whose id is $1, from its registration file, or nothing. A resumed session
# runs as a new process under the same id, and a crashed one's file can outlive it, so a live entry wins.
session_pid() {
  local f p first=""
  for f in "$sessions"/*.json; do
    [ -e "$f" ] || continue
    if [ "$(jq -r '.sessionId // empty' "$f" 2>/dev/null)" = "$1" ]; then
      p=$(jq -r '.pid // empty' "$f" 2>/dev/null)
      [ -n "$p" ] || continue
      if registered_alive "$p" "$(jq -r '.startedAt // empty | floor' "$f" 2>/dev/null)"; then
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
  pid="${CLAUDE_PID:-}"
  if [ -z "$pid" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then pid=$(session_pid "$CLAUDE_CODE_SESSION_ID"); fi
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
    | $s.pid == $r.pid
      and (if $s.startedAt == null then true
           elif $r.startedAt != null then ($s.startedAt | floor) == ($r.startedAt | floor)
           else (($r.claimedAt // "") | fromdateiso8601? // null) as $at | $at == null or $at * 1000 >= $s.startedAt
           end)' >/dev/null 2>&1 &&
    registered_alive "$(jq -r .pid "$1")" "$(jq -r '.startedAt // empty | floor' "$1")"
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

# True when the session named $1, running in directory $2, is a worker spawn.sh started or adopt.sh adopted: the
# worker record of that name exists and the session runs in its directory. An adopted session shares its directory
# with the user's other sessions, so it must also be the session adopted: its session id $3 or its pid $4 as
# recorded (/clear keeps the pid, a resume keeps the session id). A worker reports to its spawner, not the user.
is_worker() {
  local f="$holders/workers/$1.json" dir
  if [ -z "$1" ] || [ ! -f "$f" ]; then return 1; fi
  dir=$(jq -r '.dir // empty' "$f" 2>/dev/null || true)
  [ -n "$dir" ] || return 1
  case $2 in "$dir" | "$dir"/*) ;; *) return 1 ;; esac
  [ "$(jq -r '.adopted // false' "$f" 2>/dev/null || true)" = true ] || return 0
  jq -e --arg sid "${3:-}" --arg pid "${4:-}" \
    '($sid != "" and .sessionId == $sid) or ($pid != "" and (.pid | tostring) == $pid)' "$f" >/dev/null 2>&1
}
