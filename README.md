# local-mutex
Wrap a command in a local-filesystem mutex (lockf/flock) on self-hosted GitHub Actions runners. For when N runners on the same machine need to serialize access to a shared resource.
