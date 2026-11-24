#!/usr/bin/env bash
# The agy launcher against a throwaway install, home and repository: what a worker inside it can and cannot change.
# Linux with bwrap and unprivileged user namespaces only; elsewhere it says why and passes.
# Runs: bash test/agy-sandbox.test.sh
set -euo pipefail

scripts="$(cd "$(dirname "$0")/../skills/anderton/scripts" && pwd)"
if [ "$(uname -s)" != Linux ] || ! command -v bwrap >/dev/null 2>&1 ||
  ! bwrap --ro-bind / / --dev /dev --proc /proc --unshare-pid true 2>/dev/null; then
  # Asked to check a root-owned install (CI's Linux runner), a host that cannot run the sandbox fails, never skips.
  if [ "${AGY_SANDBOX_SUDO:-}" = 1 ]; then
    echo "FAIL: AGY_SANDBOX_SUDO=1, but this host cannot run bwrap with unprivileged user namespaces"
    exit 1
  fi
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
rootdir=""
cleanup() {
  chmod u+w "$home/.bun" 2>/dev/null || true
  if [ -n "$rootdir" ]; then
    sudo -n chown -R "$(id -u)" "$home/.bun" 2>/dev/null || true
    sudo -n rm -rf "$rootdir"
  fi
  rm -rf "$work" "$bundir" "$prefixroot"
}
trap cleanup EXIT
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
# Before the owner's first login, agy has not migrated its configuration, and that migration would replace a
# registration written now: register-agy.sh refuses, and writes nothing.
if got=$(HOME="$home" "$scripts/register-agy.sh" --prefix "$prefixroot/opt" 2>&1); then
  fail "register-agy.sh registered before agy's first login"
else
  case $got in *"log in once"*) ;; *) fail "register-agy.sh refused before agy's first login for another reason: $got" ;; esac
fi
[ ! -e "$home/.gemini" ] || fail "register-agy.sh wrote in the home before agy's first login: $(find "$home/.gemini")"
# The owner's login leaves agy's migration marker and its stored login; the launcher refuses to start agy without the
# login.
mkdir -p "$home/.gemini/config" "$home/.gemini/antigravity-cli"
: > "$home/.gemini/config/.migrated"
echo example-token > "$home/.gemini/antigravity-cli/antigravity-oauth-token"
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
: > "$work/config-elsewhere/.migrated"
ln -s "$work/config-elsewhere" "$home/.gemini/config"
if HOME="$home" "$scripts/register-agy.sh" --prefix "$prefixroot/opt" >/dev/null 2>&1; then
  fail "register-agy.sh accepted a linked ~/.gemini/config"
fi
[ "$(ls -A "$work/config-elsewhere")" = .migrated ] || fail "register-agy.sh wrote through a linked ~/.gemini/config"
rm "$home/.gemini/config"
mv "$work/config.saved" "$home/.gemini/config"
mv "$home/.gemini/hooks.json" "$work/gemini-hooks.saved"
ln -s "$work/canary" "$home/.gemini/hooks.json"
if HOME="$home" "$scripts/register-agy.sh" --prefix "$prefixroot/opt" >/dev/null 2>&1; then
  fail "register-agy.sh accepted a link where an empty hook file goes"
fi
rm "$home/.gemini/hooks.json"
mv "$work/gemini-hooks.saved" "$home/.gemini/hooks.json"
# agy's migration, after a registration written before the first login, moves the legacy antigravity-cli/hooks.json
# ({}) over config/hooks.json and leaves a link to it in its place. Rerun then, register-agy.sh writes the registration
# back and replaces the link, relative or absolute, with an empty file of its own.
pinned_hooks=$(sed -n 's/^hooks_sha256=//p' "$prefixroot/opt/agy/etc/pin")
for target in "$home/.gemini/config/hooks.json" ../config/hooks.json; do
  printf '{}' > "$home/.gemini/config/hooks.json"
  rm "$home/.gemini/antigravity-cli/hooks.json"
  ln -s "$target" "$home/.gemini/antigravity-cli/hooks.json"
  got=$(HOME="$home" "$scripts/register-agy.sh" --prefix "$prefixroot/opt" 2>&1) || fail "register-agy.sh refused agy's migration link to $target: $got"
  [ -f "$home/.gemini/antigravity-cli/hooks.json" ] && [ ! -L "$home/.gemini/antigravity-cli/hooks.json" ] &&
    [ "$(cat "$home/.gemini/antigravity-cli/hooks.json")" = '{}' ] ||
    fail "register-agy.sh did not replace agy's migration link to $target with an empty hook file"
  [ "$(sha256sum "$home/.gemini/config/hooks.json" | cut -d' ' -f1)" = "$pinned_hooks" ] ||
    fail "register-agy.sh did not write the registration back over agy's migration (link to $target)"
