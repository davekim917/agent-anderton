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
version=$(pinned version)
agy="$base/$version/antigravity"
[ -n "$version" ] && [ -x "$agy" ] || die "the pinned agy $version is not installed under $base."
[ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "HOME is not set."
gemini="$HOME/.gemini"
state="$gemini/antigravity-cli"
# agy reads these from its state directory; a worker that could write one could add hooks, plugins or agents.
customizations="agents agents.json plugins plugins.json rules rules.json skills skills.json workflows hooks.json secplugins"

# Every path the view below binds read-only, in bind order, for the check inside too. Host git reads the repository's
# config, config.worktree, hooks and info, and this worktree's config.worktree, commondir and .git pointer, so a worker
# that could write one could have host git run a command of its choosing.
read_only_paths() {
  local wt=$1 common=$2 gitdir=$3 entry
  printf '%s\n' "$wt/.agents" "$common/hooks" "$common/config" "$common/config.worktree" "$common/info" \
    "$gemini/config" "$gemini/hooks.json"
  if [ "$gitdir" != "$common" ]; then printf '%s\n' "$gitdir/config.worktree" "$gitdir/commondir" "$wt/.git"; fi
  for entry in $customizations; do printf '%s\n' "$state/$entry"; done
}

# The files the guard reads its merge and response-secret policy from. They sit outside every writable root, so the
# read-only view of the host covers them; binding a missing one would create it.
scope_files() {
  local dir
  dir=$(pinned scope_dir)
  [ -z "$dir" ] || printf '%s\n' "$dir/merge-scope.local.json" "$dir/response-secrets.local.json"
}

inside() {
  local wt common gitdir path options
  # The caller's PATH chose nothing so far; every tool below is named by its path.
  [ "$(/usr/bin/tr -d '\0' < /proc/1/comm 2>/dev/null)" = bwrap ] || die "--inside runs only as bwrap's child."
  case ,$(/usr/bin/findmnt -rn -o OPTIONS --mountpoint / | /usr/bin/head -n 1), in *,ro,*) ;; *) die "/ is not read-only here." ;; esac
  wt=$(/usr/bin/git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git worktree."
  common=$(cd "$(/usr/bin/git rev-parse --git-common-dir)" && pwd -P)
  gitdir=$(cd "$(/usr/bin/git rev-parse --absolute-git-dir)" && pwd -P)
  [ "$(owner_of "$base")" = 0 ] || [ -e "$base/etc/user-owned-test-install" ] || die "$base is not root-owned."
  [ "$(sha256 "$agy")" = "$(pinned binary_sha256)" ] || die "$agy does not match its pinned digest."
  [ "$(sha256 "$gemini/config/hooks.json")" = "$(pinned hooks_sha256)" ] ||
    die "$gemini/config/hooks.json is not the guard registration install-agy.sh wrote."
  [ "$(sha256 "$base/libexec/agy-guard-hook")" = "$(pinned hook_sha256)" ] ||
    die "$base/libexec/agy-guard-hook is not the hook install-agy.sh wrote."
  for path in "$gemini/hooks.json" "$state/hooks.json"; do
    case $(/usr/bin/tr -d '[:space:]' < "$path") in '' | '{}') ;; *) die "$path defines hooks; only $gemini/config/hooks.json may." ;; esac
  done
  refuse_workspace_config
  while IFS= read -r path; do
    [ -e "$path" ] || continue
    options=$(/usr/bin/findmnt -rn -o OPTIONS --mountpoint "$path" 2>/dev/null | /usr/bin/head -n 1) || options=""
    case ,$options, in *,ro,*) ;; *) die "$path is not mounted read-only; refusing to start agy outside its sandbox." ;; esac
  done <<EOF
$(read_only_paths "$wt" "$common" "$gitdir"; [ "$gitdir" = "$common" ] || echo "$common/worktrees")
EOF
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

owner_of() {
  /usr/bin/stat -c %u "$1"
}

# agy loads hooks and plugins from the .agents directory of the worktree, which it treats as the workspace root. A
# hooks.json there would load; a link there, even a dangling one, could point at a file the worker can still write.
refuse_workspace_config() {
  local entry
  for entry in hooks.json plugins plugins.json plugins.txt; do
    if [ "$entry" = hooks.json ] && { [ -e "$wt/.agents/$entry" ] || [ -L "$wt/.agents/$entry" ]; }; then
      die "$wt/.agents/hooks.json exists; workspace hooks can switch the guard off."
    fi
    if [ -L "$wt/.agents/$entry" ]; then
      die "$wt/.agents/$entry is a symbolic link; its target could stay writable."
    fi
  done
}

if [ "${1:-}" = --inside ]; then
  shift
  inside "$@"
fi

[ "$(uname -s)" = Linux ] || die "Linux only."
bwrap=$(pinned bwrap)
[ -n "$bwrap" ] && [ -x "$bwrap" ] || die "the bwrap install-agy.sh pinned (${bwrap:-none}) is not installed."
wt=$(git rev-parse --show-toplevel 2>/dev/null) || die "run it from the worker's git worktree."
wt=$(cd "$wt" && pwd -P)
[ "$(pwd -P)" = "$wt" ] || die "run it from the worktree's top level ($wt)."
common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
gitdir=$(cd "$(git rev-parse --absolute-git-dir)" && pwd -P)
[ -f "$gemini/config/hooks.json" ] || die "$gemini/config/hooks.json is missing; run register-agy.sh."

