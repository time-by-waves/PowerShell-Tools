# ADR-004 — OS Versioning Strategy

**Status:** Accepted
**Date:** 2026-05-23

## Context

The wrapper has an OS-agnostic long-term goal but is being built Windows-first
so that OS-specific decisions are visible and traceable rather than discovered
during a later porting effort.

## Decision

- v1 is Windows only. No Linux or macOS code paths.
- Any code that is Windows-specific must be marked with an inline comment:
  `# Windows only — see ADR-004`
- The goal is minimal OS-specific code paths. Where a cross-platform
  alternative exists at equivalent quality, it is preferred even in v1.
- When a later version introduces cross-OS support, changes to Windows-specific
  sections will reference back to this ADR and the new ADR that supersedes it.

## Rationale

Building Windows-first with explicit marking ensures:
- The delta between v1 and a cross-OS version is auditable
- No Windows assumptions are hidden in the implementation
- Future contributors can identify every point that needs a platform decision

## Consequences

- All Windows-specific code is findable by searching for `# Windows only`
- `Export-Clixml` and DPAPI usage is deferred (see ADR-003) as it would
  immediately create a Windows-only dependency in a core function
- The module will carry a `#Requires -Version` statement targeting
  PowerShell 7+ to avoid Windows PowerShell 5.1 compatibility concerns
