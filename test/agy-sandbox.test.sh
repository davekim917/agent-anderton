#!/usr/bin/env bash
# The agy launcher against a throwaway install, home and repository: what a worker inside it can and cannot change.
# Linux with bwrap and unprivileged user namespaces only; elsewhere it says why and passes.
# Runs: bash test/agy-sandbox.test.sh
set -euo pipefail

scripts="$(cd "$(dirname "$0")/../skills/anderton/scripts" && pwd)"
if [ "$(uname -s)" != Linux ] || ! command -v bwrap >/dev/null 2>&1 ||
  ! bwrap --ro-bind / / --dev /dev --proc /proc --unshare-pid true 2>/dev/null; then
  echo "agy-sandbox: skipped (needs Linux, bwrap and unprivileged user namespaces)"
  exit 0
fi
# Not under /tmp: the launcher keeps /tmp writable, which would make the whole throwaway home writable too.
work=$(mktemp -d "$(cd "$(dirname "$0")/.." && pwd)/.agy-sandbox-test.XXXXXX")
work=$(cd "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
failures=0
fail() {
  echo "FAIL: $1"
  failures=$((failures + 1))
}

# A stand-in release whose "agy" runs the shell script it is given, and insists on the flag the launcher passes.
# The home has a space in its path, which the hook command must carry.
home="$work/home dir"
mkdir -p "$work/release" "$work/guard/guards" "$home" "$work/NanoClaw [dev]/data"
cat > "$work/release/antigravity" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = --dangerously-skip-permissions ] || { echo "launched without --dangerously-skip-permissions" >&2; exit 9; }
exec bash -c "$2"
FAKE
chmod +x "$work/release/antigravity"
tar -czf "$work/release.tar.gz" -C "$work/release" antigravity
cp "$work/release.tar.gz" "$work/release.good.tar.gz"
printf 'version=0.0.0-test\nurl=https://example.invalid/agy.tar.gz\nsha256=%s\n' \
  "$(sha256sum "$work/release.tar.gz" | cut -d' ' -f1)" > "$work/agy.pin"
# A stand-in guard wrapper that reports the environment and arguments the hook gives it.
cat > "$work/guard/agy-guard.sh" <<'GUARD'
#!/usr/bin/env bash
printf 'HOME=%s\nPATH=%s\nMERGE=%s\nSECRETS=%s\nDEV=%s/%s\nLAB=%s/%s\nARGS=%s\n' "$HOME" "$PATH" \
  "${BOOTSTRAP_MERGE_SCOPE_FILE-unset}" "${BOOTSTRAP_RESPONSE_SECRETS_FILE-unset}" \
  "${BOOTSTRAP_DEV_SCOPE_FILE+set}" "${BOOTSTRAP_DEV_SCOPE_FILE:-}" "${BOOTSTRAP_LAB_SCOPE_FILE+set}" "${BOOTSTRAP_LAB_SCOPE_FILE:-}" "$*"
GUARD
printf 'export {};\n' > "$work/guard/agy-guard.ts"
printf 'export const WATCHDOG_SECONDS = 3630;\n' > "$work/guard/agy-supervisor.ts"
mkdir "$work/scope"
# The bun the installer copies in must be trusted: owned by this user with every parent, writable by no one else.
bundir=$(mktemp -d /tmp/agy-sandbox-bun.XXXXXX)
# The install must sit where no one else can write any directory above it, which a shared scratch directory (or /tmp,
# which the launcher keeps writable) is not: a directory of this user's own home is.
prefixroot=$(mktemp -d "$HOME/.agy-sandbox-prefix.XXXXXX")
chmod 0755 "$prefixroot"
trap 'rm -rf "$work" "$bundir" "$prefixroot"' EXIT
printf '#!/bin/sh\necho 1.4.2\n' > "$bundir/bun"
chmod 0755 "$bundir/bun"
install_root() { # install_root <prefix> [args...]: the root stage, as this user
  local prefix=$1
  shift
  "$scripts/install-agy.sh" --user "$(id -un)" --home "$home" --guard "$work/guard" --scope-dir "$work/scope" \
    --bun "$bundir/bun" --nanoclaw "$work/NanoClaw [dev]" --prefix "$prefix" --pin "$work/agy.pin" --tarball "$work/release.tar.gz" "$@"
}
# The root stage writes nothing in the home, even one it could not write.
chmod 0555 "$home"
install_root "$prefixroot/opt" >/dev/null || fail "the root stage failed with the home unwritable"
chmod 0755 "$home"
[ -z "$(ls -A "$home")" ] || fail "the root stage wrote in the home: $(ls -A "$home")"
HOME="$home" "$scripts/register-agy.sh" --prefix "$prefixroot/opt" >/dev/null