args=(--ro-bind / / --dev /dev --proc /proc --unshare-pid --die-with-parent)
writable=()
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

# Writable roots, each with the reason it is writable.
add_rw /tmp                          # shared scratch; scripts/test-safe.sh-style host-wide locks live here
add_rw "$wt"                         # the worker's own checkout
add_rw "$common"                     # commits, refs and fetches of that checkout
add_rw "$state"                      # agy's conversations, logs and caches
# Tool caches are this worktree's own, never the host's: host tools run what they cache (pre-commit's hook
# environments, packages pnpm hard-links into node_modules), so a shared cache would run worker code outside.
private="$HOME/.cache/anderton-agy/$(printf '%s' "$wt" | sha256sum | cut -c1-16)"
for name in cache pnpm bun npm; do mkdir -p "$private/$name"; done
# bwrap cannot make a mount point inside the read-only view, so each target exists first.
mkdir -p "$HOME/.cache" "$HOME/.local/share/pnpm" "$HOME/.bun/install/cache" "$HOME/.npm"
add_rw "$HOME/.cache" "$private/cache"
add_rw "$HOME/.local/share/pnpm" "$private/pnpm"
add_rw "$HOME/.bun/install/cache" "$private/bun"
add_rw "$HOME/.npm" "$private/npm"
if [ -f "$conf" ]; then
  while read -r kind path _; do
    path=${path/#\~/$HOME}
    case $kind in rw) add_rw "$path" ;; esac
  done < "$conf"
fi

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

# Hook and plugin config agy reads stays read-only, inside the writable roots too. The worktree's own git directory
# stays writable, the repository's list of worktrees around it does not.
mkdir -p "$wt/.agents" "$common/hooks" "$common/info"
if [ "$gitdir" != "$common" ]; then
  add_ro "$common/worktrees"
  args+=(--bind "$gitdir" "$gitdir")
fi
for path in "$gemini/hooks.json" "$state/hooks.json"; do
  [ -f "$path" ] || die "$path is missing; run install-agy.sh."
done
for entry in agents plugins rules skills workflows secplugins; do mkdir -p "$state/$entry"; done
while IFS= read -r path; do add_ro "$path"; done <<EOF
$(read_only_paths "$wt" "$common" "$gitdir")
EOF
# A second hard link to any protected file, made before launch inside a writable root, would write it past the bind.
while IFS= read -r path; do
  [ -e "$path" ] || continue
  alias=$(find "$path" -type f -links +1 -print -quit) || die "could not check $path for hard links."
  [ -z "$alias" ] || die "$alias has another hard link; remove it before starting agy."
done <<EOF
$(read_only_paths "$wt" "$common" "$gitdir"; scope_files; echo "$base/libexec/agy-guard-hook")
EOF

# Credential stores, and sockets of processes that would run a command outside the sandbox.
# A store created after launch would not be masked, so the usual ones are masked even while empty.
for path in "$HOME/.claude" "$HOME/.codex" "$HOME/.config/gh" "$HOME/.ssh" "$HOME/.gnupg" "$HOME/.aws" \
  "$HOME/.config/gcloud" "$HOME/.docker"; do
  mkdir -p "$path"
done
for path in "$HOME/.claude" "$HOME/.codex" "$HOME"/.codex-* "$HOME/.config/gh" "$HOME/.ssh" "$HOME/.gnupg" \
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
      mask)
        # A glob such as ~/.codex* names every match; one that matches nothing hides nothing.
        while IFS= read -r match; do [ -z "$match" ] || add_mask "$match"; done <<EOF
$(compgen -G "$path" || true)
EOF
        ;;
      gh-token-file) token_file=$path ;;
    esac
  done < "$conf"
fi

env=(HOME="$HOME" USER="${USER:-$(id -un)}" LOGNAME="${LOGNAME:-$(id -un)}" TERM="${TERM:-xterm-256color}"
  PATH="$base/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$HOME/.bun/bin" AGY_CLI_DISABLE_AUTO_UPDATE=true)
for name in COLORTERM LANG LC_ALL TZ HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy; do
  if [ -n "${!name:-}" ]; then env+=("$name=${!name}"); fi
done
if [ -n "$token_file" ] && [ -r "$token_file" ]; then
  env+=("GH_TOKEN=$(tr -d '[:space:]' < "$token_file")")
fi

# A directory descriptor inherited from outside would reach the host's writable view of a protected path, so every
# descriptor above stderr is closed in the process that becomes bwrap. bash cannot do it itself: it keeps the script open.
exec python3 -I -c 'import os, sys; os.closerange(3, 1 << 30); os.execvp(sys.argv[1], sys.argv[1:])' \
  env -i "${env[@]}" "$bwrap" "${args[@]}" --chdir "$wt" -- "$self" --inside "$@"
