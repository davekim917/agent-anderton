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
  sha256sum "$1" | cut -d' ' -f1
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

# Every path the view below makes read-only, for the check inside.
read_only_paths() {
  local wt=$1 common=$2 entry
  printf '%s\n' "$wt/.agents" "$common/hooks" "$common/config" "$gemini/config" "$gemini/hooks.json"
  for entry in $customizations; do printf '%s\n' "$state/$entry"; done
}

inside() {
  local wt common path options entry dir
  wt=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git worktree."
  common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
  [ "$(owner_of "$base")" = 0 ] || [ -e "$base/etc/user-owned-test-install" ] || die "$base is not root-owned."
  [ "$(sha256 "$agy")" = "$(pinned binary_sha256)" ] || die "$agy does not match its pinned digest."
  [ "$(sha256 "$gemini/config/hooks.json")" = "$(pinned hooks_sha256)" ] ||
    die "$gemini/config/hooks.json is not the guard registration install-agy.sh wrote."
  for path in "$gemini/hooks.json" "$state/hooks.json"; do
    case $(tr -d '[:space:]' < "$path") in '' | '{}') ;; *) die "$path defines hooks; only $gemini/config/hooks.json may." ;; esac
  done
  dir=$PWD
  while :; do
    [ ! -e "$dir/.agents/hooks.json" ] || die "$dir/.agents/hooks.json exists; workspace hooks can switch the guard off."
    [ "$dir" != / ] || break
    dir=$(dirname "$dir")
  done
  while IFS= read -r path; do
    options=$(findmnt -rn -o OPTIONS --mountpoint "$path" 2>/dev/null | head -n 1) || options=""
    case ,$options, in *,ro,*) ;; *) die "$path is not mounted read-only; refusing to start agy outside its sandbox." ;; esac
  done <<EOF
$(read_only_paths "$wt" "$common")
EOF
  [ -n "${GH_TOKEN:-}" ] || echo "agy-sandbox: no GitHub token is configured, so this worker cannot push." >&2
  exec "$agy" --dangerously-skip-permissions "$@"
}

owner_of() {
  stat -c %u "$1"
}

if [ "${1:-}" = --inside ]; then
  shift
  inside "$@"
fi

[ "$(uname -s)" = Linux ] || die "Linux only."
command -v bwrap >/dev/null 2>&1 || die "bwrap is not installed."
wt=$(git rev-parse --show-toplevel 2>/dev/null) || die "run it from the worker's git worktree."
wt=$(cd "$wt" && pwd -P)
[ "$(pwd -P)" = "$wt" ] || die "run it from the worktree's top level ($wt)."
common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
[ -f "$gemini/config/hooks.json" ] || die "$gemini/config/hooks.json is missing; run install-agy.sh."

args=(--ro-bind / / --dev /dev --proc /proc --unshare-pid --die-with-parent)
add_rw() {
  if [ -e "$1" ]; then args+=(--bind "$1" "$1"); fi
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
add_rw "$HOME/.cache"                # tool caches
add_rw "$HOME/.local/share/pnpm"     # pnpm's content-addressed store
add_rw "$HOME/.bun/install/cache"    # bun's package cache
add_rw "$HOME/.npm"                  # npm's package cache
if [ -f "$conf" ]; then
  while read -r kind path _; do
    path=${path/#\~/$HOME}
    case $kind in rw) add_rw "$path" ;; esac
  done < "$conf"
fi

# Hook and plugin config agy reads stays read-only, inside the writable roots too.
mkdir -p "$wt/.agents" "$common/hooks"
for path in "$gemini/hooks.json" "$state/hooks.json"; do
  [ -f "$path" ] || die "$path is missing; run install-agy.sh."
done
for entry in agents plugins rules skills workflows secplugins; do mkdir -p "$state/$entry"; done
while IFS= read -r path; do add_ro "$path"; done <<EOF
$(read_only_paths "$wt" "$common")
EOF

# Credential stores, and sockets of processes that would run a command outside the sandbox.
for path in "$HOME/.claude" "$HOME/.codex" "$HOME"/.codex-* "$HOME/.config/gh" "$HOME/.ssh" "$HOME/.gnupg" \
  "$HOME/.aws" "$HOME/.config/gcloud" "$HOME/.docker" "$HOME/.config/herdr" "$HOME/.config/pairfob" \
  "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" "/tmp/tmux-$(id -u)" /var/run/docker.sock "${HERDR_SOCKET_PATH:-}"; do
  [ -z "$path" ] || add_mask "$path"
done
token_file=""
if [ -f "$conf" ]; then
  while read -r kind path _; do
    path=${path/#\~/$HOME}
    case $kind in
      mask) add_mask "$path" ;;
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
exec python3 -I -c 'import os, sys; os.closerange(3, os.sysconf("SC_OPEN_MAX")); os.execvp(sys.argv[1], sys.argv[1:])' \
  env -i "${env[@]}" bwrap "${args[@]}" --chdir "$wt" -- "$self" --inside "$@"
