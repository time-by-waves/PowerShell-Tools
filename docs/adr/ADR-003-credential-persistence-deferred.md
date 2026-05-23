# ADR-003 — Credential Persistence Deferred

**Status:** Deferred
**Date:** 2026-05-23

## Context

The reference implementation uses `Export-Clixml` and `Import-Clixml` for
persisting `PSCredential` objects to disk. These cmdlets use the Windows
Data Protection API (DPAPI) to encrypt the credential, meaning the encrypted
file can only be decrypted by the same user on the same machine.

This is appropriate for v1 (Windows only) but is not portable to Linux or
macOS where DPAPI is unavailable.

## Decision

Credential persistence is deferred until the cross-OS strategy is defined.
v1 will accept credentials at runtime via parameter only. No read or write
of credential files will be implemented in v1.

## Rationale

- Implementing `Export-Clixml` now and patching it later creates a visible
  breaking change for consumers who have stored credentials under the v1 approach.
- Deferring keeps the v1 surface clean and forces a proper decision rather
  than a patch.

## Options Under Consideration (not yet decided)

| Option | Notes |
|--------|-------|
| `Export-Clixml` (Windows only) | DPAPI-backed, simple, not portable |
| `SecretManagement` module | Cross-platform, requires additional module dependency |
| AES + shared key via `ConvertFrom-SecureString` | Portable but key management adds complexity |
| Caller-managed | Module never persists — caller handles storage and passes credentials in |

## Consequences

- v1 consumers must supply credentials on every call or manage persistence themselves
- The decision on this ADR gates the credential persistence feature in a future version
