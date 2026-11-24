#!/usr/bin/env bash
# Starts agy for an Anderton worker inside bwrap, so the worker cannot change the hook config that guards it.
# install-agy.sh installs this file root-owned as <prefix>/agy/bin/agy, next to etc/pin and etc/sandbox.conf; spawn.sh
# puts that bin directory first on the worker's PATH. Linux only: it needs bwrap and unprivileged user namespaces.
#
# The view inside is the host read-only, except the writable roots below. Hook and plugin config agy reads is
# read-only even inside those roots, credential stores are hidden, and so are the sockets of processes that would run
# a command for the worker outside the sandbox. The last checks run inside the new namespace, just before agy starts.
set -euo pipefail

self=$(readlink -f "$0")
base=$(cd "$(dirname "$self")/.." && pwd -P)
pin="$base/etc/pin"
conf="$base/etc/sandbox.conf"

die() {
  echo "agy-sandbox: $*" >&2
  exit 1
}

pinned() {
  sed -n "s/^$1=//p" "$pin" | head -n 1
}

sha256() {
  /usr/bin/sha256sum "$1" | /usr/bin/cut -d' ' -f1
}

[ -f "$pin" ] || die "no $pin; run install-agy.sh first."
# --anderton-worktree-work <base commit>: tell what in this worktree retiring it would lose (worktree_work's answer),
# by running git inside a read-only sandbox with no network, so nothing the worker wrote runs outside one.
# --anderton-worktree-refs <base commit>: the same, for what waiting.sh's finished reads (worktree_refs's answer).
inspect="" inspect_base=""
case ${1:-} in
  --anderton-worktree-work | --anderton-worktree-refs)
    [ $# -ge 2 ] || die "$1 needs the worktree's base commit."
    inspect=${1#--anderton-worktree-} inspect_base=$2
    ;;
esac
version=$(pinned version)
agy="$base/$version/antigravity"
case ${1:-} in
  --anderton-worktree-work | --anderton-worktree-refs | --inspect-inside) ;;
  *) [ -n "$version" ] && [ -x "$agy" ] || die "the pinned agy $version is not installed under $base." ;;