done
# A link there to anything else is refused, and nothing is written through it.
rm "$home/.gemini/antigravity-cli/hooks.json"
ln -s "$work/canary" "$home/.gemini/antigravity-cli/hooks.json"
if HOME="$home" "$scripts/register-agy.sh" --prefix "$prefixroot/opt" >/dev/null 2>&1; then
  fail "register-agy.sh accepted a link to another file where agy's state hook file goes"
fi
[ "$(cat "$work/canary")" = canary ] || fail "register-agy.sh wrote through a link to $(cat "$work/canary")"
# Where the link resolves is what counts, not its text: ../alias/../config/hooks.json reads as the registration's path,
# but through the alias link it lands on another file.
mkdir -p "$work/alias-target/sub" "$work/alias-target/config"
echo canary > "$work/alias-target/config/hooks.json"
ln -s "$work/alias-target/sub" "$home/.gemini/alias"
rm "$home/.gemini/antigravity-cli/hooks.json"
ln -s ../alias/../config/hooks.json "$home/.gemini/antigravity-cli/hooks.json"
if HOME="$home" "$scripts/register-agy.sh" --prefix "$prefixroot/opt" >/dev/null 2>&1; then
  fail "register-agy.sh accepted a link whose text, not its target, names config/hooks.json"
fi
[ -L "$home/.gemini/antigravity-cli/hooks.json" ] && [ "$(cat "$work/alias-target/config/hooks.json")" = canary ] ||
  fail "register-agy.sh replaced or wrote through a link that resolves elsewhere"
rm "$home/.gemini/alias" "$home/.gemini/antigravity-cli/hooks.json"
printf '{}' > "$home/.gemini/antigravity-cli/hooks.json"
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
(umask 022 && touch "$prefixroot/opt/agy/etc/user-owned-test-install")
agy="$prefixroot/opt/agy/bin/agy"

# The install refuses a release that does not match its pin.
printf 'tampered' >> "$work/release.tar.gz"
install_refusal "a tarball that does not match the pin" "$work/guard" "does not match the pinned sha256"

git init -q "$work/repo"
git -C "$work/repo" -c user.name=example -c user.email=example@example.invalid commit -q --allow-empty -m init
git -C "$work/repo" worktree add -q --detach "$work/wt-example" HEAD
git -C "$work/repo" worktree add -q --detach "$work/wt-other" HEAD
printf 'import sys\nopen(sys.argv[1], "w").write("x")\n' > "$work/wt-example/write.py"
# agy's built-in plugins, as its first start unpacks them.
mkdir -p "$home/.gemini/antigravity-cli/builtin/plugins/swarm"
echo '{}' > "$home/.gemini/antigravity-cli/builtin/plugins/swarm/plugin.json"
mkdir -p "$home/.claude" "$home/.codex-example" "$home/.codex.backup" "$home/.claude-example" "$home/.cache"
for canary in "$home/.claude/canary" "$home/.codex-example/canary" "$home/.codex.backup/auth.json" \
  "$home/.claude-example/canary" "$home/.claude.json" "$home/.git-credentials" "$home/.netrc" \
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
# A GitHub token file reaches the worker only as GH_TOKEN; the file itself is hidden, with no mask line for it.
mkdir -p "$work/tokens"
echo example-token > "$work/tokens/github.token"
echo "gh-token-file $work/tokens/github.token" >> "$prefixroot/opt/agy/etc/sandbox.conf"

# Descriptor 9, a directory opened outside, stands in for one a launching shell leaks into the sandbox.
run() {
  (cd "$work/wt-example" && exec 9<"$work/wt-example" && env -i HOME="$home" PATH=/usr/bin:/bin "$agy" "$1")
}

