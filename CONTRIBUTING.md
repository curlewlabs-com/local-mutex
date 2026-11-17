# Contributing

Thanks for your interest in improving `local-mutex`. The bar for a change is
whether two callers taking the same `name` in the same lock directory, under
one kernel, still run one at a time, and the lock still goes away with the
process holding it, even on `SIGKILL`. Bug fixes, sharper diagnostics when a
lock waits or a call is refused, results of the README's manual check on a
runner setup CI cannot reproduce, and clearer docs are all welcome.

## Before a large change

Open an issue describing the problem first. The guarantee rests on the kernel
doing the work: the lock is the OS's own `lockf` or `flock` wrapped around one
command, with no fallback lock and no stale-lock recovery, and the `lockf -k`
and `flock -o` flags are what keep every caller on one inode and stop a killed
holder's children from keeping the lock. Callers also depend on more than
`action.yml`'s inputs, and AGENTS.md lists those interfaces. README.md's "How
it works" section explains the flags. A short discussion up front saves
rework.

## Running the checks

CI runs these on every push to `main` and every pull request against it:

```sh
shellcheck lib/local-mutex.sh
actionlint
```

The integration tests are the steps of `.github/workflows/ci.yml`, and run on
GitHub's hosted runners: `ubuntu-latest`, which takes the lock with `flock`,
and `macos-latest`, which takes it with `lockf`. A new test goes in that file
beside them, and a change to the locking path needs a test where two callers
contend. CI does not reproduce several runners sharing one machine; README.md's
"Manual validation on a shared runner host" checks that with two terminals.

Keep each pull request to one change, with its test, and describe the why in
its body. AGENTS.md holds the repository's rules and its release steps.
