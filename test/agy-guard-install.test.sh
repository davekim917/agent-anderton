#!/usr/bin/env bash
# install-agy.sh against a real bootstrap checkout at the commit in test/agy-guard.commit, the guard this repository was
# verified with: the installed hook must answer agy as the guard does, through the registration it wrote.
# Runs: AGY_GUARD_CHECKOUT=<bootstrap checkout> bash test/agy-guard-install.test.sh (Linux, bun 1.3.3 or newer as
# /usr/local/bin/bun, the PATH the registration gives the hook). Without AGY_GUARD_CHECKOUT it says so and passes.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
scripts="$here/../skills/anderton/scripts"
if [ -z "${AGY_GUARD_CHECKOUT:-}" ]; then
  echo "agy-guard-install: skipped (set AGY_GUARD_CHECKOUT to a bootstrap checkout)"
  exit 0
fi
want=$(tr -d '[:space:]' < "$here/agy-guard.commit")
got=$(git -C "$AGY_GUARD_CHECKOUT" rev-parse HEAD)
[ "$got" = "$want" ] || { echo "FAIL: $AGY_GUARD_CHECKOUT is at $got, not $want (test/agy-guard.commit)"; exit 1; }
[ -z "$(git -C "$AGY_GUARD_CHECKOUT" status --porcelain)" ] || { echo "FAIL: $AGY_GUARD_CHECKOUT has local changes"; exit 1; }

work=$(mktemp -d "$here/../.agy-guard-install-test.XXXXXX")
work=$(cd "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
failures=0
fail() {
  echo "FAIL: $1"
  failures=$((failures + 1))
}

mkdir -p "$work/release" "$work/home" "$work/scope" "$work/cwd"
printf '#!/bin/sh\nexit 0\n' > "$work/release/antigravity"
chmod +x "$work/release/antigravity"
tar -czf "$work/release.tar.gz" -C "$work/release" antigravity
printf 'version=0.0.0-test\nurl=https://example.invalid/agy.tar.gz\nsha256=%s\n' \
  "$(sha256sum "$work/release.tar.gz" | cut -d' ' -f1)" > "$work/agy.pin"
"$scripts/install-agy.sh" --user "$(id -un)" --home "$work/home" --guard "$AGY_GUARD_CHECKOUT/plugins/workflow-agents/hooks" \
  --scope-dir "$work/scope" --prefix "$work/opt" --pin "$work/agy.pin" --tarball "$work/release.tar.gz" >/dev/null

installed=$(sed -n 's/^guard=//p' "$work/opt/agy/etc/pin")
for file in agy-guard.sh agy-guard.ts agy-supervisor.ts guard-policy.ts; do
  cmp -s "$AGY_GUARD_CHECKOUT/plugins/workflow-agents/hooks/$file" "$installed/$file" || fail "the installed $file differs from the checkout's"
done

# The hook command exactly as agy runs it: its words carry no quoting, since the installer refuses paths that need it.
command=$(jq -r '.["agent-anderton-agy-guard"].PreToolUse[0].hooks[0].command' "$work/home/.gemini/config/hooks.json")
read -r -a words <<<"$command"
hook() { # hook <tool name> <args json>: the installed hook's reply to one agy call
  jq -nc --arg name "$1" --argjson args "$2" --arg cwd "$work/cwd" \
    '{hookEventName: "PreToolUse", toolCall: {name: $name, args: $args, id: "call-1"}, cwd: $cwd}' |
    (cd "$work/cwd" && "${words[@]}")
}
reply=$(hook run_command '{"CommandLine":"git status"}')
[ "$reply" = '{"decision":"allow"}' ] || fail "a safe command was not allowed: $reply"
reply=$(hook run_command '{"CommandLine":"snow sql -q \"DROP TABLE example_db.core.orders\""}')
case $(jq -r '"\(.decision) \(.reason)"' <<<"$reply") in
  "deny "*"Drop Snowflake table"*) ;;
  *) fail "a destructive command was not denied by the guard: $reply" ;;
esac
reply=$(hook write_file '{"Path":".agents/hooks.json","Content":"{}"}')
case $(jq -r '"\(.decision) \(.reason)"' <<<"$reply") in
  "deny "*"hook-config location"*) ;;
  *) fail "a write to a hook config was not denied: $reply" ;;
esac

if [ "$failures" -gt 0 ]; then
  echo "$failures agy-guard-install check(s) failed"
  exit 1
fi
echo "agy-guard-install: ok (bootstrap $want)"
