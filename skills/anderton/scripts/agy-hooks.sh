#!/usr/bin/env bash
# Registers the agy guard as a PreToolUse hook in ~/.gemini/config/hooks.json, run in place from a bootstrap checkout as
# Claude Code runs that checkout's guard hooks, and checks the registration before spawn.sh starts an agy worker.
#
# usage: agy-hooks.sh register --guard <bootstrap checkout> [--replace]
#        agy-hooks.sh check [--workspace <dir>]...
#        agy-hooks.sh skill [--remove]
#
# register keeps herdr's antigravity-cli entry as it is, refuses any other hook unless --replace drops it, and leaves
# the file read-only (0444): it writes a new file and renames it over the old one, so a read-only file is no obstacle.
# check passes only for exactly the guard's entry, plus herdr's when it is there, in a read-only regular file, with the
# guard and bun in place. With --workspace (repeatable) it also refuses a workspace hooks.json in <dir> that names either entry,
# since agy would let it override the global one.
# skill registers this checkout's Anderton skill as /anderton: a short skill in ~/.gemini/config/skills/anderton that
# points agy at this checkout, whose scripts run in place, since the guard refuses any command under ~/.gemini.
# Portable to macOS's bash 3.2 and BSD userland.
set -euo pipefail

key=agent-anderton-agy-guard
# agy ends a hook at this timeout with no decision; agy-supervisor.ts's deadline must fall after the guard's one-hour
# approval wait and early enough before it to print its own deny.
hook_timeout=3660
config="$HOME/.gemini/config"
file="$config/hooks.json"
herdr_script="$config/hooks/herdr-agent-state.sh"

die() {
  echo "agy-hooks: $*" >&2
  exit 1
}

# The command agy runs, which it may run through a shell or split on spaces: no path in it may need quoting.
guard_command() { # guard_command <checkout>
  printf '/usr/bin/env BOOTSTRAP_MERGE_SCOPE_FILE=%s BOOTSTRAP_RESPONSE_SECRETS_FILE=%s BOOTSTRAP_DEV_SCOPE_FILE= BOOTSTRAP_LAB_SCOPE_FILE= /bin/bash %s PreToolUse' \
    "$1/merge-scope.local.json" "$1/response-secrets.local.json" "$1/plugins/workflow-agents/hooks/agy-guard.sh"
}
guard_entry() { # guard_entry <checkout>
  jq -nc --arg command "$(guard_command "$1")" --argjson timeout "$hook_timeout" \
    '{PreToolUse: [{matcher: "*", hooks: [{type: "command", command: $command, timeout: $timeout}]}]}'
}
# What herdr integration install antigravity-cli writes for this home.
herdr_entry() {
  jq -nc --arg command "bash '$herdr_script' session" '{PreInvocation: [{command: $command, timeout: 10, type: "command"}]}'
}

