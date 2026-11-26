#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034 # check runs its eval strings later, so they must not expand here, and they read what is set for them
# agy-hooks.sh against a throwaway home and a stand-in bootstrap checkout: what register writes, in either order with
# herdr's antigravity-cli integration, and what check refuses.
# Runs under macOS's bash 3.2 as well as Linux: bash test/agy-hooks.test.sh
set -euo pipefail

scripts="$(cd "$(dirname "$0")/../skills/anderton/scripts" && pwd)"
work=$(mktemp -d "${TMPDIR:-/tmp}/agy-hooks-test.XXXXXX")
work=$(cd "$work" && pwd -P)
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
failures=0
check() { # check <description> <command...>
  local description=$1
  shift
  if "$@"; then echo "ok   $description"; else echo "FAIL $description"; failures=$((failures + 1)); fi
}
contains() { case $out in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# A bootstrap checkout whose guard records how it was called, and a bun for check to find.
guard="$work/bootstrap"
mkdir -p "$guard/plugins/workflow-agents/hooks" "$work/bin"
cat > "$guard/plugins/workflow-agents/hooks/agy-guard.sh" <<'GUARD'
#!/usr/bin/env bash
printf '%s|merge=%s|secrets=%s|dev=%s:%s|lab=%s:%s\n' "$*" "$BOOTSTRAP_MERGE_SCOPE_FILE" "$BOOTSTRAP_RESPONSE_SECRETS_FILE" \
  "${BOOTSTRAP_DEV_SCOPE_FILE+set}" "${BOOTSTRAP_DEV_SCOPE_FILE:-}" "${BOOTSTRAP_LAB_SCOPE_FILE+set}" "${BOOTSTRAP_LAB_SCOPE_FILE:-}"
GUARD
printf 'export const WATCHDOG_SECONDS = 3630;\n' > "$guard/plugins/workflow-agents/hooks/agy-supervisor.ts"
printf '#!/bin/sh\nexit 0\n' > "$work/bin/bun"
chmod +x "$work/bin/bun"
home="$work/home"
config="$home/.gemini/config"
file="$config/hooks.json"
mkdir -p "$config"
key=agent-anderton-agy-guard

hooks() { # hooks <args...>: agy-hooks.sh as the worker user; sets $out and $status
  set +e
  out=$(env HOME="$home" PATH="$work/bin:/usr/bin:/bin" "$scripts/agy-hooks.sh" "$@" 2>&1)
  status=$?
  set -e
}
# What herdr integration install antigravity-cli does: writes its hook script, then rewrites hooks.json, pretty-printed
# and 0644, with its entry merged in. It cannot write a read-only hooks.json and stops there, with the script written.
herdr_install() {
  mkdir -p "$config/hooks"
  printf '#!/bin/sh\nprintf "{}"\n' > "$config/hooks/herdr-agent-state.sh"
  chmod 0755 "$config/hooks/herdr-agent-state.sh"
  [ -w "$file" ] || [ ! -e "$file" ] || { echo "Permission denied (os error 13)"; return 1; }
  jq --arg command "bash '$config/hooks/herdr-agent-state.sh' session" \
    '. + {herdr: {PreInvocation: [{command: $command, timeout: 10, type: "command"}]}}' "$file" > "$file.herdr"
  mv -f "$file.herdr" "$file"
  chmod 0644 "$file"
}
# shellcheck disable=SC2012 # the mode string, which ls prints alike on both systems
perms() { ls -l "$file" | cut -c1-10; }

printf '{}' > "$file"
hooks register --guard "$guard"
check "register refuses before agy has set up its configuration" eval '[ "$status" -eq 1 ] && contains "run agy once and sign in"'
: > "$config/.migrated"
hooks register --guard "$guard"
check "register writes the guard's entry alone" eval '[ "$status" -eq 0 ] && [ "$(jq -c "keys" "$file")" = "[\"$key\"]" ]'
check "with agy's hook timeout" [ "$(jq -r --arg k "$key" '.[$k].PreToolUse[0].hooks[0].timeout' "$file")" = 3660 ]
check "and leaves the file read-only" [ "$(perms)" = "-r--r--r--" ]
hooks check
check "check accepts it" eval '[ "$status" -eq 0 ] && contains "$guard/plugins/workflow-agents/hooks/agy-guard.sh"'
before=$(cksum < "$file")
hooks register --guard "$guard"
check "registering again changes nothing" eval '[ "$status" -eq 0 ] && contains "already registered" && [ "$(cksum < "$file")" = "$before" ]'

# The command reaches the guard, with its policy files and empty dev and lab scopes, whether agy runs it through a shell
# or splits it on spaces.
command=$(jq -r --arg k "$key" '.[$k].PreToolUse[0].hooks[0].command' "$file")
want="PreToolUse|merge=$guard/merge-scope.local.json|secrets=$guard/response-secrets.local.json|dev=set:|lab=set:"
check "the hook command reaches the guard through a shell" [ "$(PATH=/usr/bin:/bin sh -c "$command")" = "$want" ]
read -r -a words <<<"$command"
check "and split on spaces" [ "$(PATH=/usr/bin:/bin "${words[@]}")" = "$want" ]

# herdr's integration installed after the lock: its install fails, then succeeds once the file is writable, and register
# locks the file again with herdr's entry kept.
set +e; herdr_out=$(herdr_install); herdr_status=$?; set -e
check "herdr's install cannot write the read-only registration" eval '[ "$herdr_status" -ne 0 ] && [ "$(jq -c "keys" "$file")" = "[\"$key\"]" ]'
hooks register --guard "$guard"
check "register says how to add herdr's entry it finds missing" eval '[ "$status" -eq 0 ] && contains "chmod u+w $file, then herdr integration install antigravity-cli"'
chmod u+w "$file"
herdr_install
herdr_entry=$(jq -c .herdr "$file")
hooks check
check "check refuses a writable registration" eval '[ "$status" -eq 1 ] && contains "is writable"'
hooks register --guard "$guard"
check "register keeps herdr's entry next to the guard's" eval '[ "$status" -eq 0 ] && [ "$(jq -c .herdr "$file")" = "$herdr_entry" ] &&
  [ "$(jq -c "keys" "$file")" = "[\"$key\",\"herdr\"]" ]'
check "and locks the file again" [ "$(perms)" = "-r--r--r--" ]
hooks check
check "check accepts the guard's entry with herdr's" [ "$status" -eq 0 ]

# herdr's integration first, over an earlier guard registration: register replaces that entry and keeps herdr's.
chmod u+w "$file"
jq -nc --arg k "$key" '{($k): {PreToolUse: [{matcher: "*", hooks: [{type: "command", command: "/example/libexec/agy-guard-hook PreToolUse", timeout: 3660}]}]}}' > "$file"
herdr_install
hooks register --guard "$guard"
check "register replaces an earlier guard entry, keeping herdr's" eval '[ "$status" -eq 0 ] && [ "$(jq -c .herdr "$file")" = "$herdr_entry" ] &&
  [ "$(jq -r --arg k "$key" ".[\$k].PreToolUse[0].hooks[0].command" "$file")" = "$command" ] && [ "$(perms)" = "-r--r--r--" ]'

# Hooks of anyone else stay until the operator says to drop them.
chmod u+w "$file"
jq -c '. + {example: {PreToolUse: []}}' "$file" > "$file.tmp" && mv -f "$file.tmp" "$file"
hooks register --guard "$guard"
check "register refuses a registration holding other hooks" eval '[ "$status" -eq 1 ] && contains "holds other hooks (example)"'
hooks register --guard "$guard" --replace
check "and drops them with --replace" eval '[ "$status" -eq 0 ] && [ "$(jq -c "keys" "$file")" = "[\"$key\",\"herdr\"]" ]'
cp -R "$guard" "$work/a guard"
hooks register --guard "$work/a guard"
check "register refuses a guard path agy would split" eval '[ "$status" -eq 1 ] && contains "may hold only"'

refused() { # refused <description> <text> [check args...]
  local description=$1 text=$2
  shift 2
  hooks check "$@"
  check "$description" eval "[ \"\$status\" -eq 1 ] && contains \"$text\""
}
saved=$(cat "$file")
restore() { chmod u+w "$file" 2>/dev/null || true; rm -f "$file"; printf '%s' "$saved" > "$file"; chmod 0444 "$file"; }
chmod u+w "$file"; jq -c '. + {example: {PreToolUse: []}}' "$file" > "$file.tmp" && mv -f "$file.tmp" "$file"; chmod 0444 "$file"
refused "check refuses any other hook" "other than the guard's and herdr's"
restore
chmod u+w "$file"; jq -c --arg k "$key" '.[$k].enabled = false' "$file" > "$file.tmp" && mv -f "$file.tmp" "$file"; chmod 0444 "$file"
refused "check refuses a guard entry that differs from register's" "does not register the agy guard"
restore
chmod u+w "$file"; jq -c '.herdr.PreInvocation[0].command = "bash /example/other.sh session"' "$file" > "$file.tmp" && mv -f "$file.tmp" "$file"; chmod 0444 "$file"
refused "check refuses a herdr entry herdr does not write" "herdr entry other than"
restore
mv "$file" "$work/hooks.real" && ln -s "$work/hooks.real" "$file"
refused "check refuses a linked registration" "symbolic link"
rm "$file" && mv "$work/hooks.real" "$file"
mv "$guard/plugins/workflow-agents/hooks/agy-guard.sh" "$work/agy-guard.sh"
refused "check refuses a guard that is not there" "agy-guard.sh is missing"
mv "$work/agy-guard.sh" "$guard/plugins/workflow-agents/hooks/agy-guard.sh"
mv "$work/bin/bun" "$work/bun"
refused "check refuses without bun, which the guard runs" "bun is not on PATH"
mv "$work/bun" "$work/bin/bun"
printf '{"example":{"PreToolUse":[]}}' > "$home/.gemini/hooks.json"
refused "check refuses hooks in another global hook file agy loads" "defines hooks"
printf '{}' > "$home/.gemini/hooks.json"
mkdir -p "$work/wt/.agent"
jq -nc --arg k "$key" '{($k): {enabled: false}}' > "$work/wt/.agent/hooks.json"
refused "check refuses a workspace hooks.json that would override the guard" "could override" --workspace "$work/wt"
rm "$work/wt/.agent/hooks.json"
hooks check --workspace "$work/wt"
check "and accepts that workspace once it names neither entry" [ "$status" -eq 0 ]
odd="$work/one
two"
mkdir -p "$odd/.agents"
jq -nc --arg k "$key" '{($k): {enabled: false}}' > "$odd/.agents/hooks.json"
refused "check reads a workspace whose path holds a newline as one path" "could override" --workspace "$work/wt" --workspace "$odd"
mkdir -p "$work/closed/.agents"
chmod 000 "$work/closed/.agents"
refused "and refuses a workspace root it cannot read rather than read it as empty" "cannot read" --workspace "$work/closed"
chmod 755 "$work/closed/.agents"

# skill writes agy's /anderton: a short skill naming this checkout's SKILL.md and scripts by absolute path, since agy
# shows the model a skill's text but not where it lives.
skill_dir=$(cd "$scripts/.." && pwd -P)
wrapper="$config/skills/anderton/SKILL.md"
hooks skill
check "skill writes agy's /anderton, naming this checkout's SKILL.md and scripts by absolute path" eval '[ "$status" -eq 0 ] &&
  grep -qx "name: anderton" "$wrapper" &&
  grep -qxF "Read $skill_dir/SKILL.md in full and follow it. Its scripts are in $skill_dir/scripts: run each one by that absolute path." "$wrapper"'
before=$(cat "$wrapper")
hooks skill
check "once, however often it runs" eval '[ "$status" -eq 0 ] && [ "$(cat "$wrapper")" = "$before" ]'
sed "s|$skill_dir|/other/skills/anderton|g" "$wrapper" > "$work/wrapper.tmp"
mv "$work/wrapper.tmp" "$wrapper"
other=$(cat "$wrapper")
hooks skill
check "it refuses to replace another checkout's registration, naming it" eval '[ "$status" -ne 0 ] &&
  contains "names another checkout (/other/skills/anderton)" && [ "$(cat "$wrapper")" = "$other" ]'
hooks skill --remove
check "or to remove it" eval '[ "$status" -ne 0 ] && contains "names another checkout" && [ "$(cat "$wrapper")" = "$other" ]'
printf -- '---\nname: anderton\ndescription: Example.\n---\n\nExample skill.\n' > "$wrapper"
hooks skill
check "and an anderton skill it did not write" eval '[ "$status" -ne 0 ] && contains "agy-hooks.sh did not write" && grep -qx "Example skill." "$wrapper"'
rm -r "$config/skills/anderton"
# Registration takes one lock: an installer that waits on it sees what the one holding it wrote.
mkdir -p "$config/skills/.anderton-skill.lock"
echo $$ > "$config/skills/.anderton-skill.lock/pid"
( sleep 1
  mkdir -p "$config/skills/anderton"
  printf -- '---\nname: anderton\n---\n\n<!-- written by agent-anderton agy-hooks.sh skill for /racing/skills/anderton -->\n' > "$wrapper"
  rm -rf "$config/skills/.anderton-skill.lock" ) &
hooks skill
wait
check "an installer that waited on the lock sees the other's registration and leaves it" eval '[ "$status" -ne 0 ] &&
  contains "names another checkout (/racing/skills/anderton)" && grep -q "/racing/skills/anderton" "$wrapper"'
rm -r "$config/skills/anderton"
hooks skill
hooks skill --remove
check "--remove takes out its own registration" eval '[ "$status" -eq 0 ] && [ ! -e "$config/skills/anderton" ]'
mkdir -p "$home/.gemini/copy/skills"
cp -R "$scripts/.." "$home/.gemini/copy/skills/anderton"
set +e
out=$(env HOME="$home" PATH="$work/bin:/usr/bin:/bin" "$home/.gemini/copy/skills/anderton/scripts/agy-hooks.sh" skill 2>&1)
status=$?
set -e
check "skill refuses a copy under ~/.gemini, where the guard would refuse its scripts" eval '[ "$status" -ne 0 ] && contains "under ~/.gemini" &&
  [ ! -e "$config/skills/anderton" ]'

if [ "$failures" -gt 0 ]; then
  echo "$failures agy-hooks check(s) failed"
  exit 1
fi
echo "agy-hooks: ok"
