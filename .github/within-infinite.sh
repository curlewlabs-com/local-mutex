#!/bin/sh
# The one deadline for every wait in CI's tests.
#
#   within-infinite.sh <what is being waited for> <shell command>
#
# Runs the command with `sh -c` and exits with its status, or fails if it has
# not finished within INFINITE_S seconds. A test that waits for a lock, for a
# killed holder's lock to come free, or for a line another process logs has
# no deadline of its own: how long the kernel takes to tear down a killed
# process, or a hosted runner takes to schedule one, is not something this
# tool promises, and a short deadline turns a slow runner into a failure.
# INFINITE_S is long enough that only a hang reaches it, so a test proves
# "this finishes" and never "this finishes quickly".
#
# A test whose failure mode is "blocks until some process ends" makes that
# process outlive INFINITE_S - a holder that runs until the test releases it -
# so the hang reaches the deadline instead of quietly ending first.
#
# On a timeout the command's whole process tree is killed, not just its
# `sh -c`: a holder blocked forever keeps the step's output open, and a step
# whose output never closes hangs until the job's own limit instead of
# failing here.
set -eu

INFINITE_S=60
TICK_S=0.1
TICKS_PER_S=10

what=$1
cmd=$2

# Stops a process before walking its children, so a loop cannot start a new
# child mid-walk, then kills the children before the parent. pgrep -P is on
# both the Linux and the macOS runners.
kill_tree() {
    kill -STOP "$1" 2>/dev/null || true
    for child in $(pgrep -P "$1" 2>/dev/null); do
        kill_tree "$child"
    done
    kill -KILL "$1" 2>/dev/null || true
}

done_file=$(mktemp)
rm -f "$done_file"

(
    sh -c "$cmd" && rc=0 || rc=$?
    echo "$rc" >"$done_file.tmp"
    mv "$done_file.tmp" "$done_file"
) &
runner=$!

ticks=0
until [ -e "$done_file" ]; do
    if [ "$ticks" -ge $((INFINITE_S * TICKS_PER_S)) ]; then
        kill_tree "$runner"
        echo "FAIL: $what did not finish within ${INFINITE_S}s" >&2
        exit 1
    fi
    sleep "$TICK_S"
    ticks=$((ticks + 1))
done

wait "$runner" || true
rc=$(cat "$done_file")
rm -f "$done_file"
exit "$rc"
