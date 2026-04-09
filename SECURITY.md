# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it
privately via [GitHub's security advisory feature](https://github.com/curlewlabs-com/local-mutex/security/advisories/new).

Do not open a public issue for security vulnerabilities.

## Scope

This action wraps OS-native lock primitives (`lockf`/`flock`) and executes
caller-provided shell commands. The primary security surface is:

- **Input sanitization:** The `name` input is sanitized to `[a-zA-Z0-9._-]`
  before being used as a filename component. Path traversal via the lock name
  is blocked by this sanitization.
- **Command execution:** The `run` input is executed as-is under `/bin/sh`.
  This is by design — the action is a thin wrapper, not a sandbox.