esac
[ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "HOME is not set."
gemini="$HOME/.gemini"
state="$gemini/antigravity-cli"
# agy reads these from its state directory; a worker that could write one could add hooks, plugins or agents. builtin
# holds the plugins and skills agy ships, the enabled swarm plugin among them.
customizations="agents agents.json plugins plugins.json rules rules.json skills skills.json workflows hooks.json secplugins builtin"

# Every path the view below binds read-only inside a writable root, in bind order, for the check inside too. Host git
# reads this worktree's config.worktree, commondir and .git pointer, so a worker that could write one could have host
# git run a command of its choosing. The repository's own git directory is read-only as a whole, apart from the parts
# commits and fetches write (common_writable).
read_only_paths() {
  local wt=$1 gitdir=$2 entry
  printf '%s\n' "$wt/.agents" "$gemini/config" "$gemini/hooks.json" "$gitdir/config.worktree" "$gitdir/commondir" "$wt/.git"
  for entry in $customizations; do printf '%s\n' "$state/$entry"; done
}

# The parts of the repository's git directory a worker writes to commit, fetch and push: object and ref storage, which
# git reads as data, never as configuration.
common_writable() {
  printf '%s\n' "$1/objects" "$1/refs" "$1/logs" "$1/packed-refs" "$1/FETCH_HEAD"
}

# The files the guard reads its merge and response-secret policy from. They sit outside every writable root, so the
# read-only view of the host covers them; binding a missing one would create it.
scope_files() {
  local dir
  dir=$(pinned scope_dir)
  [ -z "$dir" ] || printf '%s\n' "$dir/merge-scope.local.json" "$dir/response-secrets.local.json"
}

inside() {
  local wt common gitdir path options guard bun bun_version deadline hook_timeout overflow
  # The caller's PATH chose nothing so far; every tool below is named by its path.
  [ "$(/usr/bin/tr -d '\0' < /proc/1/comm 2>/dev/null)" = bwrap ] || die "--inside runs only as bwrap's child."
  case ,$(/usr/bin/findmnt -rn -o OPTIONS --mountpoint / | /usr/bin/head -n 1), in *,ro,*) ;; *) die "/ is not read-only here." ;; esac
  wt=$(/usr/bin/git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git worktree."
  common=$(cd "$(/usr/bin/git rev-parse --git-common-dir)" && pwd -P)
  gitdir=$(cd "$(/usr/bin/git rev-parse --absolute-git-dir)" && pwd -P)
  # In this user namespace only the worker's uid is mapped, so a root-owned install shows as the overflow uid (0 only
  # under a setuid bwrap, which makes none). The launcher proved the real owner before bwrap started; here the install
  # must still not be the worker's own, apart from a test install.
  overflow=$(/usr/bin/cat /proc/sys/kernel/overflowuid 2>/dev/null) || overflow=""
  case $(owner_of "$base") in
    0) ;;
    "$(/usr/bin/id -u)") [ -e "$base/etc/user-owned-test-install" ] || die "$base is not root-owned." ;;
    "$overflow") ;;
    *) die "$base is not root-owned." ;;
  esac
  [ "$(sha256 "$agy")" = "$(pinned binary_sha256)" ] || die "$agy does not match its pinned digest."
  [ "$(sha256 "$gemini/config/hooks.json")" = "$(pinned hooks_sha256)" ] ||
    die "$gemini/config/hooks.json is not the guard registration install-agy.sh wrote."
  [ "$(sha256 "$base/libexec/agy-guard-hook")" = "$(pinned hook_sha256)" ] ||
    die "$base/libexec/agy-guard-hook is not the hook install-agy.sh wrote."
  # The hook can decide only with all of these; without one, the wrapper denies every call or agy never runs it.
  guard=$(pinned guard)
  for path in /bin/bash "$guard/.complete" "$guard/agy-guard.sh" "$guard/agy-guard.ts" "$guard/agy-supervisor.ts"; do
    [ -f "$path" ] || die "$path is missing, so the guard hook cannot decide; rerun install-agy.sh."
  done
  # agy cuts the hook off at its registered timeout with no deny, so the supervisor's deadline must come first, with
  # room to print its own. The registration's bytes were checked above.
  deadline=$(/usr/bin/sed -n 's/^export const WATCHDOG_SECONDS = \([0-9][0-9]*\);$/\1/p' "$guard/agy-supervisor.ts" | /usr/bin/head -n 1)
  hook_timeout=$(/usr/bin/sed -n 's/.*"timeout":\([0-9][0-9]*\).*/\1/p' "$gemini/config/hooks.json" | /usr/bin/head -n 1)
  [ -n "$deadline" ] && [ -n "$hook_timeout" ] && [ "$deadline" -gt 3600 ] && [ "$deadline" -le $((hook_timeout - 10)) ] ||
    die "the guard supervisor's deadline (${deadline:-none}) is not above the 3600-second approval wait and 10 seconds under the hook timeout (${hook_timeout:-none})."
  # The guard wrapper runs "bun" from the hook's PATH, whose first directory must hold only the pinned copy, where the
  # worker cannot replace it.
  bun="$base/hookbin/bun"
  [ "$(/usr/bin/ls -A "$base/hookbin" 2>/dev/null)" = bun ] || die "$base/hookbin does not hold the pinned bun alone."
  [ "$(sha256 "$bun")" = "$(pinned bun_sha256)" ] || die "$bun is not the bun install-agy.sh pinned."
  case ,$(/usr/bin/findmnt -rn -o OPTIONS -T "$bun" | /usr/bin/head -n 1), in
    *,ro,*) ;;
    *) die "the guard hook's bun ($bun) is writable inside the sandbox." ;;
  esac
  bun_version=$(/usr/bin/env -i "$bun" --version 2>/dev/null) || bun_version=""
  if ! [[ $bun_version =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] ||
    [ $(( 10#${BASH_REMATCH[1]} * 1000000 + 10#${BASH_REMATCH[2]} * 1000 + 10#${BASH_REMATCH[3]} )) -lt 1003003 ]; then
    die "the guard hook's bun (${bun_version:-missing}) is not a release at or above 1.3.3, so it would deny every call."
  fi
  # Without a stored login agy starts its own sign-in, which only the owner may complete.
  [ -s "$state/antigravity-oauth-token" ] || die "agy has no stored login ($state/antigravity-oauth-token); the owner signs in first."
  for path in "$gemini/hooks.json" "$state/hooks.json"; do
    case $(/usr/bin/tr -d '[:space:]' < "$path") in '' | '{}') ;; *) die "$path defines hooks; only $gemini/config/hooks.json may." ;; esac
  done
  refuse_workspace_config
  while IFS= read -r path; do
    [ -e "$path" ] || continue
    options=$(/usr/bin/findmnt -rn -o OPTIONS --mountpoint "$path" 2>/dev/null | /usr/bin/head -n 1) || options=""
    case ,$options, in *,ro,*) ;; *) die "$path is not mounted read-only; refusing to start agy outside its sandbox." ;; esac
  done <<EOF
