#!/usr/bin/env bash
# Copies the agy guard's hook registration, which install-agy.sh wrote under the prefix as root, into this user's
# ~/.gemini/config/hooks.json, and creates the two other hook files agy reads as empty. Run it as the worker user, never
# as root, and only after the owner has logged in to agy once: agy's first start migrates its configuration, moving the
# legacy ~/.gemini/antigravity-cli/hooks.json over ~/.gemini/config/hooks.json, which would replace a registration
# written before it. It refuses a planted link anywhere it writes, and creates files only without following links; the
# one link it replaces is the one that migration leaves at antigravity-cli/hooks.json, pointing at config/hooks.json.
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

def subdirectory(parent, name, shown, create=True):
    if create:
        try:
            os.mkdir(name, 0o755, dir_fd=parent)
        except FileExistsError:
            pass
    try:
        return os.open(name, DIRECTORY, dir_fd=parent)
    except FileNotFoundError:
        if create:
            raise
        return None
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

def replace_with(parent, data):
    # rename replaces the name itself, a link included, and never writes through it.
    temporary = ".hooks.json.%d" % os.getpid()
    write_new(parent, temporary, data)
    os.rename(temporary, "hooks.json", src_dir_fd=parent, dst_dir_fd=parent)

top = os.open(home, DIRECTORY)
gemini = subdirectory(top, ".gemini", home + "/.gemini", create=False)
config = subdirectory(gemini, "config", home + "/.gemini/config", create=False) if gemini is not None else None
try:
    migrated = config is not None and stat.S_ISREG(os.stat(".migrated", dir_fd=config, follow_symlinks=False).st_mode)
except FileNotFoundError:
    migrated = False
if not migrated:
    die("agy has not migrated its configuration yet (no " + home + "/.gemini/config/.migrated), and its first start would"
        " replace a registration written now: log in once, unsandboxed, as install-agy.sh printed, then rerun.")
state = subdirectory(gemini, "antigravity-cli", home + "/.gemini/antigravity-cli")

# agy's migration leaves a link at antigravity-cli/hooks.json to config/hooks.json, which would make the guard
# registration a second hook file there; any other link could point where someone else writes.
legacy_shown = home + "/.gemini/antigravity-cli/hooks.json"
legacy_link = False
try:
    legacy = os.stat("hooks.json", dir_fd=state, follow_symlinks=False)
except FileNotFoundError:
    legacy = None
if legacy is not None and stat.S_ISLNK(legacy.st_mode):
    target = os.readlink("hooks.json", dir_fd=state)
    if os.path.normpath(os.path.join(home + "/.gemini/antigravity-cli", target)) != home + "/.gemini/config/hooks.json":
        die(legacy_shown + " is a link to " + target + ", not agy's migration link to " + home
            + "/.gemini/config/hooks.json; review it and remove it, then rerun.")
    legacy_link = True
else:
    existing(state, "hooks.json", legacy_shown)
existing(gemini, "hooks.json", home + "/.gemini/hooks.json")

shown = home + "/.gemini/config/hooks.json"
info = existing(config, "hooks.json", shown)
if info is not None:
    fd = os.open("hooks.json", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=config)
    with os.fdopen(fd, "rb") as current:
        held = current.read()
    same = held == registration
    # Empty, as agy's migration leaves it after moving the legacy {} here, it holds no hooks to review.
    if not same and not replace and b"".join(held.split()) not in (b"", b"{}"):
        die(shown + " already holds other hooks; review it, then rerun with --replace-hooks.")
if info is None or not same:
    replace_with(config, registration)

if existing(gemini, "hooks.json", home + "/.gemini/hooks.json") is None:
    write_new(gemini, "hooks.json", b"{}")
if legacy_link:
    replace_with(state, b"{}")
elif existing(state, "hooks.json", legacy_shown) is None:
    write_new(state, "hooks.json", b"{}")
PY
echo "Registered the agy guard hook in $home/.gemini/config/hooks.json."
