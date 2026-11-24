#!/usr/bin/env bash
# Installs the pinned agy release for Anderton workers, its sandbox launcher, a pinned bun and the agy guard, and
# writes the guard's hook registration under the prefix. The operator runs it as root after reviewing it; agents never
# do. It writes nothing in the worker's home: the worker user then runs register-agy.sh, which copies the registration
# into ~/.gemini without following links.
#
# usage: install-agy.sh --user NAME --guard DIR [--home DIR] [--scope-dir DIR] [--bun FILE] [--bwrap FILE]
#                       [--nanoclaw DIR] [--prefix DIR] [--pin FILE] [--tarball FILE]
#   --home       the user's home, default from the passwd database.
#   --guard      plugins/workflow-agents/hooks of a reviewed bootstrap checkout; it is copied, not referenced.
#   --scope-dir  where the guard reads its untracked merge-scope.local.json and response-secrets.local.json, default the
#                root of the --guard checkout. The installed copy has no checkout above it, so the hook names them. It
#                must lie outside every directory an agy worker can write; the launcher checks that again at launch.
#   --bun        the bun to copy in for the guard hook, default /usr/local/bin/bun: 1.3.3 or newer, owned with every
#                parent directory by root (or by the installing user, when not root) and writable by no one else.
#   --bwrap      the bubblewrap the launcher runs, default the one on PATH, owned the same way.
#   --nanoclaw   a NanoClaw install whose data/ and .env the default sandbox.conf hides from workers.
#   --prefix     default /opt. The release, launcher, hook and pin go under PREFIX/agy, the guard under PREFIX/agy-guard.
#   --pin        default agy.pin beside this script.
#   --tarball    an already-downloaded release tarball, checked against the pin like a download.
# Linux only. Leaves AGY_CLI_DISABLE_AUTO_UPDATE to the launcher, and the install root-owned so agy cannot update it.
set -euo pipefail

# What this creates is root's alone, whatever umask it was started with.
umask 022
here=$(cd "$(dirname "$0")" && pwd -P)
prefix=/opt user="" home="" guard="" scope="" bun=/usr/local/bin/bun bwrap="" nanoclaw="" pin="$here/agy.pin" tarball=""
die() {
  echo "install-agy: $*" >&2
  exit 1
}
while [ $# -gt 0 ]; do
  case $1 in
    --user | --home | --guard | --scope-dir | --bun | --bwrap | --nanoclaw | --prefix | --pin | --tarball)
      [ $# -ge 2 ] || die "$1 needs a value."
      case $1 in
        --user) user=$2 ;;
        --home) home=$2 ;;
        --guard) guard=$2 ;;
        --scope-dir) scope=$2 ;;
        --bun) bun=$2 ;;
        --bwrap) bwrap=$2 ;;
        --nanoclaw) nanoclaw=$2 ;;
        --prefix) prefix=$2 ;;
        --pin) pin=$2 ;;
        --tarball) tarball=$2 ;;
      esac
      shift 2
      ;;
    --replace-hooks) die "--replace-hooks moved to register-agy.sh, which the worker user runs." ;;
    *) die "unknown argument $1" ;;
  esac
done
[ "$(uname -s)" = Linux ] || die "Linux only."
[ -n "$user" ] && [ -n "$guard" ] || die "usage: install-agy.sh --user NAME --guard DIR [--home DIR] [--scope-dir DIR] [--bun FILE] [--bwrap FILE] [--nanoclaw DIR] [--prefix DIR] [--pin FILE] [--tarball FILE]"
for file in agy-guard.sh agy-guard.ts agy-supervisor.ts; do
  [ -f "$guard/$file" ] || die "$guard has no $file."
done
# agy cuts a hook off at this timeout, with no deny. The supervisor's deadline must fall after the guard's one-hour
# approval wait and early enough before this timeout to print its own deny.
hook_timeout=3660
watchdog=$(sed -n 's/^export const WATCHDOG_SECONDS = \([0-9][0-9]*\);$/\1/p' "$guard/agy-supervisor.ts" | head -n 1)
[ -n "$watchdog" ] || die "$guard/agy-supervisor.ts sets no WATCHDOG_SECONDS."
[ "$watchdog" -gt 3600 ] && [ "$watchdog" -le $((hook_timeout - 10)) ] ||
  die "the supervisor's deadline, $watchdog seconds, is not between the 3600-second approval wait and $((hook_timeout - 10)) (10 seconds under the hook timeout)."

