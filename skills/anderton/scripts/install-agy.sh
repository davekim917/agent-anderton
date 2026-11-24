#!/usr/bin/env bash
# Installs the pinned agy release for Anderton workers, its sandbox launcher and the agy guard, and registers the guard
# in the worker user's ~/.gemini/config/hooks.json. The operator runs it as root after reviewing it; agents never do.
#
# usage: install-agy.sh --user NAME --guard DIR [--home DIR] [--prefix DIR] [--pin FILE] [--tarball FILE] [--replace-hooks]
#   --home     the user's home, default from the passwd database.
#   --guard    plugins/workflow-agents/hooks of a reviewed bootstrap checkout; it is copied, not referenced.
#   --prefix   default /opt. The release, launcher and pin go under PREFIX/agy, the guard under PREFIX/agy-guard.
#   --pin      default agy.pin beside this script.
#   --tarball  an already-downloaded release tarball, checked against the pin like a download.
# Linux only. Leaves AGY_CLI_DISABLE_AUTO_UPDATE to the launcher, and the install root-owned so agy cannot update it.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
prefix=/opt user="" home="" guard="" pin="$here/agy.pin" tarball="" replace=""
die() {
  echo "install-agy: $*" >&2
  exit 1
}
while [ $# -gt 0 ]; do
  case $1 in
    --user | --home | --guard | --prefix | --pin | --tarball)
      [ $# -ge 2 ] || die "$1 needs a value."
      case $1 in
        --user) user=$2 ;;
        --home) home=$2 ;;
        --guard) guard=$2 ;;
        --prefix) prefix=$2 ;;
        --pin) pin=$2 ;;
        --tarball) tarball=$2 ;;
      esac
      shift 2
      ;;
    --replace-hooks) replace=1; shift ;;
    *) die "unknown argument $1" ;;
  esac
done
[ "$(uname -s)" = Linux ] || die "Linux only."
[ -n "$user" ] && [ -n "$guard" ] || die "usage: install-agy.sh --user NAME --guard DIR [--home DIR] [--prefix DIR] [--pin FILE] [--tarball FILE] [--replace-hooks]"
[ -f "$guard/agy-guard.sh" ] && [ -f "$guard/agy-guard.ts" ] || die "$guard has no agy-guard.sh and agy-guard.ts."
[ -n "$home" ] || home=$(getent passwd "$user" | cut -d: -f6)
[ -n "$home" ] && [ -d "$home" ] || die "no home directory for $user."
value() {
  sed -n "s/^$1=//p" "$pin" | head -n 1
}
version=$(value version) url=$(value url) sha=$(value sha256)
[ -n "$version" ] && [ -n "$url" ] && [ -n "$sha" ] || die "$pin needs version, url and sha256."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [ -z "$tarball" ]; then
  tarball="$work/agy.tar.gz"
  curl -fsSL -o "$tarball" "$url" || die "could not download $url."
fi
[ "$(sha256sum "$tarball" | cut -d' ' -f1)" = "$sha" ] || die "$tarball does not match the pinned sha256."
mkdir "$work/x"
tar -xzf "$tarball" -C "$work/x"
[ -f "$work/x/antigravity" ] || die "the release holds no antigravity binary."

root="$prefix/agy"
install -d -m 0755 "$root" "$root/$version" "$root/bin" "$root/etc"
install -m 0755 "$work/x/antigravity" "$root/$version/antigravity"
install -m 0755 "$here/agy-sandbox.sh" "$root/bin/agy"

# The guard, copied under its content digest so a later checkout cannot change what the hook runs.
digest=$(cd "$guard" && find . -type f \( -name '*.ts' -o -name '*.sh' -o -name 'package.json' -o -name 'bun.lock' \) \
  -not -path './node_modules/*' -not -name '*.test.ts' | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-16)
dest="$prefix/agy-guard/$digest"
if [ ! -d "$dest" ]; then
  install -d -m 0755 "$dest" "$dest/guards"
  for file in agy-guard.sh agy-guard.ts guard-policy.ts package.json bun.lock; do
    if [ -f "$guard/$file" ]; then install -m 0644 "$guard/$file" "$dest/$file"; fi
  done
  for file in "$guard"/guards/*.ts; do
    if [ -f "$file" ]; then install -m 0644 "$file" "$dest/guards/${file##*/}"; fi
  done
  if [ -f "$dest/package.json" ]; then
    (cd "$dest" && bun install --production --frozen-lockfile --ignore-scripts >/dev/null) || die "could not install the guard's dependencies."
  fi
fi

# agy runs every hook in this file; the launcher refuses to start unless it still has exactly these bytes.
hooks="$home/.gemini/config/hooks.json"
registration=$(printf '{"agent-anderton-agy-guard":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"/usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=%s /bin/bash %s/agy-guard.sh PreToolUse","timeout":3660}]}]}}' "$home" "$dest")
if [ -f "$hooks" ] && [ "$(cat "$hooks")" != "$registration" ] && [ -z "$replace" ]; then
  die "$hooks already holds other hooks; review it, then rerun with --replace-hooks."
fi
install -d -o "$user" -m 0755 "$home/.gemini" "$home/.gemini/config" "$home/.gemini/antigravity-cli"
printf '%s' "$registration" > "$hooks"
chown "$user" "$hooks"
for empty in "$home/.gemini/hooks.json" "$home/.gemini/antigravity-cli/hooks.json"; do
  if [ ! -f "$empty" ]; then printf '{}' > "$empty"; chown "$user" "$empty"; fi
done

{
  echo "version=$version"
  echo "binary_sha256=$(sha256sum "$root/$version/antigravity" | cut -d' ' -f1)"
  echo "hooks_sha256=$(sha256sum "$hooks" | cut -d' ' -f1)"
  echo "guard=$dest"
} > "$root/etc/pin"
[ -f "$root/etc/sandbox.conf" ] || : > "$root/etc/sandbox.conf"
echo "Installed agy $version at $root, the guard at $dest, and its registration in $hooks."
echo "Next: log in once, unsandboxed, as $user: env -u DBUS_SESSION_BUS_ADDRESS AGY_CLI_DISABLE_AUTO_UPDATE=true $root/$version/antigravity acp --login"
