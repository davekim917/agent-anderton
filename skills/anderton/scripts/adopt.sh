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
provider=claude
if [ "${1:-}" = --provider ]; then
  [ "$#" -ge 3 ] || exit 2
  provider=$2
  shift 2
fi
name="${1:-}"
usage="usage: adopt.sh [--provider claude] <name> | adopt.sh --provider codex <name> <thread-uuid>"
case $name in
  '' | -* | *[!a-z0-9-]*) echo "$usage" >&2; exit 2 ;;
esac
case "$provider:$#" in claude:1 | codex:2) ;; *) echo "$usage" >&2; exit 2 ;; esac
refuse() { echo "Not adopted: $1" >&2; exit 1; }

sid=$(invoking_session)
caller_provider=$(invoking_provider)
root=$(invoking_root)
take_repository_lock "$root"
records=$(project_holders "$root")
role=$(caller_claim "$root")
[ -n "$role" ] || refuse "only a session holding an Anderton role adopts a session."
me=$(claim_name "$role")
[ -n "$me" ] || refuse "this session has no name for the adopted one to report to. Name it with /rename, then rerun."
[ "$name" != "$me" ] || refuse "an Anderton does not adopt itself."
record="$holders/workers/$name.json"
role_scope=$(jq -r '.scope // empty' "$role")
mkdir -p "$holders/workers"

if [ "$provider" = codex ]; then
  target=$2
  codex_home=$(invoking_codex_home) || refuse "cannot resolve the Codex home."
  data=$("$anderton_scripts/codex-worker.py" identity "$codex_home" "$target" --adopt) || refuse "cannot verify this Codex thread."
  cwd=$(printf '%s' "$data" | jq -r .dir)
  [ "$(project_root "$cwd")" = "$root" ] || refuse "$target is in another repository."
  while IFS= read -r r; do
    if [ -n "$r" ] && jq -e --arg id "$target" --arg home "$codex_home" '
      .provider == "codex" and .sessionId == $id and .codexHome == $home' "$r" >/dev/null 2>&1; then
      refuse "$target holds an Anderton role of its own; it answers to the user."
    fi
  done <<EOF
$records
EOF
  [ -z "$(codex_worker_record "$codex_home" "$target" "$cwd")" ] || refuse "$target already has a worker record."
  adoption=$(python3 -c 'import uuid; print(uuid.uuid4())') || refuse "cannot assign an adoption ID."
  if ! (set -C && : > "$record") 2>/dev/null; then refuse "$name already has a worker record."; fi
  jq -nc --arg name "$name" --arg root "$root" --arg codex_home "$codex_home" --argjson thread "$data" \
    --arg spawner "$me" --arg sid "$sid" --arg scope "$role_scope" --arg provider "$caller_provider" \
    --arg adoption "$adoption" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {name: $name, provider: "codex", launcher: "adopted", id: $thread.id, dir: $thread.dir, root: $root,
     codexHome: $codex_home, codexAdoptionId: $adoption, codexBaselineTurn: $thread.baseline,
     worktree: false, adopted: true, startedAt: $at,
     spawner: $spawner, spawnerSession: $sid, spawnerProvider: $provider, spawnerScope: (if $scope == "" then null else $scope end)}' >| "$record"
  echo "Adopted '$name' (Codex thread $target). Tell it to report milestones in its final reply with worker.sh message."
  exit 0
fi

found="" cwd=""
for s in "$sessions"/*.json; do
  [ -e "$s" ] || continue
  [ "$(jq -r '.name // empty' "$s" 2>/dev/null)" = "$name" ] || continue
  registered_alive "$(jq -r '.pid // empty' "$s")" "$(jq -r '.startedAt // empty | floor' "$s" 2>/dev/null)" "$(jq -r '.procStart // empty' "$s" 2>/dev/null)" || continue
  [ -z "$found" ] || refuse "more than one live session is named $name."
  found=$s
  cwd=$(jq -r '.cwd // empty' "$s")
done
[ -n "$found" ] || refuse "no live session is named $name."
if [ -z "$cwd" ] || [ "$(project_root "$cwd")" != "$root" ]; then refuse "$name is in another repository."; fi
while IFS= read -r r; do
  if [ -n "$r" ] && is_holder "$found" "$r"; then refuse "$name holds an Anderton role of its own; it answers to the user."; fi
done <<EOF
$records
EOF

owned=$(worker_record "$name" "$cwd" "$(jq -r '.sessionId // empty' "$found")" "$(jq -r '.pid // empty' "$found")" \
  "$(jq -r '.startedAt // empty | floor' "$found" 2>/dev/null)")
[ -z "$owned" ] || refuse "$name already reports to $(jq -r '.spawner // "another Anderton"' "$owned" 2>/dev/null)."

if ! (set -C && : > "$record") 2>/dev/null; then
  refuse "$name already reports to $(jq -r '.spawner // "another Anderton"' "$record" 2>/dev/null); that Anderton releases it with retire.sh $name first."
fi
jq -nc --arg name "$name" --arg dir "$cwd" --arg root "$root" --arg spawner "$me" --arg spawner_session "$sid" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg scope "$role_scope" --arg provider "$caller_provider" --slurpfile reg "$found" \
  '{name: $name, launcher: "adopted", dir: $dir, root: $root, worktree: false, adopted: true, spawner: $spawner, spawnerSession: $spawner_session,
    spawnerProvider: $provider, spawnerScope: (if $scope == "" then null else $scope end),
    sessionId: $reg[0].sessionId, pid: $reg[0].pid, sessionStartedAt: $reg[0].startedAt, startedAt: $at}
    + if $provider == "codex" or $provider == "agy" then {reportTransport: "transcript"} else {} end' >| "$record"
if [ "$caller_provider" = codex ] || [ "$caller_provider" = agy ]; then
  echo "Adopted '$name': tell it to report milestones in its final reply with worker.sh message."
else
  echo "Adopted '$name': it now reports to $me, and $me hears when it blocks. Tell it so by SendMessage."
fi