# Dies unless <checkout> is a bootstrap checkout whose agy guard can decide within the hook's timeout.
guard_ready() { # guard_ready <checkout>
  local hooks="$1/plugins/workflow-agents/hooks" deadline
  case $1 in /*) ;; *) die "the guard checkout $1 is not an absolute path." ;; esac
  case $1 in *[!A-Za-z0-9._/-]*) die "the guard checkout $1 may hold only letters, digits, '.', '_', '-' and '/', since agy may split the hook command on spaces." ;; esac
  for name in agy-guard.sh agy-supervisor.ts; do
    [ -f "$hooks/$name" ] || die "$hooks/$name is missing, so the guard cannot decide."
  done
  deadline=$(sed -n 's/^export const WATCHDOG_SECONDS = \([0-9][0-9]*\);$/\1/p' "$hooks/agy-supervisor.ts" | head -n 1)
  [ -n "$deadline" ] && [ "$deadline" -gt 3600 ] && [ "$deadline" -le $((hook_timeout - 10)) ] ||
    die "the guard supervisor's deadline (${deadline:-none} seconds) is not above the 3600-second approval wait and 10 seconds under the hook timeout ($hook_timeout)."
}

# Dies unless $file is a regular file of its own, whose content is one JSON object, which it prints compact.
current_hooks() {
  local text
  [ ! -L "$config" ] || die "$config is a symbolic link; agy-hooks will not write through it."
  [ ! -L "$file" ] || die "$file is a symbolic link, whose target could stay writable."
  [ -e "$file" ] || { echo '{}'; return 0; }
  [ -f "$file" ] || die "$file is not a regular file."
  [ -z "$(find "$file" -links +1 2>/dev/null)" ] || die "$file has another hard link, which would keep it writable elsewhere."
  text=$(cat "$file") || die "could not read $file."
  [ -n "$(printf '%s' "$text" | tr -d '[:space:]')" ] || { echo '{}'; return 0; }
  printf '%s' "$text" | jq -ce 'if type == "object" then . else error("not an object") end' 2>/dev/null ||
    die "$file is not a JSON object."
}

register() {
  local guard="" replace="" hooks others updated tmp
  while [ $# -gt 0 ]; do
    case $1 in
      --guard) [ $# -ge 2 ] || die "--guard needs a bootstrap checkout."; guard=$2; shift 2 ;;
      --replace) replace=1; shift ;;
      *) die "usage: agy-hooks.sh register --guard <bootstrap checkout> [--replace]" ;;
    esac
  done
  [ -n "$guard" ] || die "usage: agy-hooks.sh register --guard <bootstrap checkout> [--replace]"
  [ "$(id -u)" != 0 ] || die "run it as the user agy runs as, not root."
  [ -d "$guard" ] || die "no guard checkout at $guard."
  guard=$(cd "$guard" && pwd -P)
  guard_ready "$guard"
  # agy's first start migrates its configuration, moving its legacy hooks.json over this one, which would replace a
  # registration written before it.
  [ -d "$config" ] && [ -f "$config/.migrated" ] ||
    die "agy has not set up $config yet (no .migrated there), and its first start would replace a registration written now: run agy once and sign in, then rerun."
  hooks=$(current_hooks)
  others=$(printf '%s' "$hooks" | jq -r --arg key "$key" '[keys[] | select(. != $key and . != "herdr")] | join(", ")')
  if [ -n "$others" ] && [ -z "$replace" ]; then
    die "$file holds other hooks ($others); check refuses them. Review them, then rerun with --replace, which drops them."
  fi
  updated=$(printf '%s' "$hooks" | jq -c --arg key "$key" --argjson guard "$(guard_entry "$guard")" \
    '(if has("herdr") then {herdr: .herdr} else {} end) + {($key): $guard}')
  if [ -f "$file" ] && [ ! -w "$file" ] && [ "$(cat "$file")" = "$updated" ]; then
    echo "The agy guard is already registered in $file, read-only."
  else
    tmp=$(mktemp "$config/.hooks.json.XXXXXX") || die "could not write in $config."
    printf '%s' "$updated" > "$tmp"
    chmod 0444 "$tmp"
    mv -f "$tmp" "$file"
    echo "Registered the agy guard ($guard/plugins/workflow-agents/hooks/agy-guard.sh) in $file, read-only."
  fi
  if [ -f "$herdr_script" ] && ! printf '%s' "$updated" | jq -e 'has("herdr")' >/dev/null; then
    echo "herdr's antigravity-cli hook script is installed, but its entry is not in $file: herdr cannot write a read-only file. Run chmod u+w $file, then herdr integration install antigravity-cli, then this again."
  fi
}

check() {
  local workspaces=() workspace hooks command guard root path content
  while [ $# -gt 0 ]; do
    case $1 in
      --workspace) [ $# -ge 2 ] || die "--workspace needs a directory."; workspaces+=("$2"); shift 2 ;;
      *) die "usage: agy-hooks.sh check [--workspace <dir>]..." ;;
    esac
  done
  [ -f "$file" ] || die "$file is missing: register the guard with agy-hooks.sh register --guard <bootstrap checkout>."
  hooks=$(current_hooks)
  # Only the owner's read-only bit set means nothing running as this user rewrites it by accident.
  [ "$(id -u)" = 0 ] || [ ! -w "$file" ] || die "$file is writable; rerun agy-hooks.sh register to make it read-only."
  [ "$(printf '%s' "$hooks" | jq -r --arg key "$key" '[keys[] | select(. != $key and . != "herdr")] | join(", ")')" = "" ] ||
    die "$file holds hooks other than the guard's and herdr's; review them, then rerun agy-hooks.sh register --replace."
  command=$(printf '%s' "$hooks" | jq -r --arg key "$key" '.[$key].PreToolUse[0].hooks[0].command // empty')
  guard=$(printf '%s' "$command" | sed -n 's|^/usr/bin/env BOOTSTRAP_MERGE_SCOPE_FILE=\([^ ]*\)/merge-scope\.local\.json .*|\1|p')
  if [ -z "$guard" ] ||
    ! printf '%s' "$hooks" | jq -e --arg key "$key" --argjson guard "$(guard_entry "$guard")" '.[$key] == $guard' >/dev/null; then
    die "$file does not register the agy guard as agy-hooks.sh register writes it; rerun that."
  fi
  guard_ready "$guard"
  if printf '%s' "$hooks" | jq -e 'has("herdr")' >/dev/null; then
    printf '%s' "$hooks" | jq -e --argjson herdr "$(herdr_entry)" '.herdr == $herdr' >/dev/null ||
      die "$file has a herdr entry other than herdr's antigravity-cli integration writes; reinstall it, then rerun agy-hooks.sh register."
    [ -f "$herdr_script" ] || die "$file runs $herdr_script, which is missing."
  fi
  # agy-guard.sh runs bun from the hook's environment, which is agy's own.
  command -v bun >/dev/null 2>&1 || die "bun is not on PATH, so the guard would deny every agy tool call."
  # agy loads these two as well, and a same-named entry in either would replace the guard's.
  for path in "$HOME/.gemini/hooks.json" "$HOME/.gemini/antigravity-cli/hooks.json"; do
    [ ! -L "$path" ] || die "$path is a symbolic link; agy loads hooks from it."
    [ -e "$path" ] || continue
    content=$(tr -d '[:space:]' < "$path") || die "could not read $path."
    case $content in '' | '{}') ;; *) die "$path defines hooks; only $file may." ;; esac
  done
  for workspace in ${workspaces[@]+"${workspaces[@]}"}; do
    # A directory this user cannot search hides whether agy would find hooks in it, so it is not read as empty.
    [ -d "$workspace" ] && [ -x "$workspace" ] || die "cannot read $workspace, where agy would look for workspace hooks."
    for root in .agents .agent _agents _agent; do
      if [ -e "$workspace/$root" ] && ! { [ -r "$workspace/$root" ] && [ -x "$workspace/$root" ]; }; then
        die "cannot read $workspace/$root, where agy would look for workspace hooks."
      fi
      path="$workspace/$root/hooks.json"
      [ -e "$path" ] || [ -L "$path" ] || continue
      if [ -L "$path" ] || ! jq -e --arg key "$key" 'type == "object" and (has($key) or has("herdr")) | not' "$path" >/dev/null 2>&1; then
        die "$path could override the guard's registration (a link, unreadable, or naming $key or herdr)."
      fi
    done
  done
  echo "The agy guard is registered in $file: $guard/plugins/workflow-agents/hooks/agy-guard.sh."
}

# The /anderton skill agy loads: a short one written here, since agy shows the model a skill's text but not where it
# lives, that names this checkout's SKILL.md and scripts by absolute path. Its marker line names the checkout that wrote
# it, which alone may replace or remove it.
skill_marker() { printf '<!-- written by agent-anderton agy-hooks.sh skill for %s -->' "$1"; }
skill_text() { # skill_text <this checkout's skill folder>
  printf -- '---\nname: anderton\ndescription: %s\n---\n\n%s\n\nRead %s/SKILL.md in full and follow it. Its scripts are in %s/scripts: run each one by that absolute path.\n' \
    '"Make this agy session the Anderton, the operator that owns the line to production and coordinates its workers. Use only when the user types /anderton."' \
    "$(skill_marker "$1")" "$1" "$1"
}

# One registration or removal at a time: the ownership check and the write it allows happen under one lock, a
# directory (so no flock is needed) naming the process that holds it.
skill_lock() {
  local lock="$config/skills/.anderton-skill.lock" owner tries=0
  until mkdir "$lock" 2>/dev/null; do
    [ -d "$lock" ] || die "could not make $lock."
    owner=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$owner" ] && ! ps -p "$owner" >/dev/null 2>&1; then
      rm -rf "$lock"
      continue
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || die "another agy-hooks.sh skill holds $lock; rerun once it ends."
    sleep 0.1
  done
  echo $$ > "$lock/pid"
  # shellcheck disable=SC2064 # the lock's path is fixed now
  trap "rm -rf '$lock'" EXIT
}

skill() {
  local remove="" skill_dir dir="$config/skills/anderton" file_path existing owner tmp entry
  case ${1:-} in
    --remove) remove=1 ;;
    "") ;;
    *) die "usage: agy-hooks.sh skill [--remove]" ;;
  esac
  [ "$(id -u)" != 0 ] || die "run it as the user agy runs as, not root."
  skill_dir=$(cd "$(dirname "$0")/.." && pwd -P) || die "could not find this checkout's skill."
  [ -f "$skill_dir/SKILL.md" ] || die "$skill_dir/SKILL.md is missing."
  case $skill_dir/ in "$HOME/.gemini/"*) die "$skill_dir is under ~/.gemini, where the guard refuses every command, so the skill's scripts could not run: register it from a checkout elsewhere." ;; esac
  [ -d "$config" ] && [ -f "$config/.migrated" ] ||
    die "agy has not set up $config yet (no .migrated there), and its first start would replace a registration written now: run agy once and sign in, then rerun."
  for entry in "$config" "$config/skills" "$dir" "$dir/SKILL.md"; do
    [ ! -L "$entry" ] || die "$entry is a symbolic link; agy-hooks will not write through it."
  done
  mkdir -p "$config/skills" || die "could not make $config/skills."
  skill_lock
  file_path="$dir/SKILL.md"
  owner=""
  if [ -e "$dir" ]; then
    existing=$(cat "$file_path" 2>/dev/null) || existing=""
    owner=$(printf '%s\n' "$existing" | sed -n 's/^<!-- written by agent-anderton agy-hooks.sh skill for \(.*\) -->$/\1/p' | head -n 1)
    [ -n "$owner" ] || die "$dir holds an anderton skill agy-hooks.sh did not write; review it, and remove it yourself if it should go."
  fi
  if [ -n "$remove" ]; then
    if [ -z "$owner" ]; then echo "agy loads no /anderton skill from $dir; nothing to remove."; return 0; fi
    [ "$owner" = "$skill_dir" ] || die "$dir names another checkout ($owner); remove it with that checkout's agy-hooks.sh skill --remove."
    rm -f "$file_path"
    rmdir "$dir" 2>/dev/null || true
    echo "Removed the /anderton skill ($skill_dir) from $dir."
    return 0
  fi
  [ -z "$owner" ] || [ "$owner" = "$skill_dir" ] ||
    die "$dir already names another checkout ($owner); remove it with that checkout's agy-hooks.sh skill --remove first, so agy loads one."
  mkdir -p "$dir" || die "could not make $dir."
  tmp=$(mktemp "$dir/.SKILL.md.XXXXXX") || die "could not write in $dir."
  skill_text "$skill_dir" > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$file_path"
  echo "Registered the /anderton skill ($skill_dir) in $file_path. agy sessions started from now on list it."
  case $skill_dir in */plugins/cache/*) echo "$skill_dir is a versioned copy that a plugin update replaces: register it from a clone you keep, such as ~/.claude/plugins/marketplaces/agent-anderton." ;; esac
}

case ${1:-} in
  register) shift; register "$@" ;;
  check) shift; check "$@" ;;
  skill) shift; skill "$@" ;;
  *) echo "usage: agy-hooks.sh register --guard <bootstrap checkout> [--replace] | check [--workspace <dir>]... | skill [--remove]" >&2; exit 2 ;;
esac