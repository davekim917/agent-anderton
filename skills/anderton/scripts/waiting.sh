#!/usr/bin/env bash
# List the live Claude Code sessions in the caller's repository (every repository with --all) that are
# waiting on a person: their turn ended with Claude talking, or it is blocked on a prompt. The
# sessions holding an Anderton role in the caller's repository, its own or a named project's, are always left
# out: each is a tab the user answers directly. So are the workers spawn.sh started, which report to them,
# unless one is blocked on a prompt: a session held there cannot send a report. Called from a session holding
# a role, it lists only the sessions that role answers for. With --blocked, for watch.sh,
# it prints one header line per session blocked on a person. Then come the You Should Know notes not yet
# reported.
# Portable to macOS's bash 3.2 and BSD userland: jq does the date arithmetic, not date -d.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

require_tools waiting.sh

all=""
blocked=""
worker_list=""
for arg in "$@"; do
  case $arg in
    --all) all=1 ;;
    --blocked) blocked=1 ;;
    --codex-workers) worker_list=codex ;;
    --transcript-workers) worker_list=transcript ;;
    --workers) worker_list=all ;;
    *) echo "usage: waiting.sh [--all] [--blocked | --codex-workers]" >&2; exit 2 ;;
  esac
done

judged=""
root=$(invoking_root)
records=$(project_holders "$root")

# The role the caller holds, if any. Each Anderton answers only for the workers it started, and the repository's also
# for a project's workers once that project's Anderton is gone. A session nobody started is a tab the user opened and
# reads, so no Anderton answers for it.
mine=$(caller_claim "$root")
answering_role() {
  local worker
  worker=$(worker_record "$@")
  if [ -n "$worker" ]; then answering_claim "$worker" "$root"; fi
}
held_by() { # held_by <session id>: true when an Anderton's record names that session
  local r
  while IFS= read -r r; do
    if [ -n "$r" ] && [ "$(jq -r '.sessionId // empty' "$r" 2>/dev/null)" = "$1" ]; then return 0; fi
  done <<EOF
$records
EOF
  return 1
}
answers_for() { # answers_for <name> <cwd> [session id] [pid] [start]: true when the caller's role answers for that session
  [ -z "$mine" ] || [ "$(answering_role "$@")" = "$mine" ]
}