$(read_only_paths "$wt" "$gitdir")
EOF
  # The repository's git directory, and what host git reads from it, stay read-only here.
  for path in "$common" "$common/config" "$common/config.worktree" "$common/hooks" "$common/info" "$common/worktrees"; do
    [ ! -e "$path" ] || [ ! -w "$path" ] || die "$path is writable here; refusing to start agy outside its sandbox."
  done
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    for check in "$path" "$(/usr/bin/dirname "$path")"; do
      [ ! -e "$check" ] || [ ! -w "$check" ] || die "$check, which the guard reads, is writable here."
    done
  done <<EOF
$(scope_files)
EOF
  [ -n "${GH_TOKEN:-}" ] || echo "agy-sandbox: no GitHub token is configured, so this worker cannot push." >&2
  exec "$agy" --dangerously-skip-permissions "$@"
}

# worktree_work (session-lib.sh) inside the inspecting sandbox: prints uncommitted, flagged, unpushed, unreadable or,
# only when every check found nothing to keep, clean. git takes no lock and starts no helper it can be talked out of; one it cannot (a clean filter) runs here.
inspect_inside() {
  local out git
  [ "$(/usr/bin/tr -d '\0' < /proc/1/comm 2>/dev/null)" = bwrap ] || die "--inspect-inside runs only as bwrap's child."
  case ,$(/usr/bin/findmnt -rn -o OPTIONS --mountpoint / | /usr/bin/head -n 1), in *,ro,*) ;; *) die "/ is not read-only here." ;; esac
  git=(/usr/bin/git --no-optional-locks -c core.fsmonitor= -c core.hooksPath=/dev/null -c core.untrackedCache=false
    -c log.showSignature=false)
  if [ "$1" = refs ]; then refs_inside "$2"; fi
  shift
  out=$("${git[@]}" status --porcelain --untracked-files=normal 2>/dev/null) || { echo unreadable; exit 0; }
  if [ -n "$out" ]; then echo uncommitted; exit 0; fi
  out=$(set -o pipefail; "${git[@]}" ls-files -v 2>/dev/null | /usr/bin/cut -c1 | LC_ALL=C /usr/bin/sort -u) || { echo unreadable; exit 0; }
  case $out in *[abcdefghijklmnopqrstuvwxyzS]*) echo flagged; exit 0 ;; esac
  out=$("${git[@]}" rev-list -1 HEAD --not --remotes "$1" 2>/dev/null) || { echo unreadable; exit 0; }
  if [ -n "$out" ]; then echo unpushed; else echo clean; fi
  exit 0
}

# waiting.sh's finished inside the inspecting sandbox, with inspect_inside's git: HEAD, the remote branch work lands on,
# the checked-out branch, 1 when HEAD (moved off base $1) is in that remote branch, and when it landed there (epoch),
# separated by 0x1f, since any of the last four may be empty.
refs_inside() {
  local head ref branch land landed="" at=""
  head=$("${git[@]}" rev-parse -q --verify HEAD 2>/dev/null) || exit 1
  for ref in "$("${git[@]}" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)" origin/main origin/master; do
    if [ -n "$ref" ] && "${git[@]}" rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1; then break; fi
    ref=""
  done
  branch=$("${git[@]}" symbolic-ref -q --short HEAD 2>/dev/null || true)
  if [ -n "$ref" ] && [ "$head" != "$1" ] && "${git[@]}" merge-base --is-ancestor "$head" "$ref" 2>/dev/null; then
    landed=1
    land=$("${git[@]}" rev-list --first-parent --ancestry-path "$head..$ref" 2>/dev/null | /usr/bin/tail -n 1)
    if [ -z "$land" ] || [ "$("${git[@]}" rev-parse -q --verify "$land^1" 2>/dev/null)" = "$head" ]; then land=$head; fi
    at=$("${git[@]}" log -1 --format=%ct "$land" 2>/dev/null || true)
  fi
  printf '%s\037%s\037%s\037%s\037%s\n' "$head" "$ref" "$branch" "$landed" "$at"
  exit 0
}

owner_of() {
  /usr/bin/stat -c %u "$1"
}