# The registration outlasts the supervisor's deadline and runs a hook that names the files that tighten the guard, which
# the installed copy cannot find; the dev and lab scopes, which only exempt commands from approval, are set empty so
# none is read. Whether agy splits the command on spaces or runs it with a shell, the hook gets the home intact.
hook=$(jq -r '.["agent-anderton-agy-guard"].PreToolUse[0].hooks[0]' "$home/.gemini/config/hooks.json")
[ "$(jq '.timeout' <<<"$hook")" -ge 3640 ] || fail "the hook timeout does not outlast the supervisor's deadline by 10 seconds"
command=$(jq -r '.command' <<<"$hook")
read -r -a words <<<"$command"
want="HOME=$home
PATH=$prefixroot/opt/agy/hookbin:/usr/bin:/bin
MERGE=$work/scope/merge-scope.local.json
SECRETS=$work/scope/response-secrets.local.json
DEV=set/
LAB=set/
ARGS=PreToolUse"
[ "$(sh -c "$command")" = "$want" ] || fail "the hook run by a shell did not get its environment: $(sh -c "$command" 2>&1)"
[ "$("${words[@]}")" = "$want" ] || fail "the hook run as split words did not get its environment: $("${words[@]}" 2>&1)"
[ -f "$(sed -n 's/^guard=//p' "$prefixroot/opt/agy/etc/pin")/agy-supervisor.ts" ] || fail "the installed guard has no agy-supervisor.ts"
[ "$("$prefixroot/opt/agy/hookbin/bun" --version)" = 1.4.2 ] && [ "$(ls "$prefixroot/opt/agy/hookbin")" = bun ] ||
  fail "the hook's PATH does not start with a directory holding only the pinned bun"

# The worker-user stage writes the registration and the empty hook files without following a link planted there.
echo canary > "$work/canary"
mv "$home/.gemini/config/hooks.json" "$work/hooks.json.saved"
ln -s "$work/canary" "$home/.gemini/config/hooks.json"
if HOME="$home" "$scripts/register-agy.sh" --prefix "$prefixroot/opt" --replace-hooks >/dev/null 2>&1; then
  fail "register-agy.sh accepted a link where the registration goes"
fi
[ "$(cat "$work/canary")" = canary ] || fail "register-agy.sh wrote through a link to $(cat "$work/canary")"
rm "$home/.gemini/config/hooks.json"
mv "$work/hooks.json.saved" "$home/.gemini/config/hooks.json"
mv "$home/.gemini/config" "$work/config.saved"
mkdir "$work/config-elsewhere"
ln -s "$work/config-elsewhere" "$home/.gemini/config"
if HOME="$home" "$scripts/register-agy.sh" --prefix "$prefixroot/opt" >/dev/null 2>&1; then
  fail "register-agy.sh accepted a linked ~/.gemini/config"
fi
[ -z "$(ls -A "$work/config-elsewhere")" ] || fail "register-agy.sh wrote through a linked ~/.gemini/config"
rm "$home/.gemini/config"
mv "$work/config.saved" "$home/.gemini/config"
mv "$home/.gemini/hooks.json" "$work/gemini-hooks.saved"
ln -s "$work/canary" "$home/.gemini/hooks.json"
if HOME="$home" "$scripts/register-agy.sh" --prefix "$prefixroot/opt" >/dev/null 2>&1; then
  fail "register-agy.sh accepted a link where an empty hook file goes"
fi
rm "$home/.gemini/hooks.json"
mv "$work/gemini-hooks.saved" "$home/.gemini/hooks.json"
HOME="$home" "$scripts/register-agy.sh" --prefix "$prefixroot/opt" >/dev/null || fail "register-agy.sh did not rerun cleanly"

