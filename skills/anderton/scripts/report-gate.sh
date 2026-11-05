#!/usr/bin/env bash
# The plugin's PreToolUse hook on SendMessage. It holds a message to an Anderton unless the message's first line opens
# with RESULT:, QUESTION:, BLOCKED: or ANSWER:, and holds one that repeats the sender's last report. Each message wakes
# that session and re-reads its whole context, so an acknowledgement or a "still waiting" costs as much as a result.
# It judges a message from a worker spawn.sh started to the session that started it, and a message from any session
# in a project to that project's holder. A scope's holder relays asks from its own channels, so its messages to the
# project's holder are held only when they repeat. It only ever blocks (exit 2, the reason on stderr): it never prints
# a decision, so it cannot approve anything. Anywhere else, and on any failure, it exits 0 and prints nothing.
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

input=$(cat)
fields=$(printf '%s' "$input" | jq -r '[.session_id // "", .cwd // "", (.tool_input.to // "" | tostring),
  (.tool_input.message | if type == "string" then . else "" end | split("\n") | map(select(test("\\S"))) | first // "")]
  | join("\u001f")' 2>/dev/null) || exit 0
IFS=$'\x1f' read -r sid cwd to first <<EOF
$fields
EOF
# A pure notify_when_idle subscription and the structured protocol replies carry no text to judge.
if [ -z "$sid" ] || [ -z "$cwd" ] || [ -z "$to" ] || [ -z "$first" ]; then exit 0; fi

pid=$(session_pid "$sid")
[ -n "$pid" ] || exit 0
reg="$sessions/$pid.json"
name=$(jq -r '.name // empty' "$reg" 2>/dev/null)

# True when $to addresses the session named $2, or with pid $1: by name, by name with its listing ref, or by the
# socket address a reply copies from its message, which names the session's pid.
addresses() {
  local sock
  case $to in
    uds:*.sock)
      sock=${to##*/}
      sock=${sock%.sock}
      [ -n "$1" ] && [ "$sock" = "$1" ] && return 0
      [ -n "$2" ] && [ "$(jq -r '.name // empty' "$sessions/$sock.json" 2>/dev/null)" = "$2" ] && return 0
      return 1
      ;;
  esac
  [ -n "$2" ] || return 1
  case $to in
    "$2" | "$2 ["*) return 0 ;;
  esac
  return 1
}

recipient="" kinds=1
if is_worker "$name" "$cwd"; then
  spawner=$(jq -r '.spawner // empty' "$holders/workers/$name.json" 2>/dev/null)
  if [ -n "$spawner" ] && addresses "" "$spawner"; then recipient=$spawner; fi
fi
if [ -z "$recipient" ]; then
  root=$(project_root "$cwd")
  project=$(holder_record "$root")
  [ -n "$project" ] || exit 0
  # The project's holder messages whom it likes.
  if is_holder "$reg" "$project"; then exit 0; fi
  hpid=$(jq -r '.pid // empty' "$project" 2>/dev/null)
  hname=$(jq -r '.name // empty' "$sessions/$hpid.json" 2>/dev/null)
  addresses "$hpid" "$hname" || exit 0
  recipient=${hname:-the Anderton}
  while IFS= read -r r; do
    if [ -n "$r" ] && [ "$r" != "$project" ] && is_holder "$reg" "$r"; then kinds=""; fi
  done <<EOF
$(project_holders "$root")
EOF
fi

if [ -n "$kinds" ]; then
  kind=$(printf '%s' "$first" | sed -E 's/^[[:space:]*_#>`-]*//' | sed -nE 's/^(RESULT|QUESTION|BLOCKED|ANSWER):.*/\1/p')
  if [ -z "$kind" ]; then
    {
      echo "Not sent. Message \"$recipient\" only when it changes what they do, with the kind as the first word:"
      echo "  RESULT: a milestone done (PR ready, task finished), with its link and what you verified"
      echo "  QUESTION: a decision you need, with your recommendation"
      echo "  BLOCKED: what stops you and what would unblock it"
      echo "  ANSWER: a reply to something \"$recipient\" asked you"
      echo "Acknowledgements, \"still waiting\", restated instructions and FYIs that change nothing are not sent: each one"
      echo "wakes \"$recipient\" for nothing. If none of the four fits, keep working and report at the next milestone."
    } >&2
    exit 2
  fi
fi

# A worker's last report lives beside its record, which retire.sh clears; any other sender's, under its session id.
if is_worker "$name" "$cwd"; then
  last="$holders/workers/$name.last-report"
else
  mkdir -p "$holders/reports" 2>/dev/null || exit 0
  last="$holders/reports/$sid"
  find "$holders/reports" -type f -mtime +7 -exec rm -f {} + 2>/dev/null || true
fi
if [ "$(cat "$last" 2>/dev/null)" = "$first" ]; then
  echo "Not sent: its first line repeats your last message to \"$recipient\". Send again only when something changed, and say what." >&2
  exit 2
fi
printf '%s\n' "$first" >| "$last" 2>/dev/null || true
exit 0