# agy loads hooks and plugins from the .agents directory of the worktree, which it treats as the workspace root. A
# hooks.json there would load; a link there, even a dangling one, could point at a file the worker can still write.
# agy also loads custom agent definitions when it starts: from .agents/agents, ~/.gemini/config/agents and the agents
# directory of a plugin. One with inheritCustomizations: false, or inheritScopes none or repo_and_org, runs its subagent
# with no hooks at all, so the guard would not see it.
refuse_workspace_config() {
  local entry plugin
  for entry in hooks.json plugins plugins.json plugins.txt; do
    if [ "$entry" = hooks.json ] && { [ -e "$wt/.agents/$entry" ] || [ -L "$wt/.agents/$entry" ]; }; then
      die "$wt/.agents/hooks.json exists; workspace hooks can switch the guard off."
    fi
    if [ -L "$wt/.agents/$entry" ]; then
      die "$wt/.agents/$entry is a symbolic link; its target could stay writable."
    fi
  done
  if [ -e "$wt/.agents/agents" ] || [ -L "$wt/.agents/agents" ]; then
    die "$wt/.agents/agents exists; a custom agent defined there can run its subagent with no hooks, so the guard would not see it."
  fi
  # The other names agy reads as a workspace root, like .agents, and which are not read-only in the sandbox.
  for entry in .agent _agents _agent; do
    if [ -e "$wt/$entry" ] || [ -L "$wt/$entry" ]; then
      die "$wt/$entry exists; agy reads it as a workspace customization root, so its hooks or custom agents could switch the guard off."
    fi
  done
  refuse_agent_definitions "$gemini/config/agents"
  for plugin in "$gemini/config/plugins" "$wt/.agents/plugins"; do
    [ -d "$plugin" ] || continue
    for entry in "$plugin"/* "$plugin"/.[!.]* "$plugin"/..?*; do
      if [ -L "$entry" ]; then
        die "$entry is a symbolic link; its target could stay writable, and a plugin's custom agent can run its subagent with no hooks."
      fi
      [ ! -d "$entry" ] || refuse_agent_definitions "$entry/agents"
    done
  done
}

# refuse_agent_definitions <dir>: the directory may be missing or empty, never a link or anything holding a definition.
refuse_agent_definitions() {
  local dir=$1 entry
  if [ -L "$dir" ]; then
    die "$dir is a symbolic link; its target could stay writable, and a custom agent there can run its subagent with no hooks."
  fi
  [ -e "$dir" ] || return 0
  [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] ||
    die "$dir is not a directory agy-sandbox can list; a custom agent there can run its subagent with no hooks."
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    if [ -e "$entry" ] || [ -L "$entry" ]; then
      die "$dir is not empty ($entry); a custom agent there can run its subagent with no hooks, so the guard would not see it."
    fi
  done
}

if [ "${1:-}" = --inside ]; then
  shift
  inside "$@"
fi
if [ "${1:-}" = --inspect-inside ]; then
  inspect_inside "$2" "$3"
fi

# spawn.sh names a new file for this launcher to create with its pid, which exec keeps through to bwrap: with the pane's
# process tree and bwrap's namespace, it proves to spawn.sh that this launcher, not some other agy on PATH, started.
launch_file=""
if [ "${1:-}" = --anderton-launch-file ]; then
  [ $# -ge 2 ] || die "--anderton-launch-file needs a path."
  launch_file=$2
  shift 2
fi

writable=() restored_links=()
add_rw() { # add_rw <path> [<source>]: <path> writable, backed by <source> when one is given
  local path=$1 source=${2:-$1}
  [ -e "$source" ] || return 0
  # bwrap binds a link's target, which could be anywhere, and mounts onto a link's target too.
  [ "$(readlink -f "$source")" = "$source" ] || die "$source is or passes through a symbolic link; name the real path."
  [ ! -e "$path" ] || [ "$(readlink -f "$path")" = "$path" ] || die "$path is or passes through a symbolic link; name the real path."
  # A writable home, or anything above it, would make shell rc files and user services writable.
  case $path in / | "$HOME" | "$HOME"/) die "$path would make $HOME writable; refusing." ;; esac
  case $HOME/ in "$path"/*) die "$path would make $HOME writable; refusing." ;; esac
  args+=(--bind "$source" "$path")
  writable+=("$path")
}
# add_cache <path> <private dir>: <path> writable, backed by the private dir. bwrap cannot make a mount point inside the
# read-only view, so a missing <path> is made first, but only in a directory this user owns and can write. Below one it
# cannot write (a ~/.bun root installed bun into), the missing part is made in a tmpfs over the deepest directory that
# exists, with that directory's own entries bound back read-only and the tmpfs read-only too.
add_cache() {
  local path=$1 top=$1 entry
  while [ ! -e "$top" ] && [ ! -L "$top" ]; do top=$(dirname "$top"); done
  if [ "$top" != "$path" ]; then
    [ -d "$top" ] && [ "$(readlink -f "$top")" = "$top" ] ||
      die "$top is not a directory, or is or passes through a symbolic link, so $path cannot be made there."
    if [ -O "$top" ] && [ -w "$top" ]; then
      mkdir -p "$path"
    else
      case $top in "$HOME"/?*) ;; *) die "$top is not yours to write, so the worker's cache $path cannot be made." ;; esac
      [ -r "$top" ] && [ -x "$top" ] ||
        die "$top cannot be listed, so a tmpfs over it would hide what it holds; make it readable, or create $path."
      args+=(--tmpfs "$top")
      while IFS= read -r -d '' entry; do
        if [ -L "$entry" ]; then
          args+=(--symlink "$(readlink "$entry")" "$entry")
          restored_links+=("$entry")
        else
          args+=(--ro-bind "$entry" "$entry")
        fi
      done < <(find "$top" -mindepth 1 -maxdepth 1 -print0)
      add_rw "$path" "$2"
      args+=(--remount-ro "$top")
      return 0
    fi
  fi
  add_rw "$path" "$2"
}
inside_writable() { # inside_writable <path>: true when <path> lies in a writable root
  local root
  for root in "${writable[@]}"; do
    case $1 in "$root" | "$root"/*) return 0 ;; esac
  done
  return 1
}
add_ro() {
  if [ -e "$1" ]; then args+=(--ro-bind "$1" "$1"); else args+=(--ro-bind /dev/null "$1"); fi
}
add_mask() {
  local path
  [ -e "$1" ] || return 0
  path=$(readlink -f "$1")
  if [ -d "$path" ]; then args+=(--tmpfs "$path"); else args+=(--ro-bind /dev/null "$path"); fi
}

# Credential stores, and sockets of processes that would run a command outside the sandbox, hidden from both the
# worker's sandbox and the read-only one that inspects its worktree.
add_credential_masks() {
  local path kind name
  # The worker's sandbox lasts; a store created while it runs would not be masked. An inspection does not.
  [ -n "$inspect" ] || for path in "$HOME/.claude" "$HOME/.codex" "$HOME/.config/gh" "$HOME/.ssh" "$HOME/.gnupg" "$HOME/.aws" \
    "$HOME/.config/gcloud" "$HOME/.docker"; do
    mkdir -p "$path"
  done
  # Every entry of the home whose name starts with .codex or .claude (a backup, a second account), by a literal prefix.
  while IFS= read -r -d '' path; do
    name=${path##*/}
    if [ "${name#.codex}" != "$name" ] || [ "${name#.claude}" != "$name" ]; then add_mask "$path"; fi
  done < <(find "$HOME" -mindepth 1 -maxdepth 1 -print0)
  for path in "$HOME/.config/gh" "$HOME/.ssh" "$HOME/.gnupg" \
    "$HOME/.aws" "$HOME/.config/gcloud" "$HOME/.docker" "$HOME/.config/herdr" "$HOME/.config/pairfob" \
    "$HOME/.git-credentials" "$HOME/.netrc" \
    "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" "/tmp/tmux-$(id -u)" /var/run/docker.sock "${HERDR_SOCKET_PATH:-}"; do
    [ -z "$path" ] || add_mask "$path"
  done
  # Every listening Unix socket with a path, wherever it lives: a tmux or herdr server on a custom socket would run a
  # command for the worker outside the sandbox. One opened after launch is not covered.
  while read -r path; do
    case $path in /*) [ -S "$path" ] && add_mask "$path" ;; esac
  done <<EOF
$(ss -xlnH 2>/dev/null | awk '{ print $5 }')
EOF
  token_file=""
  if [ -f "$conf" ]; then
    # A mask or token file is the rest of its line, so a path may hold spaces.
    while read -r kind path; do
      path=${path/#\~/$HOME}
      case $kind in
        mask) add_mask "$path" ;; # literal: brackets, "*" and "?" in a path are its own characters
        gh-token-file) token_file=$path ;;
      esac
    done < "$conf"
  fi
  # The token reaches a worker only as GH_TOKEN; the file itself is hidden from every sandbox, a mask line or not.
  [ -z "$token_file" ] || add_mask "$token_file"
}

# bwrap mounts the whole view before it runs anything, and fails when a path it was given to mask has gone by then (a
# socket that closed after it was listed). A dry run of the same view, running only true, tells that apart from a start
# that ran something: the launcher then exits 75, having started nothing, and the caller may try again.
unstarted=75
view_sets_up() { # view_sets_up <bwrap args...>
  env -i PATH=/usr/bin:/bin "$bwrap" "$@" -- /bin/true >/dev/null 2>&1
}

[ "$(uname -s)" = Linux ] || die "Linux only."
bwrap=$(pinned bwrap)
[ -n "$bwrap" ] && [ -x "$bwrap" ] || die "the bwrap install-agy.sh pinned (${bwrap:-none}) is not installed."
if [ -n "$inspect" ]; then
  # Host git never reads the worktree, not even to find it: the caller runs this from its top level. Read-only
  # everywhere, no network, and the credential masks, so a helper the worktree names can run here and reach nothing.
  args=(--ro-bind / / --dev /dev --proc /proc --unshare-pid --unshare-net --die-with-parent)
  add_credential_masks
  if ! view_sets_up "${args[@]}" --chdir "$(pwd -P)"; then
    echo "agy-sandbox: the sandbox could not be set up; nothing started." >&2
    exit "$unstarted"
  fi
  exec python3 -I -c 'import os, sys; os.closerange(3, 1 << 30); os.execvp(sys.argv[1], sys.argv[1:])' \
    env -i HOME="$HOME" PATH=/usr/bin:/bin "$bwrap" "${args[@]}" --chdir "$(pwd -P)" -- "$self" --inspect-inside "$inspect" "$inspect_base"
fi
wt=$(git rev-parse --show-toplevel 2>/dev/null) || die "run it from the worker's git worktree."
wt=$(cd "$wt" && pwd -P)
[ "$(pwd -P)" = "$wt" ] || die "run it from the worktree's top level ($wt)."
common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
gitdir=$(cd "$(git rev-parse --absolute-git-dir)" && pwd -P)
# A linked worktree keeps its index and HEAD in a git directory of its own, which can stay writable while the
# repository's stays read-only; the main checkout keeps them in the repository's.
[ "$gitdir" != "$common" ] || die "run it from a linked worktree (git worktree add), not the repository's main checkout."
[ -f "$gemini/config/hooks.json" ] || die "$gemini/config/hooks.json is missing; run register-agy.sh."

args=(--ro-bind / / --dev /dev --proc /proc --unshare-pid --die-with-parent)

# Writable roots, each with the reason it is writable.
add_rw /tmp                          # shared scratch; scripts/test-safe.sh-style host-wide locks live here
add_rw "$wt"                         # the worker's own checkout
while IFS= read -r path; do          # commits, refs and fetches of that checkout
  case $path in */packed-refs | */FETCH_HEAD) [ -e "$path" ] || : > "$path" ;; *) mkdir -p "$path" ;; esac
  add_rw "$path"