# The install refuses a guard checkout without the supervisor its wrapper execs, or whose deadline falls outside the
# approval wait and the hook timeout.
install_refusal() { # install_refusal <description> <guard dir> <expected text>
  local got
  if got=$("$scripts/install-agy.sh" --user "$(id -un)" --home "$home" --guard "$2" --scope-dir "${4:-$work/scope}" \
    --bun "$bundir/bun" --prefix "$prefixroot/other" --pin "$work/agy.pin" --tarball "$work/release.tar.gz" 2>&1); then
    fail "install accepted $1"
  else
    case $got in *"$3"*) ;; *) fail "install refused $1 for another reason: $got" ;; esac
  fi
}
cp -a "$work/guard" "$work/guard-incomplete"
rm "$work/guard-incomplete/agy-supervisor.ts"
install_refusal "a guard without agy-supervisor.ts" "$work/guard-incomplete" "has no agy-supervisor.ts"
for deadline in "" 3600 3651; do
  if [ -n "$deadline" ]; then
    printf 'export const WATCHDOG_SECONDS = %s;\n' "$deadline" > "$work/guard-incomplete/agy-supervisor.ts"
    install_refusal "a supervisor deadline of $deadline seconds" "$work/guard-incomplete" "is not between"
  else
    printf 'export const OTHER = 1;\n' > "$work/guard-incomplete/agy-supervisor.ts"
    install_refusal "a supervisor that sets no deadline" "$work/guard-incomplete" "sets no WATCHDOG_SECONDS"
  fi
done
mkdir -p "$prefixroot/shared"
chmod 0775 "$prefixroot/shared"
if got=$(install_root "$prefixroot/shared/opt" 2>&1); then
  fail "install accepted a prefix under a directory others can write"
else
  case $got in *"is writable by others"*) ;; *) fail "install refused a prefix under a group-writable directory for another reason: $got" ;; esac
fi
mkdir -p "$home/.cache/scope"
install_refusal "a scope directory agy workers can write" "$work/guard" "which agy workers can write" "$home/.cache/scope"
rmdir "$home/.cache/scope"
touch "$prefixroot/opt/agy/etc/user-owned-test-install"
agy="$prefixroot/opt/agy/bin/agy"

# The install refuses a release that does not match its pin.
printf 'tampered' >> "$work/release.tar.gz"
install_refusal "a tarball that does not match the pin" "$work/guard" "does not match the pinned sha256"

git init -q "$work/repo"
git -C "$work/repo" -c user.name=example -c user.email=example@example.invalid commit -q --allow-empty -m init
git -C "$work/repo" worktree add -q --detach "$work/wt-example" HEAD
git -C "$work/repo" worktree add -q --detach "$work/wt-other" HEAD
printf 'import sys\nopen(sys.argv[1], "w").write("x")\n' > "$work/wt-example/write.py"
mkdir -p "$home/.claude" "$home/.codex-example" "$home/.cache"
for canary in "$home/.claude/canary" "$home/.codex-example/canary" "$home/.git-credentials" "$home/.netrc" \
  "$work/NanoClaw [dev]/data/canary" "$work/NanoClaw [dev]/.env"; do
  echo canary-value > "$canary"
done
common="$work/repo/.git"
own_gitdir="$common/worktrees/wt-example"
# Configuration host git reads through includes, plain and conditional, of files beside the repository's config.
git -C "$work/repo" config include.path config.local
git -C "$work/repo" config "includeIf.gitdir:$common/.path" cond.local
# Masks are literal: brackets, "*" and "?" are the path's own characters, and a sibling a glob would match stays visible.
mkdir -p "$work/glob*dir?" "$work/globXdirY"
echo canary-value > "$work/glob*dir?/canary"
echo canary-value > "$work/globXdirY/canary"
echo "mask $work/glob*dir?" >> "$prefixroot/opt/agy/etc/sandbox.conf"

# Descriptor 9, a directory opened outside, stands in for one a launching shell leaks into the sandbox.
run() {
  (cd "$work/wt-example" && exec 9<"$work/wt-example" && env -i HOME="$home" PATH=/usr/bin:/bin "$agy" "$1")
}