if [ -n "$nanoclaw" ]; then
  [ -d "$nanoclaw" ] || die "no NanoClaw install at $nanoclaw."
  nanoclaw=$(cd "$nanoclaw" && pwd -P)
fi
[ -n "$home" ] || home=$(getent passwd "$user" | cut -d: -f6)
[ -n "$home" ] && [ -d "$home" ] || die "no home directory for $user."
home=$(cd "$home" && pwd -P)
[ -n "$scope" ] || scope="$guard/../../.."
[ -d "$scope" ] || die "no scope directory $scope."
scope=$(cd "$scope" && pwd -P)
mkdir -p "$prefix"
prefix=$(cd "$prefix" && pwd -P)
# The registration names one command and one argument, split on spaces or run by a shell alike, so the prefix holds none;
# the home and scope paths go into the hook script, quoted.
case $prefix in *[!A-Za-z0-9._/-]*) die "the prefix $prefix may hold only letters, digits, '.', '_', '-' and '/'." ;; esac
for path in "$home" "$scope"; do
  case $path in *"'"* | *$'\n'*) die "$path holds a quote or a newline, which the hook script cannot carry." ;; esac
done
# Directories every agy worker can write. Worktrees and their repositories are known only at launch, where the launcher
# refuses a scope file inside one.
for root in /tmp "$home/.gemini" "$home/.cache" "$home/.npm" "$home/.bun" "$home/.local/share/pnpm"; do
  case $scope/ in "$root"/*) die "the scope directory $scope is inside $root, which agy workers can write." ;; esac
  case $prefix/ in "$root"/*) die "the prefix $prefix is inside $root, which agy workers can write." ;; esac
done

# A trusted executable is one whose file and every parent directory belong to root, or to the installing user when that
# is not root, and that no one else can write: anything else could change between this check and its use. A sticky
# directory (/tmp) passes, since no one else can replace what it holds.
trusted_executable() {
  local path=$1 me dir mode
  me=$(id -u)
  case $path in /*) ;; *) die "$path is not an absolute path." ;; esac
  [ -f "$path" ] && [ -x "$path" ] && [ ! -L "$path" ] || die "$path is not an executable file (a link is not accepted: name its target)."
  dir=$path
  while :; do
    case $(stat -c %u "$dir") in 0 | "$me") ;; *) die "$dir is not owned by root$([ "$me" = 0 ] || echo " or by you"), so $path cannot be trusted." ;; esac
    mode=$(stat -c %a "$dir")
    if [ $((0$mode & 022)) -ne 0 ] && { [ "$dir" = "$path" ] || [ ! -k "$dir" ]; }; then
      die "$dir is writable by others, so $path cannot be trusted."
    fi
    [ "$dir" = / ] && break
    dir=$(dirname "$dir")
  done
}
trusted_executable "$bun"
# The same holds for every directory above the prefix: the hook, the guard and the bun installed under it must stay as
# installed while agy runs, and the launcher checks it again, against the directories agy can write.
dir=$prefix
while :; do
  case $(stat -c %u "$dir") in 0 | "$(id -u)") ;; *) die "$dir is not owned by root$([ "$(id -u)" = 0 ] || echo " or by you"), so what is installed under $prefix could be replaced." ;; esac
  if [ $((0$(stat -c %a "$dir") & 022)) -ne 0 ] && [ ! -k "$dir" ]; then
    die "$dir is writable by others, so what is installed under $prefix could be replaced."
  fi
  [ "$dir" = / ] && break
  dir=$(dirname "$dir")
done
# What an earlier install left under the prefix is read back (sandbox.conf) or kept (a complete guard copy), so all of
# it must be the installer's own too: owned by root (or by you, when not root), writable by no one else, and no link.
for top in "$prefix/agy" "$prefix/agy-guard"; do
  [ -e "$top" ] || [ -L "$top" ] || continue
  # A link is followed by what reads it, and its target is not checked here, so the install holds none.
  bad=$(find "$top" -type l -print -quit) || die "could not check $top."
  [ -z "$bad" ] || die "$bad, under the prefix, is a symbolic link; remove it, then rerun."
  bad=$(find "$top" \( ! -user "$(id -u)" -o -perm /022 \) -print -quit) || die "could not check $top."
  [ -z "$bad" ] || die "$bad, under the prefix, is not owned by $(id -un) or is writable by others; remove it, then rerun."
done
[ -n "$bwrap" ] || bwrap=$(command -v bwrap) || die "bwrap is not installed; pass --bwrap."
bwrap=$(readlink -f "$bwrap")
trusted_executable "$bwrap"

value() {
  sed -n "s/^$1=//p" "$pin" | head -n 1
}
version=$(value version) url=$(value url) sha=$(value sha256)
[ -n "$version" ] && [ -n "$url" ] && [ -n "$sha" ] || die "$pin needs version, url and sha256."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# The bytes checked against the pin are the bytes extracted: a copy nobody else can write.
if [ -n "$tarball" ]; then
  cp "$tarball" "$work/agy.tar.gz" || die "could not read $tarball."
else
  curl -fsSL -o "$work/agy.tar.gz" "$url" || die "could not download $url."
fi
tarball="$work/agy.tar.gz"
[ "$(sha256sum "$tarball" | cut -d' ' -f1)" = "$sha" ] || die "the release does not match the pinned sha256."
mkdir "$work/x"
tar -xzf "$tarball" -C "$work/x"
[ -f "$work/x/antigravity" ] || die "the release holds no antigravity binary."

root="$prefix/agy"
install -d -m 0755 "$root" "$root/$version" "$root/bin" "$root/etc" "$root/libexec" "$root/hookbin"
install -m 0755 "$work/x/antigravity" "$root/$version/antigravity"
install -m 0755 "$here/agy-sandbox.sh" "$root/bin/agy"
install -m 0755 "$here/register-agy.sh" "$root/libexec/register-agy"
# The hook's PATH starts with a directory holding only this copy, so the guard wrapper's "bun" can only be it.
install -m 0755 "$bun" "$work/bun"
case $("$work/bun" --version 2>/dev/null) in
  '' | 0.* | 1.[0-2].* | 1.3.[0-2] | 1.3.[0-2][!0-9]*) die "$bun is older than 1.3.3, which the guard needs." ;;
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "$bun reports a version this installer cannot read." ;;
esac
find "$root/hookbin" -mindepth 1 -maxdepth 1 ! -name bun -exec rm -rf {} +
mv -f "$work/bun" "$root/hookbin/bun"
bun="$root/hookbin/bun"

# The guard is copied first and named by the digest of the copy, so the name always matches what the hook runs.
copy="$work/guard"
install -d -m 0755 "$copy" "$copy/guards"
for file in "$guard"/*.ts "$guard"/agy-guard.sh "$guard"/package.json "$guard"/bun.lock; do
  case $file in *.test.ts) continue ;; esac
  if [ -f "$file" ]; then install -m 0644 "$file" "$copy/${file##*/}"; fi