done <<EOF
$(common_writable "$common")
EOF
add_rw "$gitdir"                     # this worktree's own HEAD, index and logs
add_rw "$state"                      # agy's conversations, logs and caches
# Tool caches are this worktree's own, never the host's: host tools run what they cache (pre-commit's hook
# environments, packages pnpm hard-links into node_modules), so a shared cache would run worker code outside.
private="$HOME/.cache/anderton-agy/$(printf '%s' "$wt" | sha256sum | cut -c1-16)"
for name in cache pnpm bun npm; do mkdir -p "$private/$name" || die "could not create the worker's private cache $private/$name."; done
add_cache "$HOME/.cache" "$private/cache"
add_cache "$HOME/.local/share/pnpm" "$private/pnpm"
add_cache "$HOME/.bun/install/cache" "$private/bun"
add_cache "$HOME/.npm" "$private/npm"
if [ -f "$conf" ]; then
  while read -r kind path _; do
    path=${path/#\~/$HOME}
    case $kind in rw) add_rw "$path" ;; esac
  done < "$conf"
fi
# A link add_cache bound back that resolves into a writable root would put a directory the worker writes where the host
# has none, on PATH for ~/.bun/bin.
for path in ${restored_links[@]+"${restored_links[@]}"}; do
  ! inside_writable "$(readlink -m "$path")" || die "$path links into a directory agy can write; remove the link, or create $(readlink -m "$path")."