# shellcheck disable=SC2016 # expanded inside the sandbox
attempts='
w() { if (eval "$2") >/dev/null 2>&1; then echo "wrote $1"; else echo "denied $1"; fi; }
w worktree-agents       "echo x > .agents/hooks.json"
w worktree-agents-mv    "mv .agents agents-moved"
w global-hooks          "echo {} > \"$HOME\"/.gemini/config/hooks.json"
w gemini-hooks          "echo {} > \"$HOME\"/.gemini/hooks.json"
w state-hooks           "echo {} > \"$HOME\"/.gemini/antigravity-cli/hooks.json"
w state-plugins         "mkdir \"$HOME\"/.gemini/antigravity-cli/plugins/example"
w state-agents-json     "echo [] > \"$HOME\"/.gemini/antigravity-cli/agents.json"
w gemini-moved          "mv \"$HOME\"/.gemini \"$HOME\"/gemini-moved"
w git-hooks             "echo x > $(git rev-parse --git-common-dir)/hooks/post-checkout"
w git-config            "git config --file $(git rev-parse --git-common-dir)/config core.hooksPath /tmp"
w home-rc               "echo x >> \"$HOME\"/.bashrc"
w python-write          "python3 -I write.py .agents/hooks.json"
w python-control        "python3 -I write.py python-control.txt"
w unshare-umount        "unshare -Urm sh -c \"umount .agents && echo x > .agents/hooks.json\""
w inherited-fd          "echo x > /proc/self/fd/9/.agents/hooks.json"
w read-claude-canary    "grep -q canary-value \"$HOME\"/.claude/canary"
w read-codex-glob       "grep -q canary-value \"$HOME\"/.codex-example/canary"
w read-git-credentials  "grep -q canary-value \"$HOME\"/.git-credentials"
w read-netrc            "grep -q canary-value \"$HOME\"/.netrc"
w read-nanoclaw-data    "grep -q canary-value '"$work"'/NanoClaw\ \[dev\]/data/canary"
w read-nanoclaw-env     "grep -q canary-value '"$work"'/NanoClaw\ \[dev\]/.env"
w git-config-worktree   "echo x > '"$common"'/config.worktree"
w git-info              "echo x > '"$common"'/info/attributes"
w own-config-worktree   "echo x > '"$own_gitdir"'/config.worktree"
w own-commondir         "echo x > '"$own_gitdir"'/commondir"
w git-pointer           "echo x > .git"
w other-worktree        "echo x > '"$common"'/worktrees/wt-other/HEAD"
w host-cache            "echo x > \"$HOME\"/.cache/pre-commit-example"
w git-config-local      "echo x > '"$common"'/config.local"
w git-config-cond       "echo x > '"$common"'/cond.local"
w git-common-new        "echo x > '"$common"'/planted"
w read-glob-literal     "grep -q canary-value '"$work"'/glob\*dir\?/canary"
w read-glob-sibling     "grep -q canary-value '"$work"'/globXdirY/canary"
w worktree-file         "echo x > example.txt"
w git-commit            "git add example.txt && git -c user.name=example -c user.email=example@example.invalid commit -qm example"
w state-file            "echo x > \"$HOME\"/.gemini/antigravity-cli/example.log"
w cache-file            "echo x > \"$HOME\"/.cache/example"
w tmp-file              "echo x > /tmp/agy-sandbox-example-$$"
'
out=$(run "$attempts" 2>&1) || fail "the launcher did not start: $out"
for denied in worktree-agents worktree-agents-mv global-hooks gemini-hooks state-hooks state-plugins state-agents-json \
  gemini-moved git-hooks git-config home-rc python-write unshare-umount inherited-fd read-claude-canary read-codex-glob \
  read-git-credentials read-netrc read-nanoclaw-data read-nanoclaw-env git-config-worktree git-info own-config-worktree \
  own-commondir git-pointer other-worktree git-config-local git-config-cond git-common-new read-glob-literal; do
  printf '%s\n' "$out" | grep -qx "denied $denied" || fail "$denied was not denied: $(printf '%s\n' "$out" | grep " $denied\$")"
done
for wrote in worktree-file python-control git-commit state-file cache-file tmp-file host-cache read-glob-sibling; do
  printf '%s\n' "$out" | grep -qx "wrote $wrote" || fail "$wrote should be writable: $(printf '%s\n' "$out" | grep " $wrote\$")"
done
# The worker's cache is its own: what it writes there never reaches the cache host tools read and run from.
[ ! -e "$home/.cache/example" ] && [ ! -e "$home/.cache/pre-commit-example" ] ||
  fail "a write to the worker's ~/.cache reached the host's"
