# local-mutex

Multiple self-hosted GitHub Actions runners on the same machine share `~/.cocoapods`, `~/.local/bin`, `/tmp`, and every other singleton OS resource. When two runners hit `pod install --repo-update`, `claude update`, `brew upgrade`, or any shared-state operation at the same time, they corrupt each other silently.

`local-mutex` wraps any shell command in a kernel-level file lock ([`lockf(1)`](https://man.freebsd.org/cgi/man.cgi?lockf(1)) on macOS/BSD, [`flock(1)`](https://man7.org/linux/man-pages/man1/flock.1.html) on Linux, whichever is on `PATH`). The lock is acquired before your command runs, held for the duration, and released automatically when it exits — including on `SIGKILL`, OOM kill, or machine reboot. No external services, no stale-lock recovery, no PID tracking.

## Why

Self-hosted runners on the same machine sharing the same OS user share `/tmp`, `~/.local/`, and every other singleton OS resource. The moment two of them try to update the same tool at once, or rebuild the same cache entry, they race each other.

GitHub Actions' built-in `concurrency:` mechanism doesn't help — it serializes whole jobs (or whole workflows) at the GitHub API level, which is far too coarse. If you have multiple runners and want them all running independent jobs in parallel except for the one moment they need to update a shared binary, `concurrency:` would force you down to one runner total.

Distributed mutex actions (`actions-mutex`, `gh-action-locks`, k8s-lock, etc.) all use external coordination — git push contention, GitHub API artifacts, HTTP services, k8s secrets — because they assume runners are on different ephemeral machines. For the same-physical-machine case, that's massive overkill: you're emulating over the network something the kernel will do for you in microseconds.

`local-mutex` is the kernel solution: a thin wrapper over the OS-native command-locking primitive, exposed as a GitHub composite action.

## Usage

```yaml
- name: Update Claude Code
  uses: curlewlabs-com/local-mutex@v1
  with:
    name: claude-update
    run: |
      claude update
      claude --version
```

That's the entire interface. The lock is acquired before `run:` starts, held for the duration, and released when `run:` exits — normally or otherwise. If another runner is holding the same `name`, this caller waits indefinitely (bounded only by the job's `timeout-minutes`).

### Example: serializing a self-updating CLI

```yaml
jobs:
  review:
    runs-on: self-hosted
    steps:
      - name: Update Claude Code
        uses: curlewlabs-com/local-mutex@v1
        with:
          name: claude-update
          run: |
            claude update
            claude --version

      - name: Run review
        run: claude -p "review the diff" < pr.diff
```

If multiple runners hit this job at the same time, the update step on each one waits for the previous one's update to finish, then runs (likely a no-op since the binary is already current). The subsequent step then runs in parallel across all of them with no contention.

### Example: serializing CocoaPods across runners

```yaml
- name: Install CocoaPods dependencies
  uses: curlewlabs-com/local-mutex@v1
  with:
    name: cocoapods-spec
    run: |
      cd app/ios
      pod install || pod install --repo-update
```

Multiple macOS runners sharing `~/.cocoapods` will race on spec-cache updates. Without serialization, `--repo-update` on one runner can partially overwrite the cache another runner is reading, producing cryptic pod resolution failures.

### Example: serializing a shared cache directory write

```yaml
- name: Rebuild shared dependency cache
  uses: curlewlabs-com/local-mutex@v1
  with:
    name: dep-cache-rebuild
    run: |
      ./scripts/build-deps.sh
      mv build-output /shared/dep-cache/$(cat .deps-hash)
```

Two runners running the same build in parallel would otherwise race on writing to `/shared/dep-cache/<hash>/`. Wrapping the build+publish step in `local-mutex` makes the second runner wait for the first to finish; if your build script checks whether the entry already exists and exits early when it does, the second runner becomes a fast no-op.

[`curlewlabs-com/local-cache`](https://github.com/curlewlabs-com/local-cache) — a sister composite action that provides a local-disk cache for self-hosted runners — uses `local-mutex` for exactly this pattern. Its `save/action.yml` wraps the per-key write step in `local-mutex` so concurrent saves of the same cache key serialize via `lockf`/`flock` instead of needing per-script PID tracking and stale-lock recovery. See its [`save/action.yml`](https://github.com/curlewlabs-com/local-cache/blob/main/save/action.yml) for a working production usage.

### Example: containerized runners with a non-shared `/tmp`

By default the lock file lives under `/tmp`. On bare-metal self-hosted runners that's already shared across every runner on the host, so callers don't need to think about it. In containerized deployments where each runner sees its own `/tmp`, point `lock-dir` at a bind-mounted path on the host:

```yaml
- name: Update shared binary
  uses: curlewlabs-com/local-mutex@v2
  with:
    name: tool-update
    lock-dir: /opt/runner-shared/locks
    run: |
      /opt/runner-shared/tools/update-toolchain.sh
```

All runners must mount the same host directory at the same in-container path. The lock-file basename inside `lock-dir` is the SHA-256 of `name`, so two runners sharing `lock-dir` and `name` always land on the same inode and serialize via the host kernel's lock.

## Inputs

| Name | Required | Description |
|---|---|---|
| `name` | yes | Lock identifier. Echoed verbatim into the diagnostic `::notice::` annotations so callers see a human-readable identifier in the log, and hashed with SHA-256 to form the lock file basename (`local-mutex-<64-hex-digest>.lock`) inside `lock-dir`. Pick a name that describes the resource being protected. Any length is accepted (SHA-256 produces a fixed 64-character basename regardless of input length). Arbitrary bytes are accepted, including non-ASCII. Empty, whitespace-only, or control-character-containing (newline, tab, etc.) values are rejected. |
| `run` | yes | Shell command to execute while holding the lock. Runs under `/bin/sh`. Multi-line scripts work. Empty or whitespace-only `run` is rejected. |
| `lock-dir` | no | Absolute path to the directory where the lock file is created. Defaults to `/tmp`. Override only when `/tmp` isn't shared across the runners on the same machine — for example, on containerized self-hosted runners where `/tmp` is container-local. The directory must exist and be writable by the runner user. Callers setting the same `name` from two runners continue to serialize as long as they share the same `lock-dir`. |

## Outputs

| Name | Description |
|---|---|
| `output-file` | Path to a file containing all `$GITHUB_OUTPUT` writes made by the inner command. Because composite actions don't propagate outputs from nested steps automatically, callers that need the inner command's outputs must read this file in a subsequent step. |

### Propagating inner outputs

If your inner command writes to `$GITHUB_OUTPUT` and you need those values in later steps, add a propagation step:

```yaml
- name: Build under lock
  id: locked-build
  uses: curlewlabs-com/local-mutex@v1
  with:
    name: shared-build
    run: |
      ./build.sh
      printf 'build-hash=%s\n' "$(cat build-hash.txt)" >> "$GITHUB_OUTPUT"

- name: Propagate build outputs
  id: build
  shell: sh
  run: cat "${{ steps.locked-build.outputs.output-file }}" >> "$GITHUB_OUTPUT"

- name: Use build hash
  run: echo "Built ${{ steps.build.outputs.build-hash }}"
```

## Diagnostic notices

The action emits two [GitHub Actions `::notice::` annotations](https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions#setting-a-notice-message) to stderr around each lock acquire:

```
::notice::local-mutex: waiting for lock <name> at <UTC timestamp>
::notice::local-mutex: released <name> at <UTC timestamp>
```

The wait notice is emitted before handing off to the lock primitive, so a hung step shows what it's blocked on. The release notice is emitted after the wrapped command exits — on success, on failure, and on signal-driven exits the inner shell can trap. Both notices appear in the step log and surface in the job summary annotations.

If the wrapped `run` command installs its own `trap '…' EXIT`, POSIX shell replaces our trap with the caller's. The caller's trap still runs correctly; only our release notice is suppressed. The wait notice is unaffected.

## How it works

The script validates `name` (non-empty, no control characters) and `lock-dir` (absolute, exists, writable; default `/tmp`), hashes `name` with SHA-256 to form the lockfile basename, emits the wait notice, then probes for and execs the chosen lock primitive. The locking core (after validation, hashing, and the diagnostic trap setup described above) is:

```sh
lockfile="${lock_dir}/local-mutex-${name_hash}.lock"

if command -v lockf >/dev/null 2>&1; then
    exec lockf -k "$lockfile" sh -c "$cmd"
elif command -v flock >/dev/null 2>&1; then
    exec flock -o -x "$lockfile" sh -c "$cmd"
else
    printf '::error::local-mutex: neither lockf(1) nor flock(1) found on PATH. Install util-linux (Linux) or use a system that ships lockf (macOS, *BSD).\n' >&2
    exit 127
fi
```

No timeout flag (the job-level `timeout-minutes` bounds it). No PID tracking. No stale-lock recovery. When the process running this script exits, the kernel releases the lock — including on `SIGKILL`, OOM kill, or machine reboot. Orphaned descendants of the wrapped command continue to exist as reparented processes but no longer hold the lock; that matches normal Unix process semantics.

**Why probe instead of branching on `uname`?** Probing for the actual binary handles edge cases without an OS allowlist: a Linux user with `lockf` from a non-default package works; a macOS user with `flock` from Homebrew works; FreeBSD/OpenBSD/NetBSD work because they all ship `lockf(1)`. The probe is simpler than maintaining an OS table and more robust than guessing. When both binaries are installed, `lockf` is preferred because its default fork/exec pattern (the child closes the lock FD before exec) cleanly releases the lock when the holding process is killed, matching the documented guarantee without an extra flag.

**Why `lockf -k`?** Without `-k`, lockf `unlink(2)`s the lock file on release. That lets a fresh acquirer `open(O_CREAT)` a brand-new inode under the same name while a previous waiter is still blocked on the now-anonymous original inode — both end up holding locks on different inodes and the mutex silently breaks. `-k` skips the unlink so all callers always lock the same inode.

**Why `flock -o -x`?** `-x` is exclusive (the default, but explicit for clarity). `-o` (or `--close`) closes the lock file descriptor in the flock child before `exec`, so the wrapped command's descendants don't inherit it. Without `-o`, killing the flock parent on Linux leaves orphan processes still holding the lock — the SIGKILL release guarantee silently breaks. macOS `lockf` doesn't need an equivalent flag because BSD `lockf` already closes the lock FD in the forked child before exec.

**Why no timeout input?** Locks are bounded by the job's `timeout-minutes`. Adding a per-step timeout would just give callers two ways to specify the same thing. If you need a timeout shorter than the job, set `timeout-minutes` on the calling step.

## When to use this — and when not to

### Use it when

- You have **multiple self-hosted GitHub Actions runners on the same physical machine** under the same OS user
- They share a **resource that cannot tolerate concurrent access** (a binary being self-updated, a cache directory being written, a configuration file being rewritten, a database being migrated)
- You want to **serialize that one operation** without serializing the whole job

### Don't use it when

- **Runners are on different machines.** Local file locks can't coordinate across machines. Use GitHub Actions' built-in [`concurrency:`](https://docs.github.com/en/actions/using-jobs/using-concurrency) instead — it serializes whole jobs across all runners, which is the right granularity when you need cross-machine coordination. (Most published "distributed mutex" composite actions are now archived and explicitly point users to `concurrency:`.)
- **You need fairness or FIFO ordering across operating systems.** On Linux (`flock`), acquisition order is not guaranteed — whichever caller the kernel happens to wake up first wins. On macOS/BSD, the `lockf(1)` man page documents that `-k` "will guarantee lock ordering," which this action passes. If your fleet mixes both OSes, don't design around FIFO; if it's all BSD-family, you can rely on it.
- **You need reentrant locks.** A process acquiring the same lock twice will deadlock.
- **You need a lock with a timeout shorter than the job.** Use `timeout-minutes` on the calling step instead.
- **You're trying to serialize work outside the runner machine** (a Cloudflare API call, a database operation, a remote service). The lock is local — it can't see beyond the runner host's filesystem.

## Comparison with the alternatives

| | local-mutex | `concurrency:` (built-in) |
|---|---|---|
| Coordination scope | Same physical machine | GitHub API (cross-machine) |
| Granularity | Per-step / per-resource | Per-job or per-workflow |
| Latency to acquire | Microseconds (kernel) | Queues whole jobs (cancels with `cancel-in-progress: true`) |
| Setup required | None — composite action only | None — built into Actions |
| Stale lock recovery | Automatic (kernel-managed) | n/a |
| Cross-runner-machine | No | Yes |

**Pick `local-mutex` when** runners share a machine and the bottleneck is a local resource — you want all your runners to keep running in parallel except when they touch the one shared thing. **Pick `concurrency:`** when you want to ensure only one job (or one workflow) runs at a time across all runners, regardless of machine.

## Requirements

- Self-hosted GitHub Actions runner on Linux, macOS, or any BSD that ships `lockf(1)`.
- One of `lockf(1)` or `flock(1)` on `PATH`. Both are standard:
  - **macOS:** `lockf` is at `/usr/bin/lockf` on every install (BSD heritage).
  - **Linux:** `flock` is in `util-linux`, installed by default on every modern distribution.
- A SHA-256 command on `PATH`. Both are standard:
  - **macOS:** `shasum` is at `/usr/bin/shasum` on every install (Perl core).
  - **Linux:** `sha256sum` is in `coreutils`, installed by default on every modern distribution.
- A writable directory shared between concurrent runners. Defaults to `/tmp`, which already fits bare-metal self-hosted runners under the same OS user. Containerized runners that don't share `/tmp` should pass `lock-dir:` pointing at a bind-mounted host path. If no directory is shared between the runners you want to coordinate, a local mutex can't help — use a distributed lock instead.

GitHub-hosted runners (`ubuntu-latest`, `macos-latest`) also work — they have the binaries — but the use case doesn't apply because GitHub-hosted runners are ephemeral and don't share state across jobs.

This repository's CI still runs on GitHub-hosted Linux and macOS runners because public-repo self-hosted testing is operationally awkward and security-sensitive. That CI meaningfully verifies the action's contract at the lock-primitive level (`lockf` on macOS, `flock` on Linux), but it does not fully reproduce the production topology of multiple self-hosted runners sharing one physical machine and one `/tmp`. If you need to validate that exact deployment shape, run the manual same-machine check below on the host where your runners live.

## Manual validation on a shared runner host

To validate the real deployment model end-to-end, open two terminals on the same machine under the same OS user and run the script directly from this checkout in both terminals with the same lock name.

**Terminal 1**

```sh
sh lib/local-mutex.sh manual-check 'date; echo "terminal 1 acquired"; sleep 10; echo "terminal 1 releasing"; date'
```

**Terminal 2** (start this while Terminal 1 is still sleeping)

```sh
sh lib/local-mutex.sh manual-check 'date; echo "terminal 2 acquired"; echo "terminal 2 releasing"; date'
```

Expected result: Terminal 2 blocks until Terminal 1 exits, then acquires the same lock immediately after. If you want to mimic the action more closely, repeat the same experiment from two separate self-hosted runner jobs on the same host using `uses: curlewlabs-com/local-mutex@v1` with the same `name:`.

## Releasing

Users pin to `@v1` (floating major tag).

**First release (v1.0.0):**

```sh
git tag v1.0.0 HEAD
git tag v1 HEAD
git push origin v1.0.0 v1
gh release create v1.0.0 --title "v1.0.0" --notes "Initial release"
```

**Subsequent patch/minor releases:** after merging the change to `main`,

```sh
# Move the floating major tag so @v1 users get the update.
git tag -f v1 HEAD
git push --force origin v1

# Create a versioned release for the marketplace.
git tag v1.x.y HEAD
git push origin v1.x.y
gh release create v1.x.y --title "v1.x.y" --notes "changelog here"
```

## License

MIT — see [LICENSE](LICENSE).
