#!/bin/sh
# The setup action's one step: export the lock script's absolute path, and
# the lock directory when the caller set one, for every later step of the job.
# INPUT_LOCK_DIR arrives in the environment from setup/action.yml.
set -eu

# GITHUB_ACTION_PATH is this sub-action's own directory, so the
# script sits one level up. Resolved through cd/pwd rather than left
# as a `..` path because the value is consumed by other processes in
# other working directories, where a relative segment names a
# different file or none.
lib_dir=$(CDPATH='' cd -- "$GITHUB_ACTION_PATH/.." && pwd)
cli="$lib_dir/lib/local-mutex.sh"

if [ ! -f "$cli" ] || [ ! -r "$cli" ]; then
    printf '::error::local-mutex setup: lock script not found at %s\n' "$cli" >&2
    exit 1
fi

# A newline in either value would end the `name=value` line and let
# the rest define a second variable of the writer's choosing. Neither
# value can hold one on any runner layout we know of, which is exactly
# why an unchecked write would never fail visibly if that stopped
# being true. Same reason the lock script rejects control characters
# in `name`.
nl=$(printf '\nx')
nl=${nl%x}
case "$cli$INPUT_LOCK_DIR" in
*"$nl"*)
    printf '::error::local-mutex setup: refusing to export a value containing a newline\n' >&2
    exit 1
    ;;
esac

printf 'LOCAL_MUTEX_CLI=%s\n' "$cli" >> "$GITHUB_ENV"
printf 'cli=%s\n' "$cli" >> "$GITHUB_OUTPUT"

# Written only when the caller asked for one. An empty value would be
# read as unset by the CLI's own `:-` default anyway, but leaving the
# variable absent keeps "nobody set a lock-dir" distinguishable from
# "somebody set an empty one" for anything that reads the environment.
if [ -n "$INPUT_LOCK_DIR" ]; then
    printf 'LOCAL_MUTEX_LOCK_DIR=%s\n' "$INPUT_LOCK_DIR" >> "$GITHUB_ENV"
fi

printf '::notice::local-mutex: CLI available at %s\n' "$cli" >&2