ls "$home"/.cache/anderton-agy/*/cache/pre-commit-example >/dev/null 2>&1 || fail "the worker's private cache kept nothing"

# The checks inside the namespace refuse to start agy when the guard could be off.
refuses() {
  local why=$1 want=$2 got
  if got=$(run true 2>&1); then fail "started although $why"; fi
  case $got in *"$want"*) ;; *) fail "refused for the wrong reason when $why: $got" ;; esac
}
cp "$home/.gemini/config/hooks.json" "$work/hooks.saved"
printf '{}' > "$home/.gemini/config/hooks.json"
refuses "the guard registration was replaced" "is not the guard registration"
cp "$work/hooks.saved" "$home/.gemini/config/hooks.json"
printf '{"example":{"PreToolUse":[]}}' > "$home/.gemini/hooks.json"
refuses "another global hook file defines hooks" "defines hooks"
printf '{}' > "$home/.gemini/hooks.json"
echo '{}' > "$work/wt-example/.agents/hooks.json"
refuses "the worktree has workspace hooks" ".agents/hooks.json exists"
rm "$work/wt-example/.agents/hooks.json"
ln -s ../outside-hooks.json "$work/wt-example/.agents/hooks.json"
refuses "the worktree has a dangling link where workspace hooks load" ".agents/hooks.json exists"
rm "$work/wt-example/.agents/hooks.json"
ln -s ../plugins-elsewhere "$work/wt-example/.agents/plugins"
refuses "a workspace plugin location is a link" "is a symbolic link"
rm "$work/wt-example/.agents/plugins"
ln -s ../outside-hooks.json "$work/wt-example/.agents/hooks.json"
rm "$work/wt-example/.agents/hooks.json"
mv "$home/.cache" "$home/cache-target"
ln -s "$home/cache-target" "$home/.cache"
refuses "a writable root is a symbolic link" "symbolic link"
rm "$home/.cache"
mv "$home/cache-target" "$home/.cache"
ln "$work/repo/.git/config" "$work/wt-example/config-alias"
refuses "a protected file has another hard link" "another hard link"
rm "$work/wt-example/config-alias"
ln "$home/.gemini/antigravity-cli/hooks.json" "$work/wt-example/state-hooks-alias"
refuses "agy's state-directory hook file has another hard link" "another hard link"
rm "$work/wt-example/state-hooks-alias"
echo '{}' > "$home/.gemini/antigravity-cli/plugins/example.json"
ln "$home/.gemini/antigravity-cli/plugins/example.json" "$work/wt-example/plugin-alias"
refuses "a file inside a protected directory has another hard link" "another hard link"
rm "$work/wt-example/plugin-alias" "$home/.gemini/antigravity-cli/plugins/example.json"
echo '{}' > "$work/scope/merge-scope.local.json"
ln "$work/scope/merge-scope.local.json" "$work/wt-example/scope-alias"
refuses "a scope file has another hard link" "another hard link"
rm "$work/wt-example/scope-alias"
cp "$prefixroot/opt/agy/etc/pin" "$work/pin.saved"
sed -i "s|^scope_dir=.*|scope_dir=$work/wt-example|" "$prefixroot/opt/agy/etc/pin"
echo '{}' > "$work/wt-example/merge-scope.local.json"
refuses "a scope file is inside the worktree" "inside a directory agy can write"
rm "$work/wt-example/merge-scope.local.json"
cp "$work/pin.saved" "$prefixroot/opt/agy/etc/pin"
cp "$prefixroot/opt/agy/etc/sandbox.conf" "$work/conf.saved"
echo "rw ~ the whole home" >> "$prefixroot/opt/agy/etc/sandbox.conf"
refuses "a writable root is the home" "would make $home writable"
cp "$work/conf.saved" "$prefixroot/opt/agy/etc/sandbox.conf"
echo "rw / everything" >> "$prefixroot/opt/agy/etc/sandbox.conf"
refuses "a writable root is /" "would make $home writable"
cp "$work/conf.saved" "$prefixroot/opt/agy/etc/sandbox.conf"
mv "$work/scope/merge-scope.local.json" "$work/merge-scope.target"
ln -s "$work/merge-scope.target" "$work/scope/merge-scope.local.json"
refuses "a scope file is a symbolic link" "is a symbolic link"
rm "$work/scope/merge-scope.local.json"
mv "$work/merge-scope.target" "$work/scope/merge-scope.local.json"
# A reinstall over an empty sandbox.conf, as an earlier installer left it, restores the default masks and keeps the rest.
printf 'mask ~/.example-operator-line\n' > "$prefixroot/opt/agy/etc/sandbox.conf"
cp "$work/release.good.tar.gz" "$work/release.tar.gz"
install_root "$prefixroot/opt" >/dev/null || fail "the reinstall failed"
for line in 'mask ~/.netrc' 'mask ~/.example-operator-line' "mask $work/NanoClaw [dev]/.env"; do
  grep -qxF -- "$line" "$prefixroot/opt/agy/etc/sandbox.conf" ||
    fail "a reinstall did not merge '$line' into the existing sandbox.conf: $(cat "$prefixroot/opt/agy/etc/sandbox.conf")"
done
touch "$prefixroot/opt/agy/etc/user-owned-test-install"
cp "$prefixroot/opt/agy/libexec/agy-guard-hook" "$work/hook.saved"
echo "# changed" >> "$prefixroot/opt/agy/libexec/agy-guard-hook"
refuses "the guard hook script was changed" "is not the hook install-agy.sh wrote"
cp "$work/hook.saved" "$prefixroot/opt/agy/libexec/agy-guard-hook"
# A planted file that git configuration includes, inside the worktree.
git -C "$work/repo" config --add include.path "$work/wt-example/planted.config"
refuses "git configuration includes a file inside the worktree" "inside a directory agy can write"
git -C "$work/repo" config --unset include.path "$work/wt-example/planted.config"
# Everything above the hook, the guard and the bun must be the installer's own and writable by no one else, and
# outside every writable root.
chmod g+w "$prefixroot/opt/agy/libexec"
refuses "a directory above the hook is writable by others" "is writable by others"
chmod g-w "$prefixroot/opt/agy/libexec"
echo "rw $prefixroot the whole install" >> "$prefixroot/opt/agy/etc/sandbox.conf"
refuses "the install is inside a writable root" "inside a directory agy can write, so"
cp "$work/conf.saved" "$prefixroot/opt/agy/etc/sandbox.conf"
echo "mask $work/glob*dir?" >> "$prefixroot/opt/agy/etc/sandbox.conf"
# The hook's bun: the pinned bytes, alone in its directory, at a release no older than 1.3.3.
cp "$prefixroot/opt/agy/hookbin/bun" "$work/bun.saved"
cp "$prefixroot/opt/agy/etc/pin" "$work/pin.saved"
rm "$prefixroot/opt/agy/hookbin/bun"
refuses "the hook's bun is missing" "hookbin/bun is missing"
cp "$work/bun.saved" "$prefixroot/opt/agy/hookbin/bun"
echo "# changed" >> "$prefixroot/opt/agy/hookbin/bun"
refuses "the hook's bun is not the pinned one" "is not the bun install-agy.sh pinned"
cp "$work/bun.saved" "$prefixroot/opt/agy/hookbin/bun"
cp "$work/bun.saved" "$prefixroot/opt/agy/hookbin/node"
refuses "the hook's bun directory holds another executable" "does not hold the pinned bun alone"
rm "$prefixroot/opt/agy/hookbin/node"
for old in 1.3.2 1.3.3-canary.1 v1.4.2; do
  printf '#!/bin/sh\necho %s\n' "$old" > "$prefixroot/opt/agy/hookbin/bun"
  sed -i "s|^bun_sha256=.*|bun_sha256=$(sha256sum "$prefixroot/opt/agy/hookbin/bun" | cut -d' ' -f1)|" "$prefixroot/opt/agy/etc/pin"
  refuses "the hook's bun reports $old" "not a release at or above 1.3.3"
done
cp "$work/bun.saved" "$prefixroot/opt/agy/hookbin/bun"
cp "$work/pin.saved" "$prefixroot/opt/agy/etc/pin"
run true >/dev/null 2>&1 || fail "the launcher did not start again once the hook config was restored"

# A listening socket outside the usual places, standing in for a tmux or herdr server on a custom path.
python3 -I -c 'import socket, sys, time; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(); time.sleep(60)' \
  "$work/example.sock" &
listener=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$work/example.sock" ] && break; sleep 0.2; done
# shellcheck disable=SC2016 # expanded inside the sandbox
got=$(run 'python3 -I -c "import socket, sys; socket.socket(socket.AF_UNIX).connect(sys.argv[1])" '"$work/example.sock"' 2>/dev/null && echo reached || echo unreachable' 2>/dev/null)
kill "$listener" 2>/dev/null || true
[ "$got" = unreachable ] || fail "a listening socket outside the sandbox was reachable: $got"

# The in-namespace stage refuses when run directly, outside the sandbox, even with a findmnt that says read-only.
mkdir -p "$work/fakebin"
printf '#!/bin/sh\necho rw,ro\n' > "$work/fakebin/findmnt"
chmod +x "$work/fakebin/findmnt"
if (cd "$work/wt-example" && HOME="$home" PATH="$work/fakebin:$PATH" "$agy" --inside true) >/dev/null 2>&1; then
  fail "--inside started agy outside the sandbox"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures agy-sandbox check(s) failed"
  exit 1
fi
echo "agy-sandbox: ok"