done
# Outside those parts, the repository's git directory must not be writable at all.
! inside_writable "$common" || die "$common, the repository's git directory, is inside a directory agy can write."

# What agy and its hook run must stay as installed while agy runs: the release, the hook, the guard, the bun and every
# directory above each is
# root's (the installing user's, for a test install), and none is writable by anyone else or inside a writable root.
owner_ok() {
  case $(stat -c %u "$1") in 0) return 0 ;; "$(id -u)") [ -e "$base/etc/user-owned-test-install" ] ;; *) return 1 ;; esac
}
for path in "$agy" "$base/libexec/agy-guard-hook" "$(pinned guard)/agy-guard.sh" "$base/hookbin/bun"; do
  [ -e "$path" ] || die "$path is missing; rerun install-agy.sh."
  check=$path
  while :; do
    owner_ok "$check" || die "$check is not owned by root, so $path could be replaced while agy runs."
    if [ $((0$(stat -c %a "$check") & 022)) -ne 0 ] && { [ "$check" = "$path" ] || [ ! -k "$check" ]; }; then
      die "$check is writable by others, so $path could be replaced while agy runs."
    fi
    ! inside_writable "$check" || die "$check is inside a directory agy can write, so $path could be replaced while agy runs."
    [ "$check" = / ] && break
    check=$(dirname "$check")
  done