done
for file in "$guard"/guards/*.ts; do
  if [ -f "$file" ]; then install -m 0644 "$file" "$copy/guards/${file##*/}"; fi
done
digest=$(cd "$copy" && find . -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-16)
dest="$prefix/agy-guard/$digest"
if [ ! -f "$dest/.complete" ]; then
  if [ -f "$copy/package.json" ]; then
    (cd "$copy" && "$bun" install --production --frozen-lockfile --ignore-scripts >/dev/null) || die "could not install the guard's dependencies."
    # bun's install cache, which nothing runs from, links into this installer's temporary directory under /tmp.
    rm -rf "$copy/node_modules/.cache"
  fi
  [ -z "$(find "$copy" -type l -print -quit)" ] || die "the guard's dependencies hold a symbolic link: $(find "$copy" -type l -print -quit)"
  install -d -m 0755 "$prefix/agy-guard"
  rm -rf "$dest"
  cp -a "$copy" "$dest"
  touch "$dest/.complete"
fi

# The hook agy runs. Dev and lab scope only exempt commands from approval, and agy has no approval channel, so its
# guard reads neither: an empty value is the guard's "no file". Merge scope and response secrets only tighten it.
hook="$root/libexec/agy-guard-hook"
q() { printf "'%s'" "$1"; }
{
  echo '#!/bin/bash'
  echo '# Written by install-agy.sh: the agy guard hook, with the environment it needs and nothing of agy'"'"'s.'
  echo "exec /usr/bin/env -i PATH=$(q "$root/hookbin:/usr/bin:/bin") HOME=$(q "$home") \\"
  echo "  BOOTSTRAP_MERGE_SCOPE_FILE=$(q "$scope/merge-scope.local.json") BOOTSTRAP_RESPONSE_SECRETS_FILE=$(q "$scope/response-secrets.local.json") \\"
  echo "  BOOTSTRAP_DEV_SCOPE_FILE= BOOTSTRAP_LAB_SCOPE_FILE= /bin/bash $(q "$dest/agy-guard.sh") \"\$@\""
} > "$work/hook"
install -m 0755 "$work/hook" "$hook"
# agy runs every hook in the registration; the launcher refuses to start unless the worker's copy has exactly these bytes.
jq -nc --arg command "$hook PreToolUse" --argjson timeout "$hook_timeout" \
  '{"agent-anderton-agy-guard": {PreToolUse: [{matcher: "*", hooks: [{type: "command", command: $command, timeout: $timeout}]}]}}' |
  tr -d '\n' > "$work/hooks.json"
