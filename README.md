# local-mutex

Wrap a command in a local-filesystem mutex on self-hosted GitHub Actions runners.

A composite action for the case where multiple GitHub Actions runners share a single physical machine and need to serialize access to a shared resource — a tool installation, a system daemon, a cache directory, anything that can't tolerate concurrent access. Uses [`lockf(1)`](https://man.freebsd.org/cgi/man.cgi?lockf(1)) on macOS/BSD or [`flock(1)`](https://man7.org/linux/man-pages/man1/flock.1.html) on Linux, whichever is on `PATH`. The lock is held by the action's own process; when that process exits — normally, on `SIGKILL`, OOM kill, or machine reboot — the kernel releases the lock immediately. There is no stale-lock recovery code in this action because there is no stale-lock problem to recover from.

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

## Inputs

| Name | Required | Description |
|---|---|---|
| `name` | yes | Lock identifier. Used as the basename of the lock file under `/tmp`. Pick a name that describes the resource being protected. Characters outside `[a-zA-Z0-9._-]` are sanitized to underscores. Names longer than 200 characters are truncated. |
| `run` | yes | Shell command to execute while holding the lock. Runs under `/bin/sh`. Multi-line scripts work. Empty or whitespace-only `run` is rejected. |

## How it works

The script sanitizes the `name` input into a safe filename component, builds a lockfile path under `/tmp`, then probes for and execs the chosen lock primitive. The actual core (after the validation and sanitization steps) is:

```sh
lockfile="/tmp/local-mutex-${safe_name}.lock"

if command -v lockf >/dev/null 2>&1; then
    exec lockf -k "$lockfile" sh -c "$cmd"
elif command -v flock >/dev/null 2>&1; then
    exec flock -o -x "$lockfile" sh -c "$cmd"
else
    fail "neither lockf(1) nor flock(1) found"
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
- **You need fairness or FIFO ordering.** `lockf` and `flock` don't guarantee acquisition order. Whichever caller the kernel happens to wake up first wins.
- **You need reentrant locks.** A process acquiring the same lock twice will deadlock.
- **You need a lock with a timeout shorter than the job.** Use `timeout-minutes` on the calling step instead.
- **You're trying to serialize work outside the runner machine** (a Cloudflare API call, a database operation, a remote service). The lock is local — it can't see beyond `/tmp`.

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
- A writable `/tmp` directory shared between concurrent runners. (If your runners somehow have separate `/tmp` namespaces, this won't work — use a distributed lock instead.)

GitHub-hosted runners (`ubuntu-latest`, `macos-latest`) also work — they have the binaries — but the use case doesn't apply because GitHub-hosted runners are ephemeral and don't share state across jobs.

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
