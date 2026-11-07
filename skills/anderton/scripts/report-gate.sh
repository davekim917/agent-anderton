#!/usr/bin/env bash
# The plugin's hook on SendMessage. Before a send (PreToolUse) it holds a message to an Anderton unless the message's
# first line opens with a kind, and holds one that repeats, word for word, what the sender last sent that Anderton
# within $ANDERTON_REPEAT_WINDOW seconds (default 1800). Each message wakes that session and re-reads its whole context,
# so an acknowledgement or a "still waiting" costs as much as a result. After a send succeeds (PostToolUse) it records
# the message, so a send that failed or was denied is never counted as sent.
# It judges a message from a worker spawn.sh started to the session that started it, and a message from any session
# in a repository to that repository's live Anderton. A worker has four kinds; any other session also has DIRECTION:, for
# passing on a person's direction. A named project's Anderton passes along what it has gathered, so its messages are
# held only when they repeat. The repository's Anderton is never held.
# It only ever blocks (exit 2, the reason on stderr) and never prints a decision, so it cannot approve anything. The
# body runs in a subshell that reports a block as 10, so a crash, which bash may report as 2, is read as allow. On any
# failure it exits 0 and prints nothing.

input=$(cat)

main() {
  # shellcheck source=SCRIPTDIR/session-lib.sh
  . "$(dirname "$0")/session-lib.sh" || exit 0
  local fields event sid cwd to id first hash
  fields=$(printf '%s' "$input" | jq -r '[.hook_event_name // "", .session_id // "", .cwd // "",
    (.tool_input.to // "" | tostring), .tool_use_id // "",
    (.tool_input.message | if type == "string" then . else "" end | split("\n") | map(select(test("\\S"))) | first // "")]
    | join("\u001f")' 2>/dev/null) || exit 0
  IFS=$'\x1f' read -r event sid cwd to id first <<EOF
$fields
EOF
  pending="$holders/reports/pending"
  case $id in */* | .*) id="" ;; esac

  if [ "$event" = PostToolUse ]; then
    local target sum
    [ -n "$id" ] && [ -f "$pending/$id" ] || exit 0
    { read -r target && read -r sum; } < "$pending/$id" 2>/dev/null || exit 0
    rm -f "$pending/$id"
    [ -n "$target" ] && [ -n "$sum" ] || exit 0
    # SendMessage reports a failed delivery as a normal result whose body says "success": false, so PostToolUse runs
    # for it too. That body comes as an object, or as JSON inside the result's text.
    if printf '%s' "$input" | jq -e '.tool_response | if type == "object" and has("success") then .success == false
      else tostring | test("\\\\*\"success\\\\*\"\\s*:\\s*false") end' >/dev/null 2>&1; then exit 0; fi
    printf '%s %s\n' "$(date +%s)" "$sum" >| "$target" 2>/dev/null
    exit 0
  fi

  # A pure notify_when_idle subscription and the structured protocol replies carry no text to judge.
  if [ -z "$sid" ] || [ -z "$to" ] || [ -z "$first" ]; then exit 0; fi

  local pid reg name home_dir root project r scope="" hpid hname recipient="" rkey="" worker="" spawner
  pid=$(sender_pid)
  [ -n "$pid" ] || exit 0
  reg="$sessions/$pid.json"
  name=$(jq -r '.name // empty' "$reg" 2>/dev/null)
  # The directory the session started in, not one it has moved to since.
  home_dir=$(jq -r '.cwd // empty' "$reg" 2>/dev/null)
  [ -z "$home_dir" ] || cwd=$home_dir
  [ -n "$cwd" ] || exit 0

  # Who the sender is comes first: the repository's Anderton is never held, and a project's only on repeats.
  root=$(project_root "$cwd")
  project=$(holder_record "$root")
  if [ -n "$project" ] && names_sender "$project"; then exit 0; fi
  while IFS= read -r r; do
    if [ -n "$r" ] && [ "$r" != "$project" ] && names_sender "$r"; then scope=1; fi
  done <<EOF
$(project_holders "$root")
EOF
  if is_worker "$name" "$cwd"; then worker=1; fi

  # The project's holder, only while it is the live process its record names; when that is uncertain, allow.
  if [ -n "$project" ]; then
    hpid=$(jq -r '.pid // empty' "$project" 2>/dev/null)
    if [ -n "$hpid" ] && is_holder "$sessions/$hpid.json" "$project"; then
      hname=$(jq -r '.name // empty' "$sessions/$hpid.json" 2>/dev/null)
      if addresses "$hpid" "$hname"; then
        recipient=${hname:-the Anderton}
        rkey="pid:$hpid"
      fi
    fi
  fi
  if [ -z "$recipient" ] && [ -n "$worker" ]; then
    spawner=$(jq -r '.spawner // empty' "$holders/workers/$name.json" 2>/dev/null)
    if [ -n "$spawner" ] && addresses "" "$spawner"; then
      recipient=$spawner
      rkey="name:$spawner"
    fi
  fi
  [ -n "$recipient" ] || exit 0

  local kind=""
  if [ -z "$scope" ]; then
    local kinds="RESULT|QUESTION|BLOCKED|ANSWER"
    [ -n "$worker" ] || kinds="$kinds|DIRECTION"
    kind=$(printf '%s' "$first" | sed -nE -e 's/^[[:space:]*_#>`-]*//' -e "s/^($kinds):.*/\\1/p") || exit 0
    if [ -z "$kind" ]; then
      {
        echo "Not sent. Message \"$recipient\" only when it changes what they do, with the kind as the first word:"
        echo "  RESULT: a milestone done (PR ready, task finished), with its link and what you verified"
        echo "  QUESTION: a decision you need, with your recommendation"
        echo "  BLOCKED: what stops you and what would unblock it"
        echo "  ANSWER: a reply to something \"$recipient\" asked you"
        [ -n "$worker" ] || echo "  DIRECTION: a person's instruction you are passing on, in their words"
        echo "Acknowledgements, \"still waiting\", restated instructions and FYIs that change nothing are not sent: each one"
        echo "wakes \"$recipient\" for nothing. If none of these fits, keep working and report at the next milestone."
      } >&2
      exit 10
    fi
  fi

  # Two answers can be the same short word to different questions.
  [ "$kind" != ANSWER ] || exit 0
  local state at sum window=${ANDERTON_REPEAT_WINDOW:-1800} keep=1440
  case $window in '' | *[!0-9]*) exit 0 ;; esac
  [ $((window / 60 + 1)) -le "$keep" ] || keep=$((window / 60 + 1))
  mkdir -p "$pending" 2>/dev/null || exit 0
  find "$holders/reports" -type f -mmin +"$keep" -exec rm -f {} + 2>/dev/null
  hash=$(printf '%s' "$input" | jq -j '.tool_input.message' 2>/dev/null | cksum | tr -s ' ' '-')
  state="$holders/reports/$(printf '%s\n%s' "$sid" "$rkey" | cksum | cut -d' ' -f1)"
  if [ -f "$state" ] && read -r at sum 2>/dev/null < "$state" && [ "$sum" = "$hash" ] && [ $(($(date +%s) - at)) -lt "$window" ]; then
    echo "Not sent: it repeats, word for word, your last message to \"$recipient\". Send again only when something changed, and say what." >&2
    exit 10
  fi
  [ -z "$id" ] || printf '%s\n%s\n' "$state" "$hash" >| "$pending/$id" 2>/dev/null
  exit 0
}

# The pid of the session running this hook. Its registry entry names its session id; when two entries name it, the
# one this hook runs under.
sender_pid() {
  local f p first="" a n
  for f in "$sessions"/*.json; do
    [ -e "$f" ] || continue
    [ "$(jq -r '.sessionId // empty' "$f" 2>/dev/null)" = "$sid" ] || continue
    p=$(jq -r '.pid // empty' "$f" 2>/dev/null)
    [ -n "$p" ] || continue
    [ -n "$first" ] || first=$p
    a=$$ n=0
    while [ -n "$a" ] && [ "$a" -gt 1 ] 2>/dev/null && [ "$n" -lt 20 ]; do
      if [ "$a" = "$p" ]; then
        printf '%s\n' "$p"
        return
      fi
      a=$(ps -o ppid= -p "$a" 2>/dev/null | tr -d ' ')
      n=$((n + 1))
    done
  done
  printf '%s\n' "$first"
}

# True when holder record $1 names the sender's registry entry. The sender is the live process running this hook, so
# only its pid and start time are compared; a record or entry without a start time counts as a match.
names_sender() {
  [ -f "$1" ] && jq -en --slurpfile s "$reg" --slurpfile r "$1" '$s[0] as $s | $r[0] as $r | $s.pid == $r.pid
    and ($s.startedAt == null or $r.startedAt == null or ($s.startedAt | floor) == ($r.startedAt | floor))' >/dev/null 2>&1
}

# True when $to addresses the session with pid $1 or, when no pid is given, the one named $2: by name, by name with
# its listing ref, or by the socket address a reply copies from its message, which names the session's pid.
addresses() {
  local sock
  case $to in
    uds:*.sock)
      sock=${to##*/}
      sock=${sock%.sock}
      if [ -n "$1" ]; then
        [ "$sock" = "$1" ]
      else
        [ -n "$2" ] && [ "$(jq -r '.name // empty' "$sessions/$sock.json" 2>/dev/null)" = "$2" ]
      fi
      return
      ;;
  esac
  [ -n "$2" ] || return 1
  case $to in
    "$2" | "$2 ["*) return 0 ;;
  esac
  return 1
}

(main)
[ $? -eq 10 ] && exit 2
exit 0