install -m 0644 "$work/hooks.json" "$root/etc/hooks.json"

# The default masks go into sandbox.conf, kept with whatever an operator added: a line already there is not repeated.
if [ -f "$root/etc/sandbox.conf" ]; then cp "$root/etc/sandbox.conf" "$work/sandbox.conf"; else
  {
    echo '# Paths agy workers do not see, besides the launcher'"'"'s built-in credential masks. One per line:'
    echo '#   mask <path> (the rest of the line, taken literally), rw <path> <reason>, gh-token-file <path>. A leading'
    echo '#   "~/" is the home. Every entry of the home named .codex* or .claude* is masked by the launcher itself.'
  } > "$work/sandbox.conf"
fi
for line in 'mask ~/.git-credentials' 'mask ~/.netrc' 'mask ~/.config/gh' 'mask ~/.claude' \
  ${nanoclaw:+"mask $nanoclaw/data"} ${nanoclaw:+"mask $nanoclaw/.env"}; do
  grep -qxF -- "$line" "$work/sandbox.conf" || echo "$line" >> "$work/sandbox.conf"
done
install -m 0644 "$work/sandbox.conf" "$root/etc/sandbox.conf"

{
  echo "version=$version"
  echo "binary_sha256=$(sha256sum "$root/$version/antigravity" | cut -d' ' -f1)"
  echo "hooks_sha256=$(sha256sum "$root/etc/hooks.json" | cut -d' ' -f1)"
  echo "hook_sha256=$(sha256sum "$hook" | cut -d' ' -f1)"
  echo "bun_sha256=$(sha256sum "$bun" | cut -d' ' -f1)"
  echo "bwrap=$bwrap"
  echo "guard=$dest"
  echo "home=$home"
  echo "scope_dir=$scope"
} > "$work/pin"
install -m 0644 "$work/pin" "$root/etc/pin"
echo "Installed agy $version at $root, the guard at $dest, and its hook registration at $root/etc/hooks.json."
echo "Next, as $user: $root/libexec/register-agy (copies the registration into ~/.gemini), then log in once, unsandboxed:"
echo "  env -u DBUS_SESSION_BUS_ADDRESS AGY_CLI_DISABLE_AUTO_UPDATE=true $root/$version/antigravity acp --login"
