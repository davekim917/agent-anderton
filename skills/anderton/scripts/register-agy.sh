#!/usr/bin/env bash
# Copies the agy guard's hook registration, which install-agy.sh wrote under the prefix as root, into this user's
# ~/.gemini/config/hooks.json, and creates the two other hook files agy reads as empty. Run it as the worker user, never
# as root: it refuses a planted link anywhere it writes, and creates files only without following links.
#
# usage: register-agy.sh [--prefix DIR] [--replace-hooks]
#   --prefix         where install-agy.sh installed, default /opt.
#   --replace-hooks  replace a ~/.gemini/config/hooks.json that holds other hooks (review it first).
set -euo pipefail

prefix=/opt replace=0
die() {
  echo "register-agy: $*" >&2
  exit 1
}
while [ $# -gt 0 ]; do
  case $1 in
    --prefix) [ $# -ge 2 ] || die "--prefix needs a value."; prefix=$2; shift 2 ;;
    --replace-hooks) replace=1; shift ;;
    *) die "unknown argument $1" ;;
  esac
done
[ "$(id -u)" != 0 ] || die "run it as the worker user, not root: root must not write inside a user's home."
root="$prefix/agy"
[ -f "$root/etc/pin" ] && [ -f "$root/etc/hooks.json" ] || die "no install under $root; run install-agy.sh first."
home=$(sed -n 's/^home=//p' "$root/etc/pin" | head -n 1)
[ -n "${HOME:-}" ] && [ "$(cd "$HOME" && pwd -P)" = "$home" ] || die "the install is for the home $home, not ${HOME:-(unset)}."
[ "$(sha256sum "$root/etc/hooks.json" | cut -d' ' -f1)" = "$(sed -n 's/^hooks_sha256=//p' "$root/etc/pin" | head -n 1)" ] ||
  die "$root/etc/hooks.json does not match its pin; rerun install-agy.sh."

# Each directory is opened without following a link, then each file is created or replaced relative to it: a link the
# worker planted at any of these names is refused, never written through.
python3 -I - "$home" "$root/etc/hooks.json" "$replace" <<'PY'
import os, stat, sys

home, source, replace = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
registration = open(source, "rb").read()
DIRECTORY = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW

def die(message):
    sys.stderr.write("register-agy: " + message + "\n")
    sys.exit(1)

def subdirectory(parent, name, shown):
    try:
        os.mkdir(name, 0o755, dir_fd=parent)
    except FileExistsError:
        pass
    try:
        return os.open(name, DIRECTORY, dir_fd=parent)
    except OSError:
        die(shown + " is not a directory (a link is refused).")

def existing(parent, name, shown):
    try:
        info = os.stat(name, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode):
        die(shown + " is not a regular file (a link is refused).")
    if info.st_nlink != 1:
        die(shown + " has another hard link, which would keep it writable elsewhere.")
    return info

def write_new(parent, name, data):
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644, dir_fd=parent)
    with os.fdopen(fd, "wb") as out:
        out.write(data)
        out.flush()
        os.fsync(out.fileno())

top = os.open(home, DIRECTORY)
gemini = subdirectory(top, ".gemini", home + "/.gemini")
config = subdirectory(gemini, "config", home + "/.gemini/config")
state = subdirectory(gemini, "antigravity-cli", home + "/.gemini/antigravity-cli")

shown = home + "/.gemini/config/hooks.json"
info = existing(config, "hooks.json", shown)
if info is not None:
    fd = os.open("hooks.json", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=config)
    with os.fdopen(fd, "rb") as current:
        same = current.read() == registration
    if not same and not replace:
        die(shown + " already holds other hooks; review it, then rerun with --replace-hooks.")
if info is None or not same:
    temporary = ".hooks.json.%d" % os.getpid()
    write_new(config, temporary, registration)
    os.rename(temporary, "hooks.json", src_dir_fd=config, dst_dir_fd=config)

for parent, shown in ((gemini, home + "/.gemini/hooks.json"), (state, home + "/.gemini/antigravity-cli/hooks.json")):
    if existing(parent, "hooks.json", shown) is None:
        write_new(parent, "hooks.json", b"{}")
PY
echo "Registered the agy guard hook in $home/.gemini/config/hooks.json."
