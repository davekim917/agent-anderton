#!/usr/bin/env bash
# Read the permission prompt a session is blocked on, from its herdr tab or tmux pane, and answer it on the user's word.
# Claude Code has no way to answer another session's prompt, so the screen is the only place to read one and a key
# press the only way to answer it. Only a session holding an Anderton role in the target's project may run this. That
# stops a mistake, not an attacker: a session running without permission checks can press keys by other means.
# usage: prompt.sh <name>                         prints the prompt and its fingerprint
#        prompt.sh <name> yes|no <fingerprint>    answers that exact prompt: yes allows this one call, no refuses it
# Exit 0: done. 2: bad usage. 3: refused, nothing pressed. 4: pressed, and the screen does not confirm the prompt closed.
# Portable to macOS's bash 3.2 and BSD userland.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

require_tools prompt.sh
usage="usage: prompt.sh <name> [yes|no <fingerprint>]"
name="${1:-}" answer="${2:-}" expected="${3:-}"
if [ -z "$name" ] || [ $# -gt 3 ]; then
  echo "$usage" >&2
  exit 2
fi
case $answer in
  '') [ -z "$expected" ] || { echo "$usage" >&2; exit 2; } ;;
  yes | no) [ -n "$expected" ] || { echo "$usage" >&2; exit 2; } ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

refuse() {
  echo "prompt.sh: $* Nothing was pressed." >&2
  exit 3
}

# The dialog the screen on stdin ends in, or nothing. It must be the last thing on the screen, so an answered prompt
# in the scrollback never counts. Its top rule must show, so a dialog taller than the screen is never answered
# half-read. Its last cursor must sit on a plain "1. Yes", the one option that allows this call and nothing
# more: Enter then cannot pick "always allow" or "don't ask again". The options come last, so the last cursor is the
# real one; a description above them is model-written. A dialog's rules start at column 0 and its contents are
# indented, so a rule a model writes into a command cannot pass for its edge.
prompt_block() {
  LC_ALL=C awk -v rule="──────────" '
    { raw[NR] = $0; sub(/[ \t\r]+$/, ""); line[NR] = $0 }
    END {
      end = NR
      while (end > 0 && (line[end] == "" || index(line[end], rule) == 1)) end--
      if (end == 0 || line[end] !~ /^ *Esc to cancel/) exit
      start = end
      while (start > 0 && index(line[start], rule) != 1) start--
      if (start == 0) exit
      cursor = ""
      for (i = start + 1; i <= end; i++) {
        t = line[i]
        sub(/^ */, "", t)
        if (index(t, "❯") == 1) cursor = t
      }
      if (cursor !~ /^❯ +1\. +Yes$/) exit
      for (i = start + 1; i <= end; i++) print raw[i]
    }'
}

# A dialog taller than its screen has lost its top, and no read brings it back: tmux's history holds only older
# frames, whose rules would pass for its edge, and herdr refuses to read further while the agent is blocked. For such a
# screen this prints one part of what is left: "command", the lines above the last dashed rule, or "options", from
# there down to "Esc to cancel", which starts with the reason a permission rule or a hook gave for asking. The cursor
# rule is prompt_block's, among the lines after the question. Dashed rules, like solid ones, start at column 0 and a command's lines
# are indented, so a rule a model writes cannot end the command early.
clipped_dialog() {
  LC_ALL=C awk -v rule="──────────" -v dash="╌╌╌╌╌╌╌╌╌╌" -v part="$1" '
    { raw[NR] = $0; sub(/[ \t\r]+$/, ""); line[NR] = $0 }
    END {
      end = NR
      while (end > 0 && (line[end] == "" || index(line[end], rule) == 1)) end--
      if (end == 0 || line[end] !~ /^ *Esc to cancel/) exit
      options = end
      while (options > 0 && index(line[options], dash) != 1) options--
      if (options == 0) exit
      question = options + 1
      while (question < end && line[question] !~ /^ *Do you want to proceed\?$/) question++
      cursor = ""
      for (i = question + 1; i <= end; i++) {
        t = line[i]
        sub(/^ */, "", t)
        if (index(t, "❯") == 1) cursor = t
      }
      if (cursor !~ /^❯ +1\. +Yes$/) exit
      top = options - 1
      while (top > 0 && index(line[top], dash) != 1) top--
      if (part == "command") { for (i = top + 1; i < options; i++) print raw[i] }
      else { for (i = options + 1; i <= end; i++) print raw[i] }
    }'
}