# shellcheck disable=SC2016 # expanded inside the sandbox
attempts='
w() { if (eval "$2") >/dev/null 2>&1; then echo "wrote $1"; else echo "denied $1"; fi; }
w worktree-agents       "echo x > .agents/hooks.json"
e() { if err=$( (eval "$2") 2>&1 >/dev/null); then echo "wrote $1"; else case $err in *"Read-only file system"*) echo "erofs $1" ;; *) echo "denied-otherwise $1: $err" ;; esac; fi; }
e alias-agent-hooks     "mkdir -p .agent && echo {} > .agent/hooks.json"
e alias-uagents-hooks   "mkdir -p _agents && echo {} > _agents/hooks.json"
e alias-uagent-hooks    "mkdir -p _agent && echo {} > _agent/hooks.json"
e root-agents-plugin    "mkdir -p .agents/plugins/example"
e alias-agent-plugin    "mkdir -p .agent/plugins/example"
e alias-uagents-plugin  "mkdir -p _agents/plugins/example"
e alias-uagent-plugin   "mkdir -p _agent/plugins/example"
w worktree-agents-mv    "mv .agents agents-moved"
w global-hooks          "echo {} > \"$HOME\"/.gemini/config/hooks.json"
w gemini-hooks          "echo {} > \"$HOME\"/.gemini/hooks.json"
w state-hooks           "echo {} > \"$HOME\"/.gemini/antigravity-cli/hooks.json"
w state-plugins         "mkdir \"$HOME\"/.gemini/antigravity-cli/plugins/example"
w state-agents-json     "echo [] > \"$HOME\"/.gemini/antigravity-cli/agents.json"
w state-builtin         "echo {} > \"$HOME\"/.gemini/antigravity-cli/builtin/plugins/swarm/plugin.json"
w state-builtin-new     "mkdir \"$HOME\"/.gemini/antigravity-cli/builtin/plugins/example"
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
w read-codex-backup     "grep -q canary-value \"$HOME\"/.codex.backup/auth.json"
w read-claude-prefix    "grep -q canary-value \"$HOME\"/.claude-example/canary"
w read-claude-json      "grep -q canary-value \"$HOME\"/.claude.json"
w read-token-file       "grep -q example-token '"$work"'/tokens/github.token"
w token-in-env          "[ \"\$GH_TOKEN\" = example-token ]"
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
  state-builtin state-builtin-new \
  gemini-moved git-hooks git-config home-rc python-write unshare-umount inherited-fd read-claude-canary read-codex-glob \
  read-codex-backup read-claude-prefix read-claude-json read-token-file \
  read-git-credentials read-netrc read-nanoclaw-data read-nanoclaw-env git-config-worktree git-info own-config-worktree \
  own-commondir git-pointer other-worktree git-config-local git-config-cond git-common-new read-glob-literal; do
  printf '%s\n' "$out" | grep -qx "denied $denied" || fail "$denied was not denied: $(printf '%s\n' "$out" | grep " $denied\$")"
done
for wrote in worktree-file python-control git-commit state-file cache-file tmp-file host-cache read-glob-sibling token-in-env; do
  printf '%s\n' "$out" | grep -qx "wrote $wrote" || fail "$wrote should be writable: $(printf '%s\n' "$out" | grep " $wrote\$")"
done
for root in alias-agent-hooks alias-uagents-hooks alias-uagent-hooks root-agents-plugin alias-agent-plugin \
  alias-uagents-plugin alias-uagent-plugin; do
  printf '%s\n' "$out" | grep -qx "erofs $root" || fail "$root was not refused read-only: $(printf '%s\n' "$out" | grep " $root")"
done
# The workspace roots the launcher creates are empty directories, which git does not list.
for root in .agents .agent _agents _agent; do
  [ -d "$work/wt-example/$root" ] && [ -z "$(ls -A "$work/wt-example/$root")" ] || fail "the launcher left $root other than an empty directory"
done
[ -z "$(git -C "$work/wt-example" status --porcelain --untracked-files=all -- .agents .agent _agents _agent)" ] ||
  fail "git lists the workspace roots the launcher created: $(git -C "$work/wt-example" status --porcelain --untracked-files=all)"
# The worker's cache is its own: what it writes there never reaches the cache host tools read and run from.
[ ! -e "$home/.cache/example" ] && [ ! -e "$home/.cache/pre-commit-example" ] ||
  fail "a write to the worker's ~/.cache reached the host's"