if [ -n "$worker_list" ]; then
  [ -n "$mine" ] || exit 0
  for r in "$holders"/workers/*.json; do
    [ -f "$r" ] || continue
    case $worker_list in
      codex) [ "$(record_provider "$r")" = codex ] || continue ;;
      transcript) uses_claude_transcript "$r" "$(invoking_provider)" || continue ;;
    esac
    if worker_belongs "$r" "$root" "$mine"; then printf '%s\n' "$r"; fi
  done
  exit 0
fi

# Each entry is judged on one copy: Claude Code rewrites it as the session's status changes, and a session selected
# as blocked but rendered from a newer entry reads as a call unanswered for over a minute, a header the watch never
# reported. Without a temporary file it reads the entry in place, as before.
# The copy sits in this user's own Claude home, never a shared temporary directory another user could reach.
snapdir=$(mktemp -d "$holders/.waiting.XXXXXX" 2>/dev/null) || snapdir=""
entry=""
if [ -n "$snapdir" ]; then
  entry="$snapdir/entry"
  trap 'rm -rf "$snapdir" 2>/dev/null || true' EXIT
fi
for s in "$sessions"/*.json; do
  [ -e "$s" ] || continue
  src=$s
  if [ -n "$entry" ] && { cat <"$s" >|"$entry"; } 2>/dev/null; then src=$entry; fi
  fields=$(jq -r '[(.pid // "" | tostring), (.startedAt // "" | if type == "number" then floor | tostring else . end), .sessionId // "", .cwd // "", .name // "", .procStart // ""] | join("\u001f")' "$src" 2>/dev/null) || continue
  IFS=$'\x1f' read -r pid start sid cwd name pstart <<EOF
$fields
EOF
  if [ -z "$pid" ] || [ -z "$sid" ]; then continue; fi
  status=$(jq -r '.status // ""' "$src" 2>/dev/null) || continue
  held=""
  while IFS= read -r r; do
    if [ -n "$r" ] && is_holder "$s" "$r"; then held=$r; fi
  done <<EOF
$records
EOF
  if [ -n "$held" ]; then
    judged="$judged $sid"
    continue
  fi
  if [ -n "$blocked" ] && [ "$status" != waiting ]; then continue; fi
  tag=""
  if is_worker "$name" "$cwd" "$sid" "$pid" "$start"; then
    [ "$status" = waiting ] || continue
    tag=" (worker)"
  fi
  if [ -z "$all" ] && { [ -z "$cwd" ] || [ "$(project_root "$cwd")" != "$root" ]; }; then
    continue
  fi
  registered_alive "$pid" "$start" "$pstart" || continue
  judged="$judged $sid"
  answers_for "$name" "$cwd" "$sid" "$pid" "$start" || continue

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
  } | jq -nrR --slurpfile reg "$src" --arg name "${name:-${sid%%-*}}${tag}" --arg cwd "$cwd" --arg blocked "$blocked" '
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

# The workers the caller answers for whose work is finished, so none outlives its PR: its worktree is gone, its HEAD
# has landed on origin's default branch (as the cached remote ref has it: no fetch here), or a PR for its branch is
# merged or closed (gh, read-only, when it is installed). A busy worker is never listed; one with work retire.sh
# would keep is listed with that work named. Adopted sessions have no worktree of their own and are left out.
ago() { # ago <epoch seconds>
  local d=$(( $(date +%s) - $1 ))
  if [ "$d" -ge 86400 ]; then echo "$((d / 86400))d ago"
  elif [ "$d" -ge 3600 ]; then echo "$((d / 3600))h ago"
  elif [ "$d" -ge 60 ]; then echo "$((d / 60))m ago"
  else echo "just now"; fi
}
worker_busy() { # worker_busy <record>: true when a live session that is that worker is mid-turn, matched by its recorded
  # name or id, or by working inside its worktree, since a renamed worker is still the process retire.sh stops
  local name id dir
  name=$(jq -r '.name // empty' "$1")
  id=$(jq -r '.id // empty' "$1")
  dir=$(jq -r '.dir // empty' "$1")
  local bn bc
  while IFS=$'\x1f' read -r bn bc; do
    if [ -n "$bn$bc" ] && { [ "$bn" = "$name" ] || [ "$bc" = "$dir" ] || case $bc in "$dir"/*) true ;; *) false ;; esac; }; then return 0; fi
  done <<EOF
$busy_sessions
EOF
  printf '%s' "$agents_json" | jq -e --arg n "$name" --arg id "$id" --arg d "$dir" 'any(.[]?; .state == "working"
    and (.name == $n or ($id != "" and .id == $id) or ((.cwd // "") as $c | $c == $d or ($c | startswith($d + "/")))))' >/dev/null 2>&1
}
finished() { # finished <record>: prints why the worker's work is finished, "open" when a PR for it is open, or nothing
  local dir base head ref land at branch prs
  dir=$(jq -r '.dir // empty' "$1")
  [ -n "$dir" ] || return 0
  if [ ! -d "$dir" ]; then
    echo "worktree gone"
    return
  fi
  head=$(git_for_worktree -C "$dir" rev-parse -q --verify HEAD 2>/dev/null) || return 0
  base=$(jq -r '.base // empty' "$1")
  for ref in "$(git_for_worktree -C "$dir" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)" origin/main origin/master; do
    if [ -n "$ref" ] && git_for_worktree -C "$dir" rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1; then break; fi
    ref=""
  done
  # Any open PR for its branch, whatever it targets, means the work is not finished; only a PR whose head is the
  # worktree's HEAD settles it otherwise, since a branch reused after its PR merged holds newer work.
  branch=$(git_for_worktree -C "$dir" symbolic-ref -q --short HEAD 2>/dev/null || true)
  prs=""
  if [ -n "$branch" ] && command -v gh >/dev/null 2>&1; then
    prs=$(cd "$dir" && gh pr list --head "$branch" --state all --limit 20 --json number,state,mergedAt,closedAt,headRefOid 2>/dev/null) || prs=""
    if printf '%s' "$prs" | jq -e 'any(.[]?; .state == "OPEN")' >/dev/null 2>&1; then
      echo open
      return 0
    fi
  fi
  # A worker still at the commit it started from has landed nothing.
  if [ -n "$ref" ] && [ "$head" != "$base" ] && git_for_worktree -C "$dir" merge-base --is-ancestor "$head" "$ref" 2>/dev/null; then
    # It landed in the oldest commit on the branch's first-parent line that contains it: a merge commit, or itself
    # when it was fast-forwarded or rebased in, and then the commit after it has it as first parent.
    land=$(git_for_worktree -C "$dir" rev-list --first-parent --ancestry-path "$head..$ref" 2>/dev/null | tail -n 1)
    if [ -z "$land" ] || [ "$(git_for_worktree -C "$dir" rev-parse -q --verify "$land^1" 2>/dev/null)" = "$head" ]; then land=$head; fi
    at=$(git_for_worktree -C "$dir" log -1 --format=%ct "$land" 2>/dev/null || true)
    echo "branch merged into $ref${at:+ $(ago "$at")}"
    return
  fi
  [ -n "$prs" ] || return 0
  printf '%s' "$prs" | jq -r --arg head "$head" 'map(select(.headRefOid == $head))
    | if length == 0 then empty
    else (map(select(.state == "MERGED")) + map(select(.state != "MERGED")))[0]
      | "PR #\(.number) \(.state | ascii_downcase)\t\((if .state == "MERGED" then .mergedAt else .closedAt end) // "" | sub("[.][0-9]+Z$"; "Z") | fromdateiso8601? // "")" end' 2>/dev/null |
    while IFS=$'\t' read -r what at; do echo "$what${at:+ $(ago "$at")}"; done
}
last_activity() { # last_activity <record>: epoch seconds of the newest transcript entry of any session that may be
  # that worker (by name, id, or a cwd inside its worktree), else of its start; nothing when neither is known
  local name id dir sids sid t at start best=""
  name=$(jq -r '.name // empty' "$1")
  id=$(jq -r '.id // empty' "$1")
  dir=$(jq -r '.dir // empty' "$1")
  sids=$( { printf '%s\n' "$registry_entries"; printf '%s' "$agents_json" | jq -c '.[]?' 2>/dev/null || true; } |
    jq -rR --arg n "$name" --arg id "$id" --arg d "$dir" 'fromjson? | objects
      | select(.name == $n or ($id != "" and .id == $id) or ((.cwd // "") as $c | $c == $d or ($c | startswith($d + "/"))))
      | .sessionId // empty' 2>/dev/null | sort -u || true)
  for sid in $sids; do
    for t in "$home"/projects/*/"$sid".jsonl; do
      [ -e "$t" ] || continue
      at=$(tail -n 200 "$t" | jq -rR 'fromjson? | .timestamp? // empty | strings' 2>/dev/null | sort | tail -n 1 |
        jq -rR 'sub("[.][0-9]+Z$"; "Z") | fromdateiso8601? // empty' 2>/dev/null || true)
      if [ -n "$at" ] && { [ -z "$best" ] || [ "$at" -gt "$best" ]; }; then best=$at; fi
    done
  done
  # A session left by an earlier worker of the same name predates this one, so activity counts from its start at most.
  start=$(jq -r '.startedAt // empty | strings | fromdateiso8601? // empty' "$1" 2>/dev/null || true)
  if [ -n "$start" ] && { [ -z "$best" ] || [ "$start" -gt "$best" ]; }; then best=$start; fi
  if [ -n "$best" ]; then echo "$best"; fi
}
ready_to_retire() {
  local r f name dir why at pid start pstart bname bcwd provider lines="" claude_ready=1
  # Without the list of background sessions, which have no registry entry, a busy one would read as idle.
  if ! agents_json=$(claude agents --json 2>/dev/null) || ! printf '%s' "$agents_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    claude_ready=""
    echo "waiting.sh: claude agents failed, so no Claude worker is judged ready to retire" >&2
  fi
  # Every registry entry on one line each, for last_activity: Claude Code writes each file as one line.
  registry_entries=$(for f in "$sessions"/*.json; do if [ -e "$f" ]; then cat "$f"; echo; fi; done)
  # Only the few registry files that say busy are read in full.
  busy_sessions=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    IFS=$'\x1f' read -r pid start pstart bname bcwd <<EOF
$(jq -r '[(.pid // "" | tostring), (.startedAt // "" | if type == "number" then floor | tostring else . end), .procStart // "", .name // "", .cwd // ""] | join("\u001f")' "$f" 2>/dev/null || true)
EOF
    if [ -n "$pid" ] && registered_alive "$pid" "$start" "$pstart"; then busy_sessions="$busy_sessions$bname$(printf '\037')$bcwd
"; fi
  done <<EOF
$(grep -lE '"status"[[:space:]]*:[[:space:]]*"busy"' "$sessions"/*.json 2>/dev/null || true)
EOF
  for r in "$holders"/workers/*.json; do
    [ -f "$r" ] || continue
    [ "$(jq -r '.worktree == true and (.adopted // false) == false' "$r" 2>/dev/null)" = true ] || continue
    name=$(jq -r '.name // empty' "$r")
    dir=$(jq -r '.dir // empty' "$r")
    if [ -z "$name" ] || [ -z "$dir" ]; then continue; fi
    if [ -z "$all" ] && [ "$(jq -r '.root // empty' "$r")" != "$root" ]; then continue; fi
    [ -z "$mine" ] || worker_belongs "$r" "$root" "$mine" || continue
    provider=$(jq -r '.provider // "claude"' "$r")
    agy_safe_git=""
    if [ "$provider" = codex ]; then
      "$(dirname "$0")/codex-worker.py" inactive "$r" || continue
    elif [ "$provider" = agy ]; then
      # Listed only when it has stopped, or herdr shows it idle: a read that fails must not look like readiness.
      agy_check "$r"
      case $agy_state:$agy_status in
        stopped:* | running:idle | running:done) ;;
        *) continue ;;
      esac
      # Host git reads its worktree below: only one still pointing into its repository, and with no helpers.
      if [ -d "$dir" ] && ! agy_git_pointer_ok "$r"; then
        lines="$lines- $name: its .git no longer points into its repository; inspect it before retiring
"
        continue
      fi
      agy_git_safe
    elif [ -z "$claude_ready" ] || worker_busy "$r"; then
      continue
    fi
    why=$(finished "$r" || true)
    # A PR still open is work in flight, however long it waits on review.
    if [ "$why" = open ]; then continue; fi
    # Work done in some other worktree leaves this one at its base, so a worker idle a day is listed too.
    if [ -z "$why" ] && [ "$provider" = claude ]; then
      at=$(last_activity "$r" || true)
      if [ -n "$at" ] && [ $(( $(date +%s) - at )) -ge 86400 ]; then
        why="idle $(( ($(date +%s) - at) / 86400 ))d, no finished work found — check its PR"
      fi
    fi
    [ -n "$why" ] || continue
    if [ -d "$dir" ]; then
      case $(worktree_work "$dir" "$(jq -r '.base // empty' "$r")") in
        uncommitted) why="$why, but has uncommitted work" ;;
        unpushed) why="$why, but has commits no remote branch has" ;;
        flagged) why="$why, but git marks files in it assume-unchanged or skip-worktree, so retire.sh will keep it" ;;
        unreadable) why="$why, but git could not read its worktree, so retire.sh will keep it" ;;
      esac
    fi
    lines="$lines- $name: $why
"
  done
  agy_safe_git=""
  if [ -n "$lines" ]; then printf '=== Ready to retire (run retire.sh <name>)\n%s' "$lines"; fi
}
[ -n "$blocked" ] || ready_to_retire

if [ -n "$mine" ] && { [ -z "$blocked" ] || [ -n "${ANDERTON_PENDING_PROBE_STAGE:-}" ]; }; then
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    name=$(jq -r .name "$r")
    id=$(jq -r '.id // empty' "$r")
    if [ -z "$id" ]; then
      [ -n "$blocked" ] || printf '=== %s (Codex, waiting for thread registration)\n' "$name"
      continue
    fi
    if [ -n "$blocked" ]; then
      "$anderton_scripts/codex-worker.py" blocker-during-notice "$r" "$ANDERTON_PENDING_PROBE_STAGE" "$ANDERTON_BLOCKER_BOOKMARKS" || true
      continue
    fi
    if ! state=$("$anderton_scripts/codex-worker.py" state "$r" 2>/dev/null); then
      printf '=== %s (Codex %s, status unavailable)\n' "$name" "$id"
      continue
    fi
    flags=$(printf '%s' "$state" | jq -r '[.activeFlags[]? |
      if . == "waitingOnApproval" then "approval" elif . == "waitingOnUserInput" then "user input" else empty end] | join(" and ")')
    if [ -n "$flags" ]; then
      printf '=== %s (Codex %s, waiting on %s)\nOpen its worker pane to respond.\n' "$name" "$id" "$flags"
    fi
  done <<EOF
$("$anderton_scripts/waiting.sh" --codex-workers)
EOF
fi

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
    if held_by "$sid"; then continue; fi
    tag=""
    if is_worker "$name" "$cwd" "$sid"; then
      [ "$state" = blocked ] || continue
      tag=" (worker)"
    fi
    if [ -n "$blocked" ] && [ "$state" != blocked ]; then continue; fi
    if [ -z "$all" ] && { [ -z "$cwd" ] || [ "$(project_root "$cwd")" != "$root" ]; }; then
      continue
    fi
    answers_for "$name" "$cwd" "$sid" || continue
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