# Every tool call the session's transcripts leave unanswered, one JSON object a line: its own, and those of its
# sub-agents and workflow agents, which ask through its screen. A transcript that can't be read counts as a call of
# unknown kind, since it could be hiding one.
unanswered_calls() {
  local t f
  for t in "$home"/projects/*/"$sid".jsonl; do
    [ -f "$t" ] || continue
    { printf '%s\n' "$t"; find "${t%.jsonl}/subagents" -name 'agent-*.jsonl' -mmin -2880 2>/dev/null || true; } |
      while IFS= read -r f; do
        tail -n 1000 "$f" | jq -sc '
          [.[] | select(.type == "user") | .message.content | arrays | .[] | select(.type? == "tool_result") | .tool_use_id] as $done
          | .[] | select(.type == "assistant") | .message.content | arrays | .[] | select(.type? == "tool_use")
          | select(.id as $id | ($done | index($id)) == null)' 2>/dev/null || echo '{"name":"unreadable"}'
      done
    return 0
  done
}

# The one Bash call waiting whose command ends with the lines on screen ($1), which ignores the terminal's wrapping,
# indents and gutter. Nothing when none or several do, or when a call of another kind is waiting: a clipped dialog
# hides its title, so it could be that call. Agent, Task and Workflow only wait on calls of their own.
matching_call() {
  unanswered_calls | jq -sc --arg shown "$1" '
    def squeezed: gsub("[[:space:]│]"; "");
    ($shown | squeezed) as $tail
    | if $tail == "" or any(.[]; .name as $n | ["Bash", "Agent", "Task", "Workflow"] | index($n) == null) then empty
      else [.[] | select(.name == "Bash" and (.input.command | type) == "string" and (.input.command | squeezed | endswith($tail)))]
        | if length == 1 then .[0] else empty end
      end' 2>/dev/null || true
}

# Sets $text and $call to the full prompt of a dialog taller than $screen, from the session's transcript, and $clipped
# when the screen shows such a dialog.
# Only a Bash command, whose exact text the transcript records.
read_clipped() {
  local shown options pending
  options=$(printf '%s\n' "$screen" | clipped_dialog options)
  [ -n "$options" ] || return 0
  clipped=1
  shown=$(printf '%s\n' "$screen" | clipped_dialog command)
  pending=$(matching_call "$shown")
  [ -n "$pending" ] || return 0
  call=$(printf '%s' "$pending" | jq -r '.id')
  text=$(printf ' Bash command, read in full from the session'"'"'s transcript: its dialog is taller than the screen\n %s\n\n%s\n\n%s' \
    "$(printf '%s' "$pending" | jq -r '.input.description // empty')" "$(printf '%s' "$pending" | jq -r '.input.command')" "$options")
}

# True when the screen on stdin ends in a dialog of any kind, answerable or not.
dialog_showing() {
  LC_ALL=C awk -v rule="──────────" '
    { sub(/[ \t\r]+$/, ""); if ($0 != "" && index($0, rule) != 1) last = $0 }
    END { exit !(last ~ /^ *Esc to cancel/) }'
}

read_screen() {
  case $mux in
    herdr) herdr agent read "$pane" --source visible --format text ;;
    tmux) tmux capture-pane -p -N -t "$pane" ;;
  esac
}

# The prompt's identity: the same text in a later prompt, or in another session or pane, reads differently.
fingerprint() {
  printf '%s\n%s\n%s\n%s\n%s\n' "$sid" "$since" "$pane" "$call" "$text" | sha256 | cut -d' ' -f1
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
}

# True when this session holds an Anderton role in project $1.
caller_holds_role() {
  local pid rec
  pid="${CLAUDE_PID:-}"
  if [ -z "$pid" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then pid=$(session_pid "$CLAUDE_CODE_SESSION_ID"); fi
  [ -n "$pid" ] || return 1
  while IFS= read -r rec; do
    if is_holder "$sessions/$pid.json" "$rec"; then return 0; fi
  done <<EOF
$(project_holders "$1")
EOF
  return 1
}

# Sets $mux and $pane to where the session with id $sid and pid $spid runs: the herdr agent carrying that session
# id, else the tmux pane its process descends from. Either way the pane is proven by the session, never by a name.
find_pane() {
  local listed p
  mux="" pane=""
  if command -v herdr >/dev/null 2>&1 && listed=$(herdr agent list 2>/dev/null); then
    pane=$(printf '%s' "$listed" |
      jq -r --arg s "$sid" '[.result.agents[]? | select(.agent_session.value == $s) | .pane_id] | if length == 1 then .[0] else empty end' 2>/dev/null) || pane=""
    if [ -n "$pane" ]; then
      mux=herdr
      return
    fi
  fi
  if command -v tmux >/dev/null 2>&1 && listed=$(tmux list-panes -a -F '#{pane_pid} #{pane_id}' 2>/dev/null); then
    p=$spid
    while [ -n "$p" ] && [ "$p" -gt 1 ]; do
      pane=$(printf '%s\n' "$listed" | awk -v p="$p" '$1 == p { print $2; exit }')
      if [ -n "$pane" ]; then
        mux=tmux
        return
      fi
      p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ') || p=""
    done
  fi
}

load_session() {
  local f found=""
  for f in "$sessions"/*.json; do
    [ -f "$f" ] || continue
    [ "$(jq -r '.name // empty' "$f" 2>/dev/null)" = "$name" ] || continue
    registered_alive "$(jq -r '.pid // empty' "$f")" "$(jq -r '.startedAt // empty | floor' "$f")" "$(jq -r '.procStart // empty' "$f" 2>/dev/null)" || continue
    [ -z "$found" ] || refuse "More than one live session is named $name."
    found=$f
  done
  [ -n "$found" ] || refuse "No live session is named $name."
  reg=$found
  sid=$(jq -r '.sessionId // empty' "$reg")
  spid=$(jq -r '.pid' "$reg")
  cwd=$(jq -r '.cwd // empty' "$reg")
  since=$(jq -r '.statusUpdatedAt // empty' "$reg")
}

load_session
root=$(invoking_root)
caller_holds_role "$root" || refuse "Only the session holding an Anderton role in this project may answer a prompt."
[ "$(project_root "${cwd:-/}")" = "$root" ] || refuse "$name is in another project."
if [ "$(jq -r '.kind // empty' "$reg")" = bg ]; then
  refuse "$name runs in the background with no tab: answer it with claude attach $name."
fi
if [ "$(jq -r '.status // empty' "$reg")" != waiting ] || [ "$(jq -r '.waitingFor // empty' "$reg")" != "permission prompt" ]; then
  refuse "$name is not blocked on a permission prompt."
fi
find_pane
[ -n "$pane" ] || refuse "$name is not in a herdr tab or tmux pane this session can reach: open its tab."
screen=$(read_screen 2>/dev/null) || refuse "Could not read $name's screen: open its tab."
text=$(printf '%s\n' "$screen" | prompt_block)
call="" clipped=""
[ -n "$text" ] || read_clipped
if [ -z "$text" ] && [ -n "$clipped" ]; then
  refuse "$name's dialog is taller than its screen and its transcript does not show the full command: open its tab."
fi
[ -n "$text" ] || refuse "$name does not show a prompt this can answer: open its tab."
print=$(fingerprint)

if [ -z "$answer" ]; then
  printf 'Session: %s\nDirectory: %s\n\n%s\n\nFingerprint: %s\n' "$name" "$cwd" "$text" "$print"
  exit 0
fi

[ "$print" = "$expected" ] || refuse "$name's prompt changed since it was read: read it again and show the user the new one."
case "$mux $answer" in
  "herdr yes") herdr agent send-keys "$pane" enter >/dev/null ;;
  "herdr no") herdr agent send-keys "$pane" esc >/dev/null ;;
  "tmux yes") tmux send-keys -t "$pane" Enter ;;
  "tmux no") tmux send-keys -t "$pane" Escape ;;
esac || refuse "The key press failed."

# The screen, not the press, says whether the prompt closed: no dialog is left, or the registry dates a new one. The
# same dialog can redraw with other line breaks, or stop parsing, so its text proves nothing either way.
for _ in 1 2 3 4; do
  sleep 1
  screen=$(read_screen 2>/dev/null) || break
  if printf '%s\n' "$screen" | dialog_showing && [ "$(jq -r '.statusUpdatedAt // empty' "$reg" 2>/dev/null)" = "$since" ]; then
    continue
  fi
  echo "Answered $answer: $name's prompt has closed."
  exit 0
done
echo "prompt.sh: The key was pressed, but the screen does not show $name's prompt closing. Open its tab." >&2
exit 4