ls "$home"/.cache/anderton-agy/*/cache/pre-commit-example >/dev/null 2>&1 || fail "the worker's private cache kept nothing"
# A ~/.bun this user cannot write (one root installed bun into) and that holds no install cache yet: the launcher
# writes nothing under it and still starts, the worker gets a private bun cache there, and sees the rest read-only.
mkdir -p "$home/.bun/bin"
printf '#!/bin/sh\necho example-bun-tool\n' > "$home/.bun/bin/example-tool"
chmod 0755 "$home/.bun/bin/example-tool"
rm -rf "$home/.bun/install"
chmod 0555 "$home/.bun"
# shellcheck disable=SC2016 # expanded inside the sandbox
bun_attempts='
"$HOME"/.bun/bin/example-tool
if echo x > "$HOME"/.bun/install/cache/example-package; then echo "wrote bun-cache"; fi
if (echo x > "$HOME"/.bun/planted) 2>/dev/null; then echo "wrote bun-home"; else echo "denied bun-home"; fi
'
out=$(run "$bun_attempts" 2>&1) || fail "the launcher did not start with an unwritable ~/.bun: $out"
for line in example-bun-tool "wrote bun-cache" "denied bun-home"; do
  printf '%s\n' "$out" | grep -qx "$line" || fail "with an unwritable ~/.bun, the worker did not report '$line': $out"
done
[ "$(ls -A "$home/.bun")" = bin ] || fail "the launcher or worker wrote under an unwritable ~/.bun: $(ls -A "$home/.bun")"
ls "$home"/.cache/anderton-agy/*/bun/example-package >/dev/null 2>&1 || fail "the worker's bun cache under an unwritable ~/.bun is not its private one"
# One whose entries cannot be listed (0111 here; 0711, root's) would lose them under the tmpfs, so the launcher refuses it; so it does an
# entry that is a link into the private cache, which would put a directory the worker writes where the host has none.
cache_refusal() { # cache_refusal <description> <expected text>
  if got=$(run true 2>&1); then fail "the launcher started with $1"; else
    case $got in *"$2"*) ;; *) fail "the launcher refused $1 for another reason: $got" ;; esac
  fi
}
chmod 0111 "$home/.bun"
cache_refusal "a ~/.bun it cannot list" "cannot be listed"
chmod 0755 "$home/.bun"
rm -rf "$home/.bun/install"
ln -s install/cache/bin "$home/.bun/example-link"
chmod 0555 "$home/.bun"
cache_refusal "a ~/.bun entry that links into the private cache" "links into a directory agy can write"
chmod 0755 "$home/.bun"
rm "$home/.bun/example-link"

# The pid the launcher writes to the file spawn.sh names is its bwrap, with the sandbox in a child of it, started from
# the pane herdr placed it in: what spawn.sh proves before it sends a brief.
launch="$work/launch.pid"
# shellcheck disable=SC2016 # expanded by the inner bash
(cd "$work/wt-example" && env -i HOME="$home" PATH=/usr/bin:/bin HERDR_PANE_ID=w9:p5 HERDR_SOCKET_PATH="$work/herdr.sock" \
  bash -c '"$0" --anderton-launch-file "$1" "sleep 30"; true' "$agy" "$launch") >/dev/null 2>&1 &
launcher=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$launch" ] && [ -n "$(cat "/proc/$(cat "$launch")/task/"*/children 2>/dev/null)" ] && break
  sleep 0.25
done
pinned_bwrap=$(sed -n 's/^bwrap=//p' "$prefixroot/opt/agy/etc/pin")
# shellcheck disable=SC1091 # the script under test, sourced at run time
proven() { (. "$scripts/session-lib.sh" && agy_sandbox_proven "$(cat "$launch")" "$pinned_bwrap" "$1" "$work/herdr.sock"); }
proven w9:p5 || fail "the launcher's recorded pid is not proven to be its sandbox in its pane"
if proven w9:p6; then fail "the launcher's sandbox was proven for a pane it did not start in"; fi
kill "$launcher" 2>/dev/null || true
wait "$launcher" 2>/dev/null || true
# A start whose view cannot be set up (a pinned bwrap that fails once, as one does when a socket it masks closes as it
# starts) ends with 75 and "unstarted" in the launch file, having run nothing; the next start runs.
printf '#!/bin/sh\nif [ ! -e "%s" ]; then : > "%s"; exit 1; fi\nexec "%s" "$@"\n' "$work/bwrap-failed" "$work/bwrap-failed" \
  "$pinned_bwrap" > "$work/bwrap-once"
chmod 0755 "$work/bwrap-once"
cp "$prefixroot/opt/agy/etc/pin" "$work/pin.saved"
sed -i "s|^bwrap=.*|bwrap=$work/bwrap-once|" "$prefixroot/opt/agy/etc/pin"
start_once() { # start_once <launch file>: the launcher, from the worktree, running a command that leaves a mark there
  (cd "$work/wt-example" && env -i HOME="$home" PATH=/usr/bin:/bin "$agy" --anderton-launch-file "$1" "echo ran > agy-ran")
}
status=0
start_once "$work/launch-once.pid" >/dev/null 2>&1 || status=$?
[ "$status" -eq 75 ] && [ "$(cat "$work/launch-once.pid")" = unstarted ] && [ ! -e "$work/wt-example/agy-ran" ] ||
  fail "a start whose sandbox could not be set up did not end with 75 and 'unstarted', having run nothing (status $status)"
rm -f "$work/launch-once.pid"
start_once "$work/launch-once.pid" >/dev/null 2>&1 || fail "the start after one that set up no sandbox did not run"
[ -e "$work/wt-example/agy-ran" ] || fail "the start after one that set up no sandbox ran nothing"
rm -f "$work/launch-once.pid" "$work/wt-example/agy-ran"
cp "$work/pin.saved" "$prefixroot/opt/agy/etc/pin"

