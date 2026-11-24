#!/usr/bin/env bash
# Read a Claude Code permission prompt from its herdr tab or tmux pane. Only an Anderton in the target's project
# can inspect it.
# usage: prompt.sh <name>
# Exit 0: inspected. 2: bad usage. 3: unavailable or refused.
# Portable to macOS's bash 3.2 and BSD userland.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

name="${1:-}"
case ${2:-} in
  yes | no)
    echo "prompt.sh is inspection-only. Answer the request directly in the session's Claude Code pane." >&2
    exit 2
    ;;
esac
if [ "$#" -ne 1 ] || [ -z "$name" ]; then
  echo "usage: prompt.sh <name>" >&2
  exit 2
fi
require_tools prompt.sh

refuse() {
  echo "prompt.sh: $*" >&2
  exit 3
}

# The dialog the screen on stdin ends in, or nothing. It must be the last thing on the screen, so an answered prompt
# in the scrollback never counts. Its top rule and menu must be visible. A dialog's rules start at column 0 and its
# contents are indented, so a rule in command text cannot pass for its edge.
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
      question = 0
      for (i = start + 1; i <= end; i++) {
        t = line[i]
        sub(/^ */, "", t)
        if (t ~ /^Do you want to .+[?]$/) { question = i; cursor = "" }
        if (index(t, "❯") == 1) cursor = t
      }
      if (cursor !~ /^❯ +1\. +Yes$/ && (!question || cursor !~ /^❯ +[0-9]+\. +[^ ]/)) exit
      for (i = start + 1; i <= end; i++) print raw[i]
    }'
}

# A dialog taller than its screen has lost its top, and no read brings it back: tmux's history holds only older
# frames, whose rules would pass for its edge, and herdr refuses to read further while the agent is blocked. For such a
# screen this prints one part of what is left: "command", the lines above the last dashed rule, or "options", from
# there down to "Esc to cancel", which starts with the reason a permission rule or a hook gave for asking. The menu's
# cursor must follow the question. Dashed rules, like solid ones, start at column 0 and a command's lines
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
      if (cursor !~ /^❯ +[0-9]+\. +[^ ]/) exit
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

# Reconstructs $text for a dialog taller than $screen, and sets $clipped when the screen shows such a dialog.
# Only a Bash command, whose exact text the transcript records.
read_clipped() {
  local shown options pending
  options=$(printf '%s\n' "$screen" | clipped_dialog options)
  [ -n "$options" ] || return 0
  clipped=1
  shown=$(printf '%s\n' "$screen" | clipped_dialog command)
  pending=$(matching_call "$shown")
  [ -n "$pending" ] || return 0
  text=$(printf ' Bash command, read in full from the session'"'"'s transcript: its dialog is taller than the screen\n %s\n\n%s\n\n%s' \
    "$(printf '%s' "$pending" | jq -r '.input.description // empty')" "$(printf '%s' "$pending" | jq -r '.input.command')" "$options")
}

read_screen() {
  case $mux in
    herdr) herdr agent read "$pane" --source visible --format text ;;
    tmux) tmux capture-pane -p -N -t "$pane" ;;
  esac
}

# True when this session holds an Anderton role in project $1.
caller_holds_role() {
  [ -n "$(caller_claim "$1")" ]
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
}

load_session
root=$(invoking_root)
caller_holds_role "$root" || refuse "Only the session holding an Anderton role in this project may inspect a prompt."
[ "$(project_root "${cwd:-/}")" = "$root" ] || refuse "$name is in another project."
if [ "$(invoking_provider)" != claude ]; then
  worker="$holders/workers/$name.json"
  case $name in '' | -* | *[!a-z0-9-]*) refuse "Expected an owned worker name." ;; esac
  if [ ! -f "$worker" ] || [ "$(live_claude_worker "$worker")" != "$reg" ] ||
    ! worker_belongs "$worker" "$root" "$(caller_claim "$root")"; then
    refuse "This Anderton does not own $name."
  fi
fi
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
clipped=""
[ -n "$text" ] || read_clipped
if [ -z "$text" ] && [ -n "$clipped" ]; then
  refuse "$name's dialog is taller than its screen and its transcript does not show the full command: open its tab."
fi
[ -n "$text" ] || refuse "$name does not show a prompt this can inspect: open its tab."
printf 'Session: %s\nDirectory: %s\n\n%s\n' "$name" "$cwd" "$text"
