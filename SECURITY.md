# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it
privately via [GitHub's security advisory feature](https://github.com/curlewlabs-com/local-mutex/security/advisories/new).

Do not open a public issue for security vulnerabilities.

## Scope

This action wraps OS-native lock primitives (`lockf`/`flock`) and executes
caller-provided shell commands. The primary security surface is:

- **Name hashing:** The `name` input is hashed with SHA-256 before being used
  as a lock-file basename (`local-mutex-<64-hex-digest>.lock`). Path traversal
  via the lock name is structurally blocked because the basename is always
  exactly 64 hex characters — no caller-controlled bytes reach the filesystem
  layer of the path. The raw `name` is echoed verbatim into the diagnostic
  `::notice::` annotations; to keep those annotations a single parseable line,
  names containing ASCII control characters (byte `0x00`–`0x1F` or `0x7F`,
  including newlines and tabs) are rejected with exit 2.
- **Command execution:** The `run` input is executed as-is under `/bin/sh`.
  This is by design — the action is a thin wrapper, not a sandbox.
