#!/usr/bin/env bash
# The plugin's shape: Claude Code only, invoke-only, and two hooks, neither of which can approve anything.
# Runs under macOS's bash 3.2 as well as Linux: bash test/structure.test.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
fail() {
  echo "FAIL: $1"
  failures=$((failures + 1))
}

command -v jq >/dev/null 2>&1 || {
  echo "jq is required" >&2
  exit 2
}

manifest="$root/.claude-plugin/plugin.json"
[ "$(jq -r '.name' "$manifest")" = anderton ] || fail "plugin.json name must be anderton"
[ "$(jq -r 'has("hooks")' "$manifest")" = false ] || fail "plugin.json must not declare hooks"
[ "$(jq -r '.skills' "$manifest")" = ./skills/ ] || fail "plugin.json skills must be ./skills/"
# Without a version, each install and update takes the repository's latest commit.
[ "$(jq -r 'has("version")' "$manifest")" = false ] || fail "plugin.json must not pin a version"

# The scripts read Claude Code's own session registry, so a Codex manifest would install a skill that cannot work.
for path in .codex-plugin always-on.md; do
  [ ! -e "$root/$path" ] || fail "$path must not exist"
done

# A background hook cannot return a decision, and the reporting gate only blocks, so the plugin can never answer a
# permission prompt.
hooks="$root/hooks/hooks.json"
[ "$(jq -c '.hooks | keys' "$hooks")" = '["PreToolUse","Stop"]' ] || fail "hooks.json must hook only Stop and PreToolUse"
[ "$(jq '[.hooks[][].hooks[]] | length' "$hooks")" = 2 ] || fail "hooks.json must have two handlers"
jq -e '.hooks.PreToolUse | length == 1 and .[0].matcher == "SendMessage"
  and (.[0].hooks[0].command | endswith("/skills/anderton/scripts/report-gate.sh\""))' "$hooks" >/dev/null ||
  fail "the PreToolUse hook must run report-gate.sh on SendMessage only"
# A PreToolUse hook that printed a decision could allow a call; the gate's only verdict is exit 2.
! grep -q 'permissionDecision\|"decision"\|"allow"' "$root/skills/anderton/scripts/report-gate.sh" ||
  fail "report-gate.sh must not print a hook decision"
jq -e '.hooks.Stop[0].hooks[0] | .type == "command" and .asyncRewake == true and (.command | endswith("/skills/anderton/scripts/watch.sh\""))' "$hooks" >/dev/null ||
  fail "the Stop hook must run watch.sh in the background with asyncRewake"
# Claude Code enforces timeout on asyncRewake, and its default of 600 seconds would end an idle holder's watch.
[ "$(jq '.hooks.Stop[0].hooks[0].timeout' "$hooks")" -ge 86400 ] || fail "the Stop hook's timeout must outlast an idle day"

awk 'NR == 1 { if ($0 != "---") exit; next }
  $0 == "---" { closed = 1; exit }
  $0 == "disable-model-invocation: true" { found = 1 }
  END { exit (closed && found) ? 0 : 1 }' "$root/skills/anderton/SKILL.md" ||
  fail "SKILL.md frontmatter must set disable-model-invocation: true"

for script in claim.sh waiting.sh spawn.sh retire.sh watch.sh prompt.sh report-gate.sh; do
  [ -x "$root/skills/anderton/scripts/$script" ] || fail "scripts/$script must exist and be executable"
done
[ -f "$root/skills/anderton/scripts/session-lib.sh" ] || fail "scripts/session-lib.sh must exist"

# pstack/LICENSE at the commit NOTICE.md pins; the copy must be verbatim.
expected=bc957ca6bee02792566a1a028d105e02e247c6e77cf057061674273da77b200e
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$root/LICENSE-PSTACK" | cut -d' ' -f1)
else
  actual=$(shasum -a 256 "$root/LICENSE-PSTACK" | cut -d' ' -f1)
fi
[ "$actual" = "$expected" ] || fail "LICENSE-PSTACK must be pstack/LICENSE verbatim"

if [ "$failures" -gt 0 ]; then
  echo "$failures structure check(s) failed"
  exit 1
fi
echo "structure: ok"
