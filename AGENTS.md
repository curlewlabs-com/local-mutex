# local-mutex — Agent Instructions

## What this repo is

A GitHub composite action that wraps a shell command in a local-filesystem mutex on self-hosted runners. Uses `lockf(1)` (BSD/macOS) or `flock(1)` (Linux), whichever is on PATH. See README.md for full context.

## Rules

- `lib/local-mutex.sh` must use `#!/bin/sh` and pass `shellcheck` clean with no warnings.
- No external dependencies beyond `sh`, `lockf` or `flock`, and standard POSIX utilities.
- The action interface (`action.yml`) takes exactly two inputs: `name` and `run`. Adding inputs is a major version bump because it expands the contract.
- Every change ships with a test in `.github/workflows/ci.yml`. Concurrency tests are non-negotiable — the whole product is "two callers serialize correctly," so any change to the locking path must be exercised by a concurrent-acquire test.
- Tag releases as `v1`, `v2`, etc. (major only). Use floating major tags.
- The script uses *only* the OS-native command-wrapping lock primitive. Do not add a mkdir-based fallback or PID-tracking stale recovery — the kernel handles process-death cleanup for both `lockf` and `flock`. If you find yourself wanting one of those, you have a different problem.
- The `flock -o` flag (close FD before exec) is non-optional. Without it, the wrapped command's descendants inherit the lock FD on Linux and the SIGKILL release guarantee silently breaks. macOS `lockf` already closes the lock FD in the forked child before exec (the same effect as `flock -o`), so it doesn't need an equivalent flag — but if you ever change the lockf invocation, verify the SIGKILL test still passes.
- Lock files live under `/tmp/local-mutex-<sanitized-name>.lock`. Changing this path is a behavior change that desyncs in-flight callers and requires a major version bump.
