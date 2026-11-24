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
mkdir -p "$work/release" "$work/guard/guards" "$work/home"
cat > "$work/release/antigravity" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = --dangerously-skip-permissions ] || { echo "launched without --dangerously-skip-permissions" >&2; exit 9; }
exec bash -c "$2"
FAKE
chmod +x "$work/release/antigravity"
tar -czf "$work/release.tar.gz" -C "$work/release" antigravity
printf 'version=0.0.0-test\nurl=https://example.invalid/agy.tar.gz\nsha256=%s\n' \
  "$(sha256sum "$work/release.tar.gz" | cut -d' ' -f1)" > "$work/agy.pin"
printf '#!/usr/bin/env bash\necho example guard\n' > "$work/guard/agy-guard.sh"
printf 'export {};\n' > "$work/guard/agy-guard.ts"
home="$work/home"
"$scripts/install-agy.sh" --user "$(id -un)" --home "$home" --guard "$work/guard" --prefix "$work/opt" \
  --pin "$work/agy.pin" --tarball "$work/release.tar.gz" >/dev/null
touch "$work/opt/agy/etc/user-owned-test-install"
agy="$work/opt/agy/bin/agy"

# The install refuses a release that does not match its pin.
printf 'tampered' >> "$work/release.tar.gz"
if "$scripts/install-agy.sh" --user "$(id -un)" --home "$home" --guard "$work/guard" --prefix "$work/other" \
  --pin "$work/agy.pin" --tarball "$work/release.tar.gz" >/dev/null 2>&1; then
  fail "install accepted a tarball that does not match the pin"
fi

git init -q "$work/repo"
git -C "$work/repo" -c user.name=example -c user.email=example@example.invalid commit -q --allow-empty -m init
git -C "$work/repo" worktree add -q --detach "$work/wt-example" HEAD
mkdir -p "$home/.claude"
echo canary-value > "$home/.claude/canary"
mkdir -p "$home/.cache"

# Descriptor 9, a directory opened outside, stands in for one a launching shell leaks into the sandbox.
run() {
  (cd "$work/wt-example" && exec 9<"$work/wt-example" && env -i HOME="$home" PATH=/usr/bin:/bin "$agy" "$1")
}

# shellcheck disable=SC2016 # expanded inside the sandbox
attempts='
w() { if (eval "$2") >/dev/null 2>&1; then echo "wrote $1"; else echo "denied $1"; fi; }
w worktree-agents       "echo x > .agents/hooks.json"
w worktree-agents-mv    "mv .agents agents-moved"
w global-hooks          "echo {} > $HOME/.gemini/config/hooks.json"
w gemini-hooks          "echo {} > $HOME/.gemini/hooks.json"
w state-hooks           "echo {} > $HOME/.gemini/antigravity-cli/hooks.json"
w state-plugins         "mkdir $HOME/.gemini/antigravity-cli/plugins/example"
w state-agents-json     "echo [] > $HOME/.gemini/antigravity-cli/agents.json"
w gemini-moved          "mv $HOME/.gemini $HOME/gemini-moved"
w git-hooks             "echo x > $(git rev-parse --git-common-dir)/hooks/post-checkout"
w git-config            "git config --file $(git rev-parse --git-common-dir)/config core.hooksPath /tmp"
w home-rc               "echo x >> $HOME/.bashrc"
w python-write          "python3 -c \"open(\x27.agents/hooks.json\x27, \x27w\x27)\""
w unshare-umount        "unshare -Urm sh -c \"umount .agents && echo x > .agents/hooks.json\""
w inherited-fd          "echo x > /proc/self/fd/9/.agents/hooks.json"
w read-claude-canary    "grep -q canary-value $HOME/.claude/canary"
w worktree-file         "echo x > example.txt"
w git-commit            "git add example.txt && git -c user.name=example -c user.email=example@example.invalid commit -qm example"
w state-file            "echo x > $HOME/.gemini/antigravity-cli/example.log"
w cache-file            "echo x > $HOME/.cache/example"
w tmp-file              "echo x > /tmp/agy-sandbox-example-$$"
'
out=$(run "$attempts" 2>&1) || fail "the launcher did not start: $out"
for denied in worktree-agents worktree-agents-mv global-hooks gemini-hooks state-hooks state-plugins state-agents-json \
  gemini-moved git-hooks git-config home-rc python-write unshare-umount inherited-fd read-claude-canary; do
  printf '%s\n' "$out" | grep -qx "denied $denied" || fail "$denied was not denied: $(printf '%s\n' "$out" | grep " $denied\$")"
done
for wrote in worktree-file git-commit state-file cache-file tmp-file; do
  printf '%s\n' "$out" | grep -qx "wrote $wrote" || fail "$wrote should be writable: $(printf '%s\n' "$out" | grep " $wrote\$")"
done

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
run true >/dev/null 2>&1 || fail "the launcher did not start again once the hook config was restored"

# The in-namespace stage refuses when run directly, outside the sandbox.
if (cd "$work/wt-example" && HOME="$home" "$agy" --inside true) >/dev/null 2>&1; then
  fail "--inside started agy outside the sandbox"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures agy-sandbox check(s) failed"
  exit 1
fi
echo "agy-sandbox: ok"
