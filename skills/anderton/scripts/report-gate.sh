#!/usr/bin/env bash
# The plugin's PreToolUse hook on SendMessage. In a worker spawn.sh started, it holds a message to the session that
# started it unless the message's first line opens with RESULT:, QUESTION:, BLOCKED: or ANSWER:, or when it repeats
# the first line of the worker's last report. Each message wakes that session and re-reads its whole context, so an
# acknowledgement or a "still waiting" costs as much as a result. It only ever blocks (exit 2, the reason on
# stderr): it never prints a decision, so it cannot approve anything. Anywhere else, and on any failure, it exits 0
# and prints nothing.
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
if [ -z "$sid" ] || [ -z "$to" ] || [ -z "$first" ]; then exit 0; fi

pid=$(session_pid "$sid")
[ -n "$pid" ] || exit 0
name=$(jq -r '.name // empty' "$sessions/$pid.json" 2>/dev/null)
is_worker "$name" "$cwd" || exit 0
record="$holders/workers/$name.json"
spawner=$(jq -r '.spawner // empty' "$record" 2>/dev/null)
[ -n "$spawner" ] || exit 0

# The spawner by name, by name with its listing ref, or by the socket address a reply copies from its message.
target=""
case $to in
  "$spawner" | "$spawner ["*) target=1 ;;
  uds:*.sock)
    sock=${to##*/}
    sock=${sock%.sock}
    for f in "$sessions"/*.json; do
      [ -e "$f" ] || continue
      if [ "$(jq -r '"\(.pid // "")\u001f\(.name // "")"' "$f" 2>/dev/null)" = "$sock"$'\x1f'"$spawner" ]; then
        target=1
        break
      fi
    done
    ;;
esac
[ -n "$target" ] || exit 0

kind=$(printf '%s' "$first" | sed -E 's/^[[:space:]*_#>`-]*//' | sed -nE 's/^(RESULT|QUESTION|BLOCKED|ANSWER):.*/\1/p')
if [ -z "$kind" ]; then
  {
    echo "Not sent. Message \"$spawner\" only when it changes what they do, with the kind as the first word:"
    echo "  RESULT: a milestone done (PR ready, task finished), with its link and what you verified"
    echo "  QUESTION: a decision you need, with your recommendation"
    echo "  BLOCKED: what stops you and what would unblock it"
    echo "  ANSWER: a reply to something \"$spawner\" asked you"
    echo "Acknowledgements, \"still waiting\", restated instructions and FYIs that change nothing are not sent: each one"
    echo "wakes \"$spawner\" for nothing. If none of the four fits, keep working and report at the next milestone."
  } >&2
  exit 2
fi

last="$holders/workers/$name.last-report"
if [ "$(cat "$last" 2>/dev/null)" = "$first" ]; then
  echo "Not sent: its first line repeats your last message to \"$spawner\". Send again only when something changed, and say what." >&2
  exit 2
fi
printf '%s\n' "$first" >| "$last" 2>/dev/null || true
exit 0