# The inspection sandbox hides the token file too. A required clean filter, which runs there, fails when it reads the
# token's contents, and then git status, so the inspection, fails. The same inspection with no gh-token-file configured,
# so nothing masked, must fail: that proves the filter runs.
printf '#!/bin/sh\nif grep -q example-token "%s" 2>/dev/null; then exit 1; fi\ncat\n' "$work/tokens/github.token" > "$work/token-filter.sh"
chmod 0755 "$work/token-filter.sh"
printf '*.tok filter=tokcheck\n' > "$work/wt-example/.gitattributes"
echo example > "$work/wt-example/notes.tok"
git -C "$work/wt-example" add .gitattributes notes.tok
git -C "$work/wt-example" -c user.name=example -c user.email=example@example.invalid commit -qm "a filtered file"
git -C "$work/repo" config filter.tokcheck.clean "$work/token-filter.sh"
git -C "$work/repo" config filter.tokcheck.required true
inspect() { # inspect <day>: the inspection's answer for wt-example, after a stat change that makes git status run the filter
  touch -d "2001-01-0$1" "$work/wt-example/notes.tok"
  (cd "$work/wt-example" && env -i HOME="$home" PATH=/usr/bin:/bin "$agy" --anderton-worktree-work "$(git rev-parse HEAD)" 2>&1) ||
    echo "exit $?"
}
cp "$prefixroot/opt/agy/etc/sandbox.conf" "$work/conf.with-token"
grep -v '^gh-token-file ' "$work/conf.with-token" > "$prefixroot/opt/agy/etc/sandbox.conf"
inspected=$(inspect 1)
[ "$inspected" = unreadable ] || fail "with the token file unmasked, the inspection's filter did not fail on reading it: $inspected"
cp "$work/conf.with-token" "$prefixroot/opt/agy/etc/sandbox.conf"
inspected=$(inspect 2)
case $inspected in uncommitted | unpushed | clean) ;; *) fail "the inspection sandbox let the filter read the token file: $inspected" ;; esac
git -C "$work/repo" config --unset filter.tokcheck.clean
git -C "$work/repo" config --unset filter.tokcheck.required

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
# A custom agent definition can turn hooks off for its subagent, so the worktree may hold none, in any form.
mkdir -p "$work/wt-example/.agents/agents"
refuses "the worktree has a custom agent directory" ".agents/agents exists"
rmdir "$work/wt-example/.agents/agents"
: > "$work/wt-example/.agents/agents"
refuses "the worktree has a file where custom agents load" ".agents/agents exists"
rm "$work/wt-example/.agents/agents"
ln -s ../agents-elsewhere "$work/wt-example/.agents/agents"
refuses "the worktree has a dangling link where custom agents load" ".agents/agents exists"
rm "$work/wt-example/.agents/agents"
# The user's agent directory may exist only empty, and never as a link.
mkdir "$home/.gemini/config/agents"
run true >/dev/null 2>&1 || fail "the launcher refused an empty ~/.gemini/config/agents: $(run true 2>&1)"
printf -- '---\nname: example-agent\n---\n' > "$home/.gemini/config/agents/example-agent.md"
refuses "the user's config/agents holds a definition" "config/agents is not empty"
rm "$home/.gemini/config/agents/example-agent.md"
rmdir "$home/.gemini/config/agents"
mkdir "$work/agents-target"
ln -s "$work/agents-target" "$home/.gemini/config/agents"
refuses "the user's config/agents is a link to an empty directory" "config/agents is a symbolic link"
rm "$home/.gemini/config/agents"
# agy also reads .agent, _agents and _agent as workspace roots, like .agents: each may only be missing or empty.
for alias in .agent _agents _agent; do
  mkdir -p "$work/wt-example/$alias"
  echo '{}' > "$work/wt-example/$alias/hooks.json"
  refuses "the worktree's $alias holds hooks" "/$alias is not empty"
  rm -r "$work/wt-example/$alias"
  : > "$work/wt-example/$alias"
  refuses "the worktree has a $alias file" "/$alias is not a directory"
  rm "$work/wt-example/$alias"
  ln -s ../alias-elsewhere "$work/wt-example/$alias"
  refuses "the worktree has a dangling $alias link" "/$alias is a symbolic link"
  rm "$work/wt-example/$alias"
