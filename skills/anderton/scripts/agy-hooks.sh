#!/usr/bin/env bash
# Registers the agy guard as a PreToolUse hook in ~/.gemini/config/hooks.json, run in place from a bootstrap checkout as
# Claude Code runs that checkout's guard hooks, and checks the registration before spawn.sh starts an agy worker.
#
# usage: agy-hooks.sh register --guard <bootstrap checkout> [--replace]
#        agy-hooks.sh check [--workspace <dir>]
#
# register keeps herdr's antigravity-cli entry as it is, refuses any other hook unless --replace drops it, and leaves
# the file read-only (0444): it writes a new file and renames it over the old one, so a read-only file is no obstacle.
# check passes only for exactly the guard's entry, plus herdr's when it is there, in a read-only regular file, with the
# guard and bun in place. With --workspace it also refuses a workspace hooks.json in <dir> that names either entry,
# since agy would let it override the global one.
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
  local workspace="" hooks command guard root path content
  while [ $# -gt 0 ]; do
    case $1 in
      --workspace) [ $# -ge 2 ] || die "--workspace needs a directory."; workspace=$2; shift 2 ;;
      *) die "usage: agy-hooks.sh check [--workspace <dir>]" ;;
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
  if [ -n "$workspace" ]; then
    for root in .agents .agent _agents _agent; do
      path="$workspace/$root/hooks.json"
      [ -e "$path" ] || [ -L "$path" ] || continue
      if [ -L "$path" ] || ! jq -e --arg key "$key" 'type == "object" and (has($key) or has("herdr")) | not' "$path" >/dev/null 2>&1; then
        die "$path could override the guard's registration (a link, unreadable, or naming $key or herdr)."
      fi
    done
  fi
  echo "The agy guard is registered in $file: $guard/plugins/workflow-agents/hooks/agy-guard.sh."
}

case ${1:-} in
  register) shift; register "$@" ;;
  check) shift; check "$@" ;;
  *) echo "usage: agy-hooks.sh register --guard <bootstrap checkout> [--replace] | check [--workspace <dir>]" >&2; exit 2 ;;
esac
