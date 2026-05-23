# ADR-002 — Parameter-Driven over Config-File-Driven

**Status:** Accepted
**Date:** 2026-05-23

## Context

An earlier version of the wrapper loaded connection details (scheme, host,
port, credential file path) from a JSONC config file at a path relative to
`$PSScriptRoot`. This mirrors the pattern common in console applications
that use `appsettings.json`.

## Decision

The wrapper will not use a config file for connection parameters. All inputs
are provided through the function signature, splatting, and the pipeline.

## Rationale

- Config-file-driven design is not idiomatic PowerShell. Consumers expect to
  pass parameters, not manage sidecar files.
- A parameter-driven wrapper is composable — callers can splat, pipe, and
  chain without being coupled to a file on disk.
- Config files introduce a deployment concern (file location, permissions,
  format) that is not appropriate for a general-purpose wrapper.
- PowerShell's `$PSDefaultParameterValues` provides a native mechanism for
  consumers who want persistent defaults without requiring the module to
  manage config files itself.

## Consequences

- No dependency on `$PSScriptRoot` or file system layout at runtime
- Callers are responsible for supplying connection parameters — a wrapper
  or profile script is the appropriate place for persistent defaults
- `$PSDefaultParameterValues` is the recommended pattern for consumers who
  want to avoid repeating parameters across calls