done
# A plugin's agents directory loads its definitions too, in the user's plugins and the worktree's; empty, it may stay.
mkdir -p "$home/.gemini/config/plugins/example/agents"
echo '{}' > "$home/.gemini/config/plugins/example/plugin.json"
run true >/dev/null 2>&1 || fail "the launcher refused a user plugin with an empty agents directory: $(run true 2>&1)"
printf -- '---\nname: example-agent\n---\n' > "$home/.gemini/config/plugins/example/agents/example-agent.md"
refuses "a user plugin holds an agent definition" "plugins/example/agents is not empty"
mv "$home/.gemini/config/plugins/example" "$work/plugin-elsewhere"
ln -s "$work/plugin-elsewhere" "$home/.gemini/config/plugins/example"
refuses "a user plugin is a link" "plugins/example is a symbolic link"
rm "$home/.gemini/config/plugins/example"
rm -r "$work/plugin-elsewhere"
mkdir -p "$work/wt-example/.agents/plugins/example/agents"
printf -- '---\nname: example-agent\n---\n' > "$work/wt-example/.agents/plugins/example/agents/example-agent.md"
refuses "a worktree plugin holds an agent definition" ".agents/plugins/example/agents is not empty"
rm -r "$work/wt-example/.agents/plugins"
# agy unpacks its built-ins on an unsandboxed run; the launcher never stands an empty directory in for them.
mv "$home/.gemini/antigravity-cli/builtin" "$work/builtin.saved"
refuses "agy's built-ins are missing" "builtin is missing; run"
[ ! -e "$home/.gemini/antigravity-cli/builtin" ] || fail "the launcher created a missing builtin directory"
mv "$work/builtin.saved" "$home/.gemini/antigravity-cli/builtin"
# A definition that appears after the checks before bwrap, as the sandbox starts, is refused by the checks inside it:
# the pinned bwrap, wrapped, plants one on the host just before it builds the real (not the dry-run) view.
cp "$prefixroot/opt/agy/etc/pin" "$work/pin.saved"
printf '#!/bin/sh\ncase " $* " in *" --inside "*) mkdir -p "%s" ;; esac\nexec "%s" "$@"\n' \
  "$work/wt-example/.agents/agents" "$(sed -n 's/^bwrap=//p' "$work/pin.saved")" > "$work/bwrap-plant"
chmod 0755 "$work/bwrap-plant"
sed -i "s|^bwrap=.*|bwrap=$work/bwrap-plant|" "$prefixroot/opt/agy/etc/pin"
if got=$(run "echo ran > agy-ran" 2>&1); then fail "started although a custom agent directory appeared as the sandbox started"; fi
case $got in *".agents/agents exists"*) ;; *) fail "the inside check refused a definition planted as the sandbox started for the wrong reason: $got" ;; esac
[ -d "$work/wt-example/.agents/agents" ] && [ ! -e "$work/wt-example/agy-ran" ] ||
  fail "the planted definition was not there, or agy ran, when the inside check ran"
rm -rf "$work/wt-example/.agents/agents" "$work/wt-example/agy-ran"
cp "$work/pin.saved" "$prefixroot/opt/agy/etc/pin"
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
# What an earlier install left under the prefix is read back only while no one else can have written it.
cp "$prefixroot/opt/agy/etc/sandbox.conf" "$work/conf.installed"
chmod g+w "$prefixroot/opt/agy/etc/sandbox.conf"
if got=$(install_root "$prefixroot/opt" 2>&1); then fail "install read back a group-writable sandbox.conf"; else
  case $got in *"is writable by others"*) ;; *) fail "install refused a group-writable sandbox.conf for another reason: $got" ;; esac
fi
chmod g-w "$prefixroot/opt/agy/etc/sandbox.conf"
mv "$prefixroot/opt/agy/etc/sandbox.conf" "$work/conf.elsewhere"
ln -s "$work/conf.elsewhere" "$prefixroot/opt/agy/etc/sandbox.conf"
if got=$(install_root "$prefixroot/opt" 2>&1); then fail "install read back a linked sandbox.conf"; else
  case $got in *"symbolic link"* | *"is writable by others"*) ;; *) fail "install refused a linked sandbox.conf for another reason: $got" ;; esac
fi
rm "$prefixroot/opt/agy/etc/sandbox.conf"
cp "$work/conf.installed" "$prefixroot/opt/agy/etc/sandbox.conf"
# A guard directory that is a link the installer owns, to a directory someone else could write, is refused too.
mv "$prefixroot/opt/agy-guard" "$work/agy-guard.installed"
mkdir "$work/guard-elsewhere"
ln -s "$work/guard-elsewhere" "$prefixroot/opt/agy-guard"
if got=$(install_root "$prefixroot/opt" 2>&1); then fail "install used a linked agy-guard directory"; else
  case $got in *"is a symbolic link"*) ;; *) fail "install refused a linked agy-guard directory for another reason: $got" ;; esac
