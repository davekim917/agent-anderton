#!/usr/bin/env bash
# Adopt a session the user opened, so the calling Anderton answers for it as for a worker it started: the session
# reports to the caller, and the caller's watch hears when it blocks. Nothing about the session itself changes;
# retire.sh <name> releases it again without stopping it.
# usage: adopt.sh <session name>   Exit 0: adopted. 1: refused. 2: bad usage.
# Portable to macOS's bash 3.2 and BSD userland.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

require_tools adopt.sh
name="${1:-}"
case $name in
  '' | -* | *[!a-z0-9-]*) echo "usage: adopt.sh <session name: a-z 0-9 ->" >&2; exit 2 ;;
esac
refuse() { echo "Not adopted: $1" >&2; exit 1; }

sid="${CLAUDE_CODE_SESSION_ID:?not running inside a Claude Code session}"
pid="${CLAUDE_PID:-$(session_pid "$sid")}"
[ -n "$pid" ] || refuse "cannot find this session's pid under $sessions."
me=$(jq -r '.name // empty' "$sessions/$pid.json" 2>/dev/null || true)
root=$(invoking_root)
records=$(project_holders "$root")
role=""
while IFS= read -r r; do
  if [ -n "$r" ] && is_holder "$sessions/$pid.json" "$r"; then role=$r; fi
done <<EOF
$records
EOF
[ -n "$role" ] || refuse "only a session holding an Anderton role adopts a session."
[ -n "$me" ] || refuse "this session has no name for the adopted one to report to. Name it with /rename, then rerun."
[ "$name" != "$me" ] || refuse "an Anderton does not adopt itself."

found="" cwd=""
for s in "$sessions"/*.json; do
  [ -e "$s" ] || continue
  [ "$(jq -r '.name // empty' "$s" 2>/dev/null)" = "$name" ] || continue
  registered_alive "$(jq -r '.pid // empty' "$s")" "$(jq -r '.startedAt // empty | floor' "$s" 2>/dev/null)" || continue
  [ -z "$found" ] || refuse "more than one live session is named $name."
  found=$s
  cwd=$(jq -r '.cwd // empty' "$s")
done
[ -n "$found" ] || refuse "no live session is named $name."
[ -n "$cwd" ] && [ "$(project_root "$cwd")" = "$root" ] || refuse "$name is in another repository."
while IFS= read -r r; do
  if [ -n "$r" ] && is_holder "$found" "$r"; then refuse "$name holds an Anderton role of its own; it answers to the user."; fi
done <<EOF
$records
EOF

mkdir -p "$holders/workers"
record="$holders/workers/$name.json"
if ! (set -C && : > "$record") 2>/dev/null; then
  refuse "$name already reports to $(jq -r '.spawner // "another Anderton"' "$record" 2>/dev/null); that Anderton releases it with retire.sh $name first."
fi
jq -nc --arg name "$name" --arg dir "$cwd" --arg root "$root" --arg spawner "$me" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{name: $name, launcher: "adopted", dir: $dir, root: $root, worktree: false, adopted: true, spawner: $spawner,
    startedAt: $at}' >| "$record"
echo "Adopted '$name': it now reports to $me, and $me hears when it blocks. Tell it so by SendMessage."
