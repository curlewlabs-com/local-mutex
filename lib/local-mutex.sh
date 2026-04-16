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

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    printf '::error::local-mutex: expected 2 or 3 arguments (NAME COMMAND [LOCK_DIR]), got %d\n' "$#" >&2
    exit 2
fi

name="$1"
cmd="$2"
# Third arg is the lock directory. Empty or unset means "use the default
# /tmp" — this matches the action.yml surface where `lock-dir` is an
# optional input with an empty-string default. Callers on self-hosted
# runners with a non-shared /tmp (containerized runners, chrooted
# sandboxes, or anywhere /tmp doesn't see across sibling runners) can
# point this at a real shared filesystem path.
lock_dir="${3:-/tmp}"

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

# Reject names containing control characters (byte 0x00–0x1F or 0x7F).
# The raw name is echoed verbatim into ::notice:: annotations below; a
# newline would split the annotation into two lines and the second line
# could be re-interpreted as a workflow command by the runner's log
# parser. Tabs and other control chars are rejected for the same display
# hygiene reason — names are identifiers, identifiers don't contain
# control characters. Non-ASCII bytes in the 0x80–0xFF range are not
# covered by this check; they are safe because SHA-256 consumes bytes
# unchanged and printf %s passes them through without reinterpretation.
case "$name" in
    *[[:cntrl:]]*)
        printf '::error::local-mutex: name cannot contain control characters (newline, tab, etc.)\n' >&2
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

# Hash the raw name with SHA-256 to derive the lockfile basename. This
# replaces the previous tr-based character-class sanitization plus
# 200-char truncation and removes every class of name→filename hazard
# at once:
#   - Path traversal ('../../etc/passwd') cannot escape: the basename
#     is always exactly 64 hex characters plus the 'local-mutex-' prefix
#     and '.lock' suffix — total 81 bytes, well under NAME_MAX on every
#     supported filesystem.
#   - Arbitrary byte sequences including invalid UTF-8 hash cleanly.
#     Both sha256sum (GNU coreutils) and shasum (Perl) are byte-oriented
#     and locale-independent, unlike tr under UTF-8 locales.
#   - Names longer than 200 characters are no longer truncated. Two
#     callers whose names share a 200-char prefix but differ later
#     previously collapsed onto the same lock; they now serialize on
#     distinct locks as expected.
#   - Names differing only in non-allowed characters (e.g. 'foo$bar'
#     vs 'foo@bar' vs 'foo bar') previously all collapsed to the same
#     underscored basename; they now hash to distinct basenames.
# The raw $name is preserved verbatim for the ::notice:: annotations
# below so callers still see a human-readable identifier in the step
# log. NUL bytes cannot reach here because POSIX argv strings terminate
# at the first NUL under execve(2), so $name is already NUL-free by the
# time the script runs.
if command -v sha256sum >/dev/null 2>&1; then
    name_hash=$(printf '%s' "$name" | sha256sum)
elif command -v shasum >/dev/null 2>&1; then
    name_hash=$(printf '%s' "$name" | shasum -a 256)
else
    printf '::error::local-mutex: neither sha256sum(1) nor shasum(1) found on PATH. Install coreutils (Linux) or use a system that ships Perl (macOS, *BSD).\n' >&2
    exit 127
fi
# Both sha256sum(1) and shasum(1) emit "<hex>  <filename>" (stdin → "-").
# Strip everything from the first space onward with POSIX parameter
# expansion so we don't have to depend on cut(1) being on PATH — the
# "missing lock binary" test exercises a locked-down PATH that only
# contains sha256sum/shasum, and any extra dependency here would break it.
name_hash=${name_hash%% *}

# Validate lock-dir before building the lockfile path. The default /tmp
# is also validated so the error shape is consistent whether the caller
# set lock-dir explicitly or relied on the default. An absolute-path
# check keeps the lockfile location deterministic regardless of where
# the action runs from; the directory and writability checks catch the
# common container-runner misconfiguration of "I set lock-dir to a path
# that doesn't exist in my container" with a clear error instead of a
# cryptic open(2) EACCES downstream.
case "$lock_dir" in
    /*) ;;
    *)
        printf '::error::local-mutex: lock-dir must be an absolute path, got: %s\n' "$lock_dir" >&2
        exit 2
        ;;
esac

if [ ! -d "$lock_dir" ]; then
    printf '::error::local-mutex: lock-dir does not exist or is not a directory: %s\n' "$lock_dir" >&2
    exit 2
fi

if [ ! -w "$lock_dir" ]; then
    printf '::error::local-mutex: lock-dir is not writable: %s\n' "$lock_dir" >&2
    exit 2
fi

lockfile="${lock_dir}/local-mutex-${name_hash}.lock"

# Emit a diagnostic notice before and after the lock acquire so callers
# debugging a hung step can see what the step is blocked on and when it
# cleared. The release notice lives in an EXIT trap inside the inner
# shell because `exec lockf`/`exec flock` replaces this script's process
# and leaves no post-hook here. If the caller's `run` installs its own
# EXIT trap, ours is replaced and the release notice drops; caller's
# trap still runs.
#
# $name is emitted verbatim (not $name_hash) so callers see the human
# identifier they supplied rather than a 64-hex digest. Control chars
# in $name are already rejected above so the notice is always a single
# safe line of output.
LMX_NAME="$name"
export LMX_NAME
printf '::notice::local-mutex: waiting for lock %s at %s\n' "$name" "$(date -u +%FT%TZ)" >&2

# shellcheck disable=SC2016
# Single quotes are intentional: $-expansion must defer to trap-fire time.
trap_line='trap '\''printf "::notice::local-mutex: released %s at %s\n" "$LMX_NAME" "$(date -u +%FT%TZ)" >&2'\'' EXIT'

inner_script="$trap_line
$cmd"

if command -v lockf >/dev/null 2>&1; then
    # -k keeps the lock file across acquisitions. Without -k, lockf
    # `unlink(2)`s the lock file on release, which lets a fresh acquirer
    # `open(O_CREAT)` a brand-new inode under the same name while a
    # previous waiter is still blocked on the now-anonymous original
    # inode. Both end up holding locks on different inodes — the mutex
    # silently breaks. -k skips the unlink so all callers always lock
    # the same inode.
    exec lockf -k "$lockfile" sh -c "$inner_script"
elif command -v flock >/dev/null 2>&1; then
    # flock holds the lock on a file descriptor and never `unlink()`s the
    # lock file, so the unlink-then-open inode race that lockf needs `-k`
    # to avoid doesn't exist here. -x is exclusive (the default but
    # explicit for clarity). -o (--close) closes the lock FD before exec
    # so the wrapped command's descendants don't inherit it — without
    # this, killing the flock parent leaves orphan processes holding the
    # lock and the SIGKILL release guarantee silently breaks.
    exec flock -o -x "$lockfile" sh -c "$inner_script"
else
    printf '::error::local-mutex: neither lockf(1) nor flock(1) found on PATH. Install util-linux (Linux) or use a system that ships lockf (macOS, *BSD).\n' >&2
    exit 127
fi