fi
rm "$prefixroot/opt/agy-guard"
mv "$work/agy-guard.installed" "$prefixroot/opt/agy-guard"
(umask 022 && touch "$prefixroot/opt/agy/etc/user-owned-test-install")
cp "$prefixroot/opt/agy/libexec/agy-guard-hook" "$work/hook.saved"
echo "# changed" >> "$prefixroot/opt/agy/libexec/agy-guard-hook"
refuses "the guard hook script was changed" "is not the hook install-agy.sh wrote"
cp "$work/hook.saved" "$prefixroot/opt/agy/libexec/agy-guard-hook"
# A planted file that git configuration includes, inside the worktree.
git -C "$work/repo" config --add include.path "$work/wt-example/planted.config"
refuses "git configuration includes a file inside the worktree" "inside a directory agy can write"
git -C "$work/repo" config --unset include.path "$work/wt-example/planted.config"
# The same through a conditional include whose condition holds a space, which a split on spaces would cut short.
git -C "$work/repo" config "includeIf.gitdir:/srv/My Project/.git/.path" "$work/wt-example/planted.config"
refuses "a conditional include with a space in its condition names a file inside the worktree" "inside a directory agy can write"
git -C "$work/repo" config --unset "includeIf.gitdir:/srv/My Project/.git/.path"
# An included file with a second hard link inside the worktree, made before launch, stays writable through that link.
echo '[example]' > "$common/config.local"
ln "$common/config.local" "$work/wt-example/config-local-alias"
refuses "an included git configuration file has another hard link" "another hard link"
rm "$work/wt-example/config-local-alias" "$common/config.local"
# The same through a link: the included name is a symbolic link to a file with a second hard link in the worktree.
echo '[example]' > "$work/config-target"
ln "$work/config-target" "$work/wt-example/config-target-alias"
ln -s "$work/config-target" "$common/config.local"
refuses "an included git configuration file links to a file with another hard link" "another hard link"
rm "$work/wt-example/config-target-alias" "$common/config.local" "$work/config-target"
# Commands git would run from a writable root: a hook directory, an fsmonitor and a filter, relative or not.
for setting in "core.hooksPath .githooks" "core.hooksPath $work/wt-example/hooks" "core.fsmonitor ./fsmonitor.sh"; do
  key=${setting%% *}
  git -C "$work/repo" config "$key" "${setting#* }"
  echo x > "$work/wt-example/fmt.sh"
  refuses "git configuration sets $setting" "inside a directory agy can write"
  git -C "$work/repo" config --unset "$key"
  rm "$work/wt-example/fmt.sh"
done
# A filter command can name a script the worker writes after launch, so only git-lfs's commands may run.
for value in "sh ./fmt.sh" "$home/.cache/example-filter" "sh formatter.sh" "git-lfs filter-process --verbose"; do
  git -C "$work/repo" config filter.example.clean "$value"
  refuses "git configuration sets the filter command '$value'" "only git-lfs's filter-process"
  git -C "$work/repo" config --unset filter.example.clean
done
git -C "$work/repo" config filter.example.process "git-lfs filter-process"
git -C "$work/repo" config filter.example.clean "git-lfs clean -- %f"
git -C "$work/repo" config filter.example.smudge "git-lfs smudge -- %f"
git -C "$work/repo" config core.fsmonitor false
run true >/dev/null 2>&1 || fail "the launcher refused a filter run from PATH and core.fsmonitor false"
git -C "$work/repo" config --unset filter.example.process
git -C "$work/repo" config --unset filter.example.clean
git -C "$work/repo" config --unset filter.example.smudge
git -C "$work/repo" config --unset core.fsmonitor
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
installed_guard=$(sed -n 's/^guard=//p' "$prefixroot/opt/agy/etc/pin")
cp "$installed_guard/agy-supervisor.ts" "$work/supervisor.saved"
rm "$installed_guard/agy-supervisor.ts"
refuses "the installed guard lacks the supervisor its wrapper execs" "agy-supervisor.ts is missing"
printf 'export const WATCHDOG_SECONDS = 3655;\n' > "$installed_guard/agy-supervisor.ts"
refuses "the installed supervisor's deadline is too close to the hook timeout" "is not above the 3600-second approval wait"
cp "$work/supervisor.saved" "$installed_guard/agy-supervisor.ts"
mv "$home/.gemini/antigravity-cli/antigravity-oauth-token" "$work/token.saved"
refuses "agy has no stored login" "no stored login"
: > "$home/.gemini/antigravity-cli/antigravity-oauth-token"
refuses "agy's stored login is empty" "no stored login"
mv "$work/token.saved" "$home/.gemini/antigravity-cli/antigravity-oauth-token"
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