done

# Git configuration may include other files; one inside a writable root, or with a second hard link the worker could
# have made in one, would let the worker give git a setting. Every include from the system, global and repository
# configuration is followed, conditional ones too. git's NUL-separated output keeps a key or path with spaces whole.
config_values() { # config_values <config file> <key regex>: each value, NUL-terminated
  local entry
  while IFS= read -r -d '' entry; do
    case $entry in *$'\n'*) printf '%s\0' "${entry#*$'\n'}" ;; esac
  done < <(git config --file "$1" --null --get-regexp "$2" 2>/dev/null)
}
include_targets() { # include_targets <config file> <depth>: every file it includes, there yet or not, NUL-terminated
  local file=$1 depth=$2 value target
  [ -f "$file" ] && [ "$depth" -lt 10 ] || return 0
  while IFS= read -r -d '' value; do
    [ -n "$value" ] || continue
    case $value in
      \~/*) target="$HOME/${value#\~/}" ;;
      /*) target=$value ;;
      *) target="$(dirname "$file")/$value" ;;
    esac
    printf '%s\0' "$target"
    include_targets "$target" $((depth + 1))
  done < <(config_values "$file" '^include(if\..*)?\.path$')
}
config_files=() included=()
for path in /etc/gitconfig "$HOME/.gitconfig" "${XDG_CONFIG_HOME:-$HOME/.config}/git/config" "$common/config" \
  "$common/config.worktree" "$gitdir/config.worktree"; do
  [ ! -f "$path" ] || config_files+=("$path")
done
while IFS= read -r -d '' path; do included+=("$path"); done < <(
  for file in "${config_files[@]}"; do include_targets "$file" 0; done)
for path in "${included[@]}"; do [ ! -f "$path" ] || config_files+=("$path"); done
for path in "${config_files[@]}"; do
  # git reads the file a link names, so its links are what count.
  [ "$(stat -L -c %h "$path")" -le 1 ] || die "git configuration file $path has another hard link; remove it before starting agy."
done
for path in "${included[@]}"; do
  for check in "$path" "$(readlink -f "$path")"; do
    ! inside_writable "$check" || die "git configuration includes $path, which is inside a directory agy can write."
  done
done
# A hook directory, fsmonitor or filter command git would run from a writable root runs the worker's code, for host
# git most of all; host git must never run in an agy worktree (spawn.sh and retire.sh read it only inside a sandbox),
# and no setting may point it there either. A relative path is relative to the worktree git runs in.
resolves_writable() { # resolves_writable <path as configured>
  local path=$1
  case $path in \~/*) path="$HOME/${path#\~/}" ;; /*) ;; *) path="$wt/$path" ;; esac
  inside_writable "$path" || inside_writable "$(readlink -m "$path")"
}
for path in "${config_files[@]}"; do
  while IFS= read -r -d '' value; do
    resolves_writable "$value" && die "git configuration sets core.hooksPath $value, inside a directory agy can write."
  done < <(config_values "$path" '^core\.hookspath$')
  while IFS= read -r -d '' value; do
    case $(printf '%s' "$value" | tr '[:upper:]' '[:lower:]') in true | false | yes | no | on | off | 1 | 0 | '') continue ;; esac
    resolves_writable "${value%% *}" && die "git configuration sets core.fsmonitor $value, inside a directory agy can write."
  done < <(config_values "$path" '^core\.fsmonitor$')
  # A filter command can name a script the worker writes later, so only git-lfs's own commands are let through.
  while IFS= read -r -d '' value; do
    read -r -a words <<<"$value"
    case ${words[*]} in
      "git-lfs filter-process" | "git-lfs clean -- %f" | "git-lfs smudge -- %f") ;;
      *) die "git configuration runs the filter command '$value'; only git-lfs's filter-process, clean -- %f and smudge -- %f may run where agy works." ;;
    esac
  done < <(config_values "$path" '^filter\..*\.(clean|smudge|process)$')
done

refuse_workspace_config
# The guard's policy files, and their directory, may not sit where the worker can write them, nor be links that could.
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ ! -L "$path" ] || die "$path, which the guard reads, is a symbolic link."
  for check in "$path" "$(readlink -f "$path")" "$(dirname "$path")"; do
    ! inside_writable "$check" || die "$path, which the guard reads, is inside a directory agy can write."
  done
done <<EOF
$(scope_files)
EOF

# Hook and plugin config agy reads stays read-only, inside the writable roots too.
mkdir -p "$wt/.agents"
for path in "$gemini/hooks.json" "$state/hooks.json"; do
  [ -f "$path" ] || die "$path is missing; run install-agy.sh."
done
for entry in agents plugins rules skills workflows secplugins; do mkdir -p "$state/$entry"; done
# agy unpacks its built-ins there on a run outside the sandbox, and rewrites them only when their checksum changes. Read
# only here, an empty stand-in would leave agy without them.
[ -d "$state/builtin" ] && [ ! -L "$state/builtin" ] ||
  die "$state/builtin is missing; run agy once outside the sandbox ($agy, as the owner signs in) to seed it, then start the worker."
while IFS= read -r path; do add_ro "$path"; done <<EOF
$(read_only_paths "$wt" "$gitdir")
EOF
# A second hard link to any protected file, made before launch inside a writable root, would write it past the bind.
while IFS= read -r path; do
  [ -e "$path" ] || continue
  alias=$(find "$path" -type f -links +1 -print -quit) || die "could not check $path for hard links."
  [ -z "$alias" ] || die "$alias has another hard link; remove it before starting agy."
done <<EOF
$(read_only_paths "$wt" "$gitdir"; printf '%s\n' "$common/config" "$common/config.worktree" "$common/hooks" "$common/info"
  scope_files; echo "$base/libexec/agy-guard-hook")
EOF

add_credential_masks

env=(HOME="$HOME" USER="${USER:-$(id -un)}" LOGNAME="${LOGNAME:-$(id -un)}" TERM="${TERM:-xterm-256color}"
  PATH="$base/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$HOME/.bun/bin" AGY_CLI_DISABLE_AUTO_UPDATE=true)
for name in COLORTERM LANG LC_ALL TZ HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy; do
  if [ -n "${!name:-}" ]; then env+=("$name=${!name}"); fi
done
if [ -n "$token_file" ] && [ -r "$token_file" ]; then
  env+=("GH_TOKEN=$(tr -d '[:space:]' < "$token_file")")
fi

# The launch file says which happened: this pid, which is about to become bwrap, or "unstarted".
if ! view_sets_up "${args[@]}" --chdir "$wt"; then
  [ -z "$launch_file" ] || (set -C && echo unstarted > "$launch_file") 2>/dev/null || true
  echo "agy-sandbox: the sandbox could not be set up (a path it masks changed as it started); nothing started." >&2
  exit "$unstarted"
fi
if [ -n "$launch_file" ]; then
  (set -C && printf '%s\n' "$$" > "$launch_file") 2>/dev/null || die "could not create $launch_file; it may belong to an earlier launch."
fi
# A directory descriptor inherited from outside would reach the host's writable view of a protected path, so every
# descriptor above stderr is closed in the process that becomes bwrap. bash cannot do it itself: it keeps the script open.
exec python3 -I -c 'import os, sys; os.closerange(3, 1 << 30); os.execvp(sys.argv[1], sys.argv[1:])' \
  env -i "${env[@]}" "$bwrap" "${args[@]}" --chdir "$wt" -- "$self" --inside "$@"
