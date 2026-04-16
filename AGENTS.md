# local-mutex — Agent Instructions

## What this repo is

A GitHub composite action that wraps a shell command in a local-filesystem mutex on self-hosted runners. Uses `lockf(1)` (BSD/macOS) or `flock(1)` (Linux), whichever is on PATH. See README.md for full context.

## Rules

- `lib/local-mutex.sh` must use `#!/bin/sh` and pass `shellcheck` clean with no warnings.
- No external dependencies beyond `sh`, `lockf` or `flock`, a SHA-256 command (`sha256sum` from GNU coreutils on Linux, `shasum` from Perl on macOS), and standard POSIX utilities.
- The action interface (`action.yml`) takes three inputs: `name`, `run`, and optional `lock-dir`. Adding further inputs is a major version bump because it expands the contract.
- Every change ships with a test in `.github/workflows/ci.yml`. Concurrency tests are non-negotiable — the whole product is "two callers serialize correctly," so any change to the locking path must be exercised by a concurrent-acquire test.
- Release tagging: every release gets an **immutable patch tag** of the
  form `vMAJOR.MINOR.PATCH` (e.g. `v1.0.0`, `v1.0.1`, `v1.1.0`) that, once
  pushed, is never force-moved — this is what downstream callers pin to if
  they need exact reproducibility. In addition, the **floating major tag**
  `vMAJOR` (e.g. `v1`, `v2`) is force-updated on every release in that
  major series so it always points at the latest `v1.x.y` commit. Callers
  that track `@v1` get automatic minor/patch updates inside the same major
  series; callers that track `@v1.0.1` stay pinned forever. Both kinds of
  tags exist in this repo and both are part of the release contract. Use
  `git tag v1.0.1 HEAD` (immutable) and `git tag -f v1 HEAD` followed by
  `git push --force origin v1` (floating) when cutting a release.
- The script uses *only* the OS-native command-wrapping lock primitive. Do not add a mkdir-based fallback or PID-tracking stale recovery — the kernel handles process-death cleanup for both `lockf` and `flock`. If you find yourself wanting one of those, you have a different problem.
- The `flock -o` flag (close FD before exec) is non-optional. Without it, the wrapped command's descendants inherit the lock FD on Linux and the SIGKILL release guarantee silently breaks. macOS `lockf` already closes the lock FD in the forked child before exec (the same effect as `flock -o`), so it doesn't need an equivalent flag — but if you ever change the lockf invocation, verify the SIGKILL test still passes.
- Lock files live under `${lock_dir}/local-mutex-<sha256-of-name>.lock`, where `lock_dir` defaults to `/tmp` when the caller does not set the `lock-dir` input. The lockfile basename is the SHA-256 digest of the raw `name` input (64 hex characters). The raw `name` is echoed verbatim into the `::notice::` annotations so callers see a human-readable identifier in the log, while the filesystem sees a fixed-length collision-resistant basename. Changing the default, the hashing scheme, or the lockfile name pattern desyncs in-flight callers and requires a major version bump.
- Reject any `name` containing control characters (bytes `0x00`–`0x1F` or `0x7F`). The raw `name` flows into `::notice::` output unfiltered; a literal newline would split the annotation into two lines and the runner's log parser could re-interpret the second line as a workflow command. Empty and whitespace-only names are also rejected. Non-ASCII bytes in the `0x80`–`0xFF` range are accepted and hash cleanly.