# A real install is root's, and inside the sandbox's user namespace root is unmapped: the checks there see the install
# as owned by the overflow uid. Installed by root with no test marker, the launcher must still start agy, also with
# the ~/.bun root owns on such a host. Root is needed, so this runs only where AGY_SANDBOX_SUDO=1 says passwordless sudo
# may install as root (CI's Linux runner); asked for and unavailable, it fails.
if [ "${AGY_SANDBOX_SUDO:-}" != 1 ]; then
  echo "agy-sandbox: root-owned install skipped (set AGY_SANDBOX_SUDO=1 where passwordless sudo may install as root)"
elif ! sudo -n true 2>/dev/null; then
  fail "AGY_SANDBOX_SUDO=1, but sudo needs a password, so the root-owned install was not checked"
else
  # The install needs a parent that root owns, with every directory above it, and no one else can write.
  root_parent=""
  for candidate in /opt /srv /var/lib /usr/local; do
    check=$candidate
    while [ -d "$check" ] && [ "$(stat -c %u "$check")" = 0 ] && [ $((0$(stat -c %a "$check") & 022)) -eq 0 ]; do
      if [ "$check" = / ]; then root_parent=$candidate; break; fi
      check=$(dirname "$check")
    done
    [ -z "$root_parent" ] || break
  done
  if [ -z "$root_parent" ]; then
    fail "no root-owned parent for the root-owned install: $(stat -c '%U %a %n' /opt /srv /var/lib /usr/local / 2>&1 | tr '\n' ';')"
  else
    rootdir=$(sudo -n mktemp -d "$root_parent/agy-sandbox-root.XXXXXX")
    sudo -n chmod 0755 "$rootdir"
    sudo -n install -d -m 0755 "$rootdir/bun"
    sudo -n install -m 0755 "$bundir/bun" "$rootdir/bun/bun"
    sudo -n "$scripts/install-agy.sh" --user "$(id -un)" --home "$home" --guard "$work/guard" --scope-dir "$work/scope" \
      --bun "$rootdir/bun/bun" --prefix "$rootdir/opt" --pin "$work/agy.pin" --tarball "$work/release.good.tar.gz" >/dev/null ||
      fail "the root stage failed as root"
    [ "$(stat -c %u "$rootdir/opt/agy")" = 0 ] && [ ! -e "$rootdir/opt/agy/etc/user-owned-test-install" ] ||
      fail "the root stage as root did not leave a root-owned install without the test marker"
    HOME="$home" "$scripts/register-agy.sh" --prefix "$rootdir/opt" --replace-hooks >/dev/null || fail "register-agy.sh failed for the root-owned install"
    rm -rf "$home/.bun/install"
    sudo -n chown 0:0 "$home/.bun"
    root_launch() { (cd "$work/wt-example" && env -i HOME="$home" PATH=/usr/bin:/bin "$rootdir/opt/agy/bin/agy" "$1"); }
    # Inside, the install shows as the overflow uid; as 0 only under a setuid bwrap, which makes no user namespace.
    if [ -u "$(sed -n 's/^bwrap=//p' "$rootdir/opt/agy/etc/pin")" ]; then want=0 branch="0, under a setuid bwrap"; else
      want=$(cat /proc/sys/kernel/overflowuid) branch="the overflow uid"
    fi
    seen=$(root_launch "stat -c %u $rootdir/opt/agy" 2>"$work/root-launch.err") ||
      fail "the launcher did not start agy from a root-owned install: $(cat "$work/root-launch.err")"
    if [ "$seen" = "$want" ]; then
      echo "agy-sandbox: the root-owned install showed inside the sandbox as uid $seen ($branch)"
    else
      fail "inside the sandbox the root-owned install showed as uid '$seen', not $want ($branch): $(cat "$work/root-launch.err")"
    fi
    # The release the launcher execs, and its version directory, are root's too: one another user owns could be
    # rewritten between the digest check and the exec.
    version=$(sed -n 's/^version=//p' "$rootdir/opt/agy/etc/pin")
    for owned in "$rootdir/opt/agy/$version/antigravity" "$rootdir/opt/agy/$version"; do
      sudo -n chown 1 "$owned"
      if got=$(root_launch true 2>&1); then fail "the launcher started with $owned owned by uid 1"; else
        case $got in *"$owned is not owned by root"*) ;; *) fail "the launcher refused $owned owned by uid 1 for another reason: $got" ;; esac
      fi
      sudo -n chown 0 "$owned"
    done
    sudo -n chown -R "$(id -u)" "$home/.bun"
  fi
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures agy-sandbox check(s) failed"
  exit 1
fi
echo "agy-sandbox: ok"
