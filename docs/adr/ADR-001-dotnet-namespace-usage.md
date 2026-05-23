# ADR-001 — .NET Namespace Usage Policy

**Status:** Accepted
**Date:** 2026-05-23

## Context

PowerShell provides built-in cmdlets and type accelerators that cover most
common operations. Direct use of .NET namespaces (e.g. `[System.UriBuilder]`,
`[System.Net.Http.HttpMethod]`) bypasses the PowerShell abstraction layer and
can reduce readability, portability, and discoverability for consumers of the
module.

However, there are cases where the built-in PowerShell way does not provide
the required behaviour, precision, or RFC compliance — particularly around
URI construction, HTTP method type safety, and secure string handling.

## Decision

Every direct use of a .NET namespace in this module must be accompanied by an
inline comment that records:

1. The .NET type being used
2. Why the built-in PowerShell equivalent was not sufficient
3. A reference to the relevant RFC or specification where applicable

Example:

```powershell
# Using [System.UriBuilder] over [uri] cast or string concatenation because
# UriBuilder provides mutable, component-level URI construction per RFC 3986.
# A [uri] cast is immutable post-construction and string concatenation does
# not validate component boundaries.
# RFC 3986 Section 3: https://www.rfc-editor.org/rfc/rfc3986.html#section-3
$uriBuilder = [System.UriBuilder]::new($scheme, $hostname, $portNumber)
```

## Rationale

This policy ensures that .NET usage is intentional and traceable rather than
habitual. It also makes the cross-OS impact visible — .NET types that rely on
Windows-specific behaviour will be identifiable at the point of use.

## Consequences

- Every .NET namespace usage requires a small documentation overhead
- Future OS compatibility reviews can grep for `[System.` and audit each instance
- Consumers of the module can understand why a given approach was chosen
