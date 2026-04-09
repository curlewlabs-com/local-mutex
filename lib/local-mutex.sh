#!/bin/sh
# Wrap a command in a local-filesystem mutex. Used to serialize a shared
# resource across multiple GitHub Actions runners on the same physical
# machine — for example a tool installation in ~/.local/bin/, a cache
# directory under /tmp, or any other resource that cannot tolerate
# concurrent access.
#
# Strategy: probe for an OS-native command-wrapping lock primitive in
# preference order (lockf first, then flock) and exec the chosen one with
# the user's command. The lock is held by this script's process (the lockf
# or flock parent). When that process exits — normally, on SIGKILL, OOM
# kill, or machine reboot — the kernel releases the lock immediately.
# Orphaned descendants of the wrapped command continue to exist as
# reparented processes but no longer hold the lock; that is intentional
# and matches normal Unix process semantics.
#
# Critical flag: `flock -o` is required so the flock parent closes the
# lock FD before exec. Without it, the wrapped command's descendants
# inherit the FD and the lock isn't released until they all exit, which
# defeats the SIGKILL guarantee. macOS lockf already closes the lock FD
# in the forked child before exec (the same way `flock -o` does), so it
# doesn't need an equivalent flag.
#
# Why probe instead of branching on `uname`?
#   - Same-system flexibility: a macOS user with `flock` from Homebrew, or a
#     Linux user with `lockf` from a non-default package, both work without
#     a uname allowlist.
#   - Smaller code: no OS table to maintain, no edge cases for FreeBSD vs
#     OpenBSD vs Darwin.
#   - The probe IS the OS detection — if `lockf` is on PATH, it works; if
#     `flock` is on PATH, it works; if neither is, we fail fast with a
#     clear message.

set -eu

if [ $# -ne 2 ]; then
    printf '::error::local-mutex: expected exactly 2 arguments (NAME COMMAND), got %d\n' "$#" >&2
    exit 2
fi

name="$1"
cmd="$2"

# Reject empty/whitespace-only inputs early. Both produce useless lock files
# and silent no-ops downstream, which is the worst possible failure mode for
# a mutex (caller thinks they ran something under a lock; in reality nothing
# was protected and nothing happened).
#
# Whitespace check uses a POSIX shell case pattern with [:space:] character
# class instead of `tr -d`. This keeps the validation independent of external
# utilities so the script behaves correctly even in unusual PATHs.
if [ -z "$name" ]; then
    printf '::error::local-mutex: name cannot be empty\n' >&2
    exit 2
fi

case "$name" in
    *[![:space:]]*) ;;
    *)
        printf '::error::local-mutex: name cannot be whitespace-only\n' >&2
        exit 2
        ;;
esac

if [ -z "$cmd" ]; then
    printf '::error::local-mutex: run command cannot be empty\n' >&2
    exit 2
fi

case "$cmd" in
    *[![:space:]]*) ;;
    *)
        printf '::error::local-mutex: run command cannot be whitespace-only\n' >&2
        exit 2
        ;;
esac

# Probe for tr(1) up-front so a missing-tr failure produces a clear
# ::error:: annotation in the GitHub Actions log instead of the shell's
# default "tr: command not found" with exit 127 and no annotation.
command -v tr >/dev/null 2>&1 || {
    printf '::error::local-mutex: tr(1) not found on PATH\n' >&2
    exit 127
}

# Sanitize name to a safe filename component. Anything outside the
# [a-zA-Z0-9._-] character class becomes an underscore. This blocks path
# traversal (`../etc/passwd` becomes `.._etc_passwd` — dots are preserved
# because they're in the allowed class, but slashes collapse to underscores
# so the result is a flat basename) and maps characters that are awkward
# in a filename (whitespace, shell metacharacters like $, `, ;, colons,
# etc.) to underscores so the basename is safe to use as a plain filename
# component. This is filename hygiene, not shell-injection defense: the
# sanitized result is only used to build $lockfile, which is then passed
# as a double-quoted argv argument to `exec lockf`/`exec flock`, never
# interpolated into an eval or sh -c string. NUL bytes cannot reach this
# point because POSIX argv strings terminate at the first NUL under
# execve(2), so $name is already NUL-free by the time the script runs.
safe_name=$(printf '%s' "$name" | tr -c 'a-zA-Z0-9._-' '_')

# Cap the lock file basename at 200 characters so the full path stays well
# under any filesystem's NAME_MAX (typically 255). Truncating long names
# instead of rejecting them keeps the action friendly to consumers that
# generate long descriptive names from version strings or hash digests.
# Names that share the first 200 characters after sanitization will collide
# and share the same lock — callers with long descriptive names should keep
# the distinguishing portion within the first 200 characters.
# Keep this length in sync with the documented limit in action.yml and README.md.
# %.200s truncates to 200 BYTES; safe here because the prior sanitizer maps
# every non-ASCII byte to '_', so the input to truncation is always
# ASCII-only and bytes == chars.
safe_name=$(printf '%.200s' "$safe_name")

lockfile="/tmp/local-mutex-${safe_name}.lock"

if command -v lockf >/dev/null 2>&1; then
    # -k keeps the lock file across acquisitions. Without -k, lockf
    # `unlink(2)`s the lock file on release, which lets a fresh acquirer
    # `open(O_CREAT)` a brand-new inode under the same name while a
    # previous waiter is still blocked on the now-anonymous original
    # inode. Both end up holding locks on different inodes — the mutex
    # silently breaks. -k skips the unlink so all callers always lock
    # the same inode.
    exec lockf -k "$lockfile" sh -c "$cmd"
elif command -v flock >/dev/null 2>&1; then
    # flock holds the lock on a file descriptor and never `unlink()`s the
    # lock file, so the unlink-then-open inode race that lockf needs `-k`
    # to avoid doesn't exist here. -x is exclusive (the default but
    # explicit for clarity). -o (--close) closes the lock FD before exec
    # so the wrapped command's descendants don't inherit it — without
    # this, killing the flock parent leaves orphan processes holding the
    # lock and the SIGKILL release guarantee silently breaks.
    exec flock -o -x "$lockfile" sh -c "$cmd"
else
    printf '::error::local-mutex: neither lockf(1) nor flock(1) found on PATH. Install util-linux (Linux) or use a system that ships lockf (macOS, *BSD).\n' >&2
    exit 127
fi
