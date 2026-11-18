#!/bin/sh
# The action's one step: run the caller's command under the named lock, with
# its GITHUB_OUTPUT writes captured for the caller to propagate. Inputs arrive
# in the environment from action.yml, so the shell quotes them.
set -eu

# Redirect the inner command's GITHUB_OUTPUT writes to a
# separate file so they can be propagated by the caller.
inner_output="${RUNNER_TEMP:-/tmp}/local-mutex-output-$$"
: > "$inner_output"
outer_output="$GITHUB_OUTPUT"
GITHUB_OUTPUT="$inner_output"
export GITHUB_OUTPUT

# Always pass lock-dir as the 3rd positional arg. The script
# treats empty string the same as "unset" - both fall back to
# the /tmp default - so this single shape works for callers who
# set lock-dir and callers who don't.
rc=0
sh "$GITHUB_ACTION_PATH/lib/local-mutex.sh" "$INPUT_NAME" "$INPUT_RUN" "$INPUT_LOCK_DIR" || rc=$?

# Restore GITHUB_OUTPUT and copy inner writes to both the
# step's own outputs (for internal use) and the original
# output stream.
GITHUB_OUTPUT="$outer_output"
export GITHUB_OUTPUT
cat "$inner_output" >> "$GITHUB_OUTPUT"
printf 'output-file=%s\n' "$inner_output" >> "$GITHUB_OUTPUT"

exit "$rc"
