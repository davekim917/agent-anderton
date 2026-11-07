#!/usr/bin/env bash
# List the live Claude Code sessions in the caller's repository (every repository with --all) that are
# waiting on a person: their turn ended with Claude talking, or it is blocked on a prompt. The
# sessions holding an Anderton role in the caller's repository, its own or a named project's, are left out,
# and so are the workers spawn.sh started, which report to them, unless one is blocked on a prompt: a
# session held there cannot send a report. Only the repository's holder always stays out. Called from a
# session holding a role, it lists only the sessions that role answers for. With --blocked, for watch.sh,
# it prints one header line per session blocked on a person. Then come the You Should Know notes not yet
# reported.
# Portable to macOS's bash 3.2 and BSD userland: jq does the date arithmetic, not date -d.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

require_tools waiting.sh

all=""
blocked=""
for arg in "$@"; do
  case $arg in
    --all) all=1 ;;
    --blocked) blocked=1 ;;
    *) echo "usage: waiting.sh [--all] [--blocked]" >&2; exit 2 ;;
  esac
done

judged=""
root=$(invoking_root)
project=$(holder_record "$root")
records=$(project_holders "$root")

# The role the caller holds, if any. A named project's Anderton answers only for the workers it started; the
# repository's answers for every other session, and for a project's workers once that project's Anderton is gone.
caller="${CLAUDE_PID:-}"
if [ -z "$caller" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then caller=$(session_pid "$CLAUDE_CODE_SESSION_ID"); fi
mine=""
if [ -n "$caller" ]; then
  while IFS= read -r r; do
    if [ -n "$r" ] && is_holder "$sessions/$caller.json" "$r"; then mine=$r; fi
  done <<EOF
$records
EOF
fi
answering_role() { # answering_role <session name> <cwd>: the record of the role that answers for that session
  local spawner r hp
  if is_worker "$1" "$2"; then
    spawner=$(jq -r '.spawner // empty' "$holders/workers/$1.json" 2>/dev/null || true)
    while IFS= read -r r; do
      if [ -z "$r" ] || [ "$r" = "$project" ] || [ -z "$spawner" ]; then continue; fi
      hp=$(jq -r '.pid // empty' "$r" 2>/dev/null || true)
      if [ -n "$hp" ] && [ "$(jq -r '.name // empty' "$sessions/$hp.json" 2>/dev/null || true)" = "$spawner" ] &&
        is_holder "$sessions/$hp.json" "$r"; then
        printf '%s\n' "$r"
        return
      fi
    done <<EOF
$records
EOF
  fi
  printf '%s\n' "$project"
}
answers_for() { # answers_for <session name> <cwd>: true when the caller's role answers for that session
  [ -z "$mine" ] || [ "$(answering_role "$1" "$2")" = "$mine" ]
}

for s in "$sessions"/*.json; do
  [ -e "$s" ] || continue
  fields=$(jq -r '[(.pid // "" | tostring), (.startedAt // "" | if type == "number" then floor | tostring else . end), .sessionId // "", .cwd // "", .name // ""] | join("\u001f")' "$s" 2>/dev/null) || continue
  IFS=$'\x1f' read -r pid start sid cwd name <<EOF
$fields
EOF
  if [ -z "$pid" ] || [ -z "$sid" ]; then continue; fi
  status=$(jq -r '.status // ""' "$s" 2>/dev/null) || continue
  held=""
  while IFS= read -r r; do
    if [ -n "$r" ] && is_holder "$s" "$r"; then held=$r; fi
  done <<EOF
$records
EOF
  if [ -n "$held" ] && { [ "$status" != waiting ] || [ "$held" = "$project" ]; }; then continue; fi
  tag=""
  if is_worker "$name" "$cwd"; then
    [ "$status" = waiting ] || continue
    tag=" (worker)"
  fi
  if [ -n "$blocked" ] && [ "$status" != waiting ]; then continue; fi
  if [ -z "$all" ] && { [ -z "$cwd" ] || [ "$(project_root "$cwd")" != "$root" ]; }; then
    continue
  fi
  registered_alive "$pid" "$start" || continue
  judged="$judged $sid"
  answers_for "$name" "$cwd" || continue

  transcript=""
  for t in "$home"/projects/*/"$sid".jsonl; do
    if [ -e "$t" ]; then
      transcript=$t
      break
    fi
  done
  [ -n "$transcript" ] || continue

  # The registry's status is Claude Code's own record that the session is blocked on a person (a
  # permission prompt, AskUserQuestion), in its main thread or in a sub-agent, whose transcripts sit
  # under <session>/subagents/. Without that status, a main-thread tool call left unanswered for over
  # a minute is probably a permission prompt. Otherwise a turn that ended with Claude's text is waiting.
  # A registry that says busy rules out both: Claude writes each block as it finishes, so a turn
  # that is still running can end in text for a while. Reading only the tails is safe: tool results
  # alternate with assistant entries, so the entries that decide this are within the final few lines.
  {
    tail -n 1000 "$transcript"
    if [ -d "${transcript%.jsonl}/subagents" ]; then
      find "${transcript%.jsonl}/subagents" -name '*.jsonl' -mmin -2880 2>/dev/null | while read -r f; do
        printf '\n{"subagent":"%s"}\n' "$(basename "$f" .jsonl)"
        tail -n 200 "$f"
      done
    fi
  } | jq -nrR --slurpfile reg "$s" --arg name "${name:-${sid%%-*}}${tag}" --arg cwd "$cwd" --arg blocked "$blocked" '
    def blocks: .message.content | if type == "string" then [{type: "text", text: .}] elif type == "array" then . else [] end;
    def human: .type == "user" and (.isMeta | not)
      and (blocks | all(.[]; .type != "tool_result"))
      and (blocks | any(.[]; .type == "image")
           or ([.[] | select(.type == "text") | .text // ""] | join("\n")
               | gsub("<(?<t>task-notification|system|system-reminder|local-command-stdout|local-command-caveat)>[\\s\\S]*?</\\k<t>>"; "")
               | test("\\S")));
    def said: [.message.content[]? | select(.type == "text") | .text] | join("\n");
    def answers: [.message.content[]? | objects | select(.type == "tool_result")] | length > 0;
    def track($e): reduce ($e.message.content[]? | objects) as $c (.;
        if $c.type == "tool_use" and $e.type == "assistant" then
          .open[$c.id // "?"] = {name: $c.name, input: $c.input, at: $e.timestamp, agent: .agent}
        elif $c.type == "tool_result" then del(.open[$c.tool_use_id // "?"])
        else . end);
    def seconds: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    def calls: map((if .agent then "[sub-agent \(.agent)] " else "" end)
      + "\(.name) (pending \(.pending)s): \(.input | tojson | .[0:200])") | join("\n");
    $reg[0] as $r
    | now as $now
    | ($now - 2 * 86400 | todate) as $since
    | reduce (inputs | fromjson? | objects) as $e ({last: null, said: "", open: {}, agent: null};
        if $e.subagent then .agent = $e.subagent
        elif ($e.timestamp // "") <= $since then .
        elif .agent != null then track($e)
        elif $e.isSidechain then .
        elif $e.type == "assistant" then
          .last = $e | (if ($e | said) != "" then .said = ($e | said) else . end) | track($e)
        elif $e | human then .last = $e | .said = ""
        elif $e | answers then .last = $e | track($e)
        else . end)
    | ([.open[] | . + {pending: ($now - (.at | seconds) | floor)}] | sort_by(-.pending)) as $open
    | ([$open[] | select(.agent == null and .pending > 60)]) as $stuck
    | if $r.status == "waiting" then
        ([$open[] | select(.name == "AskUserQuestion") | .input.questions[]?
          | "\(.question) [\([.options[]?.label] | join(" / "))]"] | join("\n")) as $ask
        | (if $r.statusUpdatedAt then ", since \($r.statusUpdatedAt / 1000 | floor | todate)" else "" end) as $when
        | "=== \($name)  \($cwd)  (waiting: \($r.waitingFor // "input")\($when))"
          + (if $blocked != "" then "" elif $ask != "" then "\n\($ask)\n"
             else "\n" + ([($open | calls), .said[-900:]] | map(select(. != "")) | join("\n")) + "\n" end)
      elif $r.status != "busy" and ($stuck | length) > 0 then
        "=== \($name)  \($cwd)  PERMISSION PROMPT? (pending \($stuck[0].pending)s)\n\($stuck | calls)\n"
      elif $r.status != "busy" and .last.type == "assistant" and (.last | said) != ""
           and all(.last.message.content[]; .type != "tool_use") then
        "=== \($name)  \($cwd)  (last reply \(.last.timestamp))\n\(.said[-900:])\n"
      else empty end' ||
    echo "waiting.sh: could not read $transcript" >&2
done

# The You Should Know plugin's notes it has seen and not marked known. Its store is a private format, so a store
# of any other shape makes jq fail, and prints nothing.
you_should_know() {
  local f notes=""
  for f in "$home"/plugins/store/cc-plugin-you-should-know_builtin-*.json; do
    [ -f "$f" ] || continue
    notes="$notes$(jq -r '(.seen - .known)[] | strings | "- " + gsub("\\s+"; " ")' "$f" 2>/dev/null || true)"
  done
  if [ -n "$notes" ]; then printf '=== You Should Know, not yet reported\n%s\n' "$notes"; fi
}
[ -n "$blocked" ] || you_should_know

# A background session can have no registry entry; `claude agents --json` reports each with a state. A blocked
# one waits on a person however long ago it stopped; a done one is listed while its turn is recent.
command -v claude >/dev/null 2>&1 || exit 0
claude agents --json 2>/dev/null |
  jq -r '.[]? | select(.kind == "background" and (.state == "blocked" or .state == "done"))
    | [.name // "", .sessionId // "", .cwd // "", .state] | join("\u001f")' 2>/dev/null |
  while IFS=$'\x1f' read -r name sid cwd state; do
    [ -n "$sid" ] || continue
    case "$judged " in *" $sid "*) continue ;; esac
    tag=""
    if is_worker "$name" "$cwd"; then
      [ "$state" = blocked ] || continue
      tag=" (worker)"
    fi
    if [ -n "$blocked" ] && [ "$state" != blocked ]; then continue; fi
    if [ -z "$all" ] && { [ -z "$cwd" ] || [ "$(project_root "$cwd")" != "$root" ]; }; then
      continue
    fi
    answers_for "$name" "$cwd" || continue
    for t in "$home"/projects/*/"$sid".jsonl; do
      [ -e "$t" ] || continue
      tail -n 400 "$t" | jq -nrR --arg name "${name:-${sid%%-*}}${tag}" --arg cwd "$cwd" --arg state "$state" --arg blocked "$blocked" '
        [inputs | fromjson? | objects] as $e
        | ([$e[] | select(.type == "assistant")
            | [.message.content[]? | objects | select(.type == "text") | .text] | join("\n")
            | select(. != "")] | last // "") as $said
        | ([$e[] | .timestamp // empty] | last // "") as $at
        | (reduce $e[] as $x ({}; reduce ($x.message.content[]? | objects) as $c (.;
            if $c.type == "tool_use" and $x.type == "assistant" then .[$c.id // "?"] = {name: $c.name, input: $c.input}
            elif $c.type == "tool_result" then del(.[$c.tool_use_id // "?"])
            else . end))) as $open
        | ([$open[] | select(.name == "AskUserQuestion") | .input.questions[]?
            | "\(.question) [\([.options[]?.label] | join(" / "))]"] | join("\n")) as $ask
        | ([$open[] | select(.name != "AskUserQuestion") | "\(.name) (pending): \(.input | tojson | .[0:200])"]
            | join("\n")) as $calls
        | if $state == "done" and $at < (now - 2 * 86400 | todate) then empty
          else "=== \($name)  \($cwd)  (background, \($state)\(if $at != "" then " since \($at)" else "" end))"
            + (if $blocked != "" then "" elif $ask != "" then "\n\($ask)\n"
               else "\n" + ([$calls, $said[-900:]] | map(select(. != "")) | join("\n")) + "\n" end)
          end' || echo "waiting.sh: could not read $t" >&2
      break
    done
  done
