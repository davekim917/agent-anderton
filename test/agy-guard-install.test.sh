#!/usr/bin/env bash
# install-agy.sh against a real bootstrap checkout at the commit in test/agy-guard.commit, the guard this repository was
# verified with: the installed hook must answer agy as the guard does, through the registration it wrote.
# Runs: AGY_GUARD_CHECKOUT=<bootstrap checkout> bash test/agy-guard-install.test.sh (Linux, bun 1.3.3 or newer on PATH,
# which the installer copies in). Without AGY_GUARD_CHECKOUT it says so and passes.
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
# The installer takes only a bun it can trust, so the one on PATH is copied where only this user can write.
bundir=$(mktemp -d /tmp/agy-guard-install-bun.XXXXXX)
trap 'rm -rf "$work" "$bundir"' EXIT
install -m 0755 "$(readlink -f "$(command -v bun)")" "$bundir/bun"
# The prefix must sit where no one else can write any directory above it: a directory of this user's own home.
prefixroot=$(mktemp -d "$HOME/.agy-guard-install-prefix.XXXXXX")
chmod 0755 "$prefixroot"
trap 'rm -rf "$work" "$bundir" "$prefixroot"' EXIT
failures=0
fail() {
  echo "FAIL: $1"
  failures=$((failures + 1))
}

# A home with a space in its path, which the hook command must carry.
home="$work/home dir"
mkdir -p "$work/release" "$home" "$work/scope" "$work/cwd"
printf '#!/bin/sh\nexit 0\n' > "$work/release/antigravity"
chmod +x "$work/release/antigravity"
tar -czf "$work/release.tar.gz" -C "$work/release" antigravity
printf 'version=0.0.0-test\nurl=https://example.invalid/agy.tar.gz\nsha256=%s\n' \
  "$(sha256sum "$work/release.tar.gz" | cut -d' ' -f1)" > "$work/agy.pin"
"$scripts/install-agy.sh" --user "$(id -un)" --home "$home" --guard "$AGY_GUARD_CHECKOUT/plugins/workflow-agents/hooks" \
  --scope-dir "$work/scope" --bun "$bundir/bun" --prefix "$prefixroot/opt" --pin "$work/agy.pin" --tarball "$work/release.tar.gz" >/dev/null
# The owner's first login leaves agy's migration marker, which register-agy.sh requires.
mkdir -p "$home/.gemini/config"
: > "$home/.gemini/config/.migrated"
HOME="$home" "$scripts/register-agy.sh" --prefix "$prefixroot/opt" >/dev/null

installed=$(sed -n 's/^guard=//p' "$prefixroot/opt/agy/etc/pin")
for file in agy-guard.sh agy-guard.ts agy-supervisor.ts guard-policy.ts; do
  cmp -s "$AGY_GUARD_CHECKOUT/plugins/workflow-agents/hooks/$file" "$installed/$file" || fail "the installed $file differs from the checkout's"
done
# bun's install cache linked into the installer's temporary directory; the installed tree holds no link, and the guard
# below still answers without it.
link=$(find "$prefixroot/opt" -type l -print -quit)
[ -z "$link" ] || fail "the install holds a symbolic link: $link -> $(readlink "$link")"

# The hook command as agy runs it, by a shell or as words split on spaces: both must reach the guard.
command=$(jq -r '.["agent-anderton-agy-guard"].PreToolUse[0].hooks[0].command' "$home/.gemini/config/hooks.json")
read -r -a words <<<"$command"
hook() { # hook <tool name> <args json>: the installed hook's replies to one agy call, by shell, then by split words
  local payload
  payload=$(jq -nc --arg name "$1" --argjson args "$2" --arg cwd "$work/cwd" \
    '{hookEventName: "PreToolUse", toolCall: {name: $name, args: $args, id: "call-1"}, cwd: $cwd}')
  (cd "$work/cwd" && sh -c "$command" <<<"$payload")
  echo
  (cd "$work/cwd" && "${words[@]}" <<<"$payload")
}
reply=$(hook run_command '{"CommandLine":"git status"}')
[ "$reply" = $'{"decision":"allow"}\n{"decision":"allow"}' ] || fail "a safe command was not allowed: $reply"
reply=$(hook run_command '{"CommandLine":"snow sql -q \"DROP TABLE example_db.core.orders\""}')
[ "$(jq -sr '[.[] | select(.decision == "deny" and (.reason | contains("Drop Snowflake table")))] | length' <<<"$reply")" = 2 ] ||
  fail "a destructive command was not denied by the guard both ways: $reply"
reply=$(hook write_file '{"Path":".agents/hooks.json","Content":"{}"}')
[ "$(jq -sr '[.[] | select(.decision == "deny" and (.reason | contains("hook-config location")))] | length' <<<"$reply")" = 2 ] ||
  fail "a write to a hook config was not denied both ways: $reply"

if [ "$failures" -gt 0 ]; then
  echo "$failures agy-guard-install check(s) failed"
  exit 1
fi
echo "agy-guard-install: ok (bootstrap $want)"
