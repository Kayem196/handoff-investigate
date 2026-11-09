# Contributing

Issues and pull requests are welcome. Feedback from real investigations is the
most valuable kind, for example "this saved me X" or "I still had to check Y by
hand", as long as it is sanitised.

## Reporting a problem

Include the module, PowerShell and Graph SDK versions, the command you ran and
the fixed outcome or failure codes, such as `request_limit`,
`redirect_rejected` or `provider_auth_failed`. Use fictional IDs and names.
**Do not attach** tenant dumps, saved investigations, exported reports, tokens
or keys. Security problems go through [SECURITY.md](SECURITY.md).

## Development

Requirements: Windows, PowerShell 7.5 or later, and Pester 6.0.0.

```powershell
Import-Module Pester -RequiredVersion 6.0.0
Invoke-Pester -Path ./tests -CI
./tools/Build-HandoffPackage.ps1 -OutDirectory (Join-Path $env:TEMP ('handoff-pkg-' + [guid]::NewGuid()))
```

Optional integration checks need Microsoft.Graph.Authentication 2.38.1 and
Python; see `tests/transport`. The HTML report checks need Node and Edge or
Chromium; see `tests/browser`. None of these contact a tenant.

**Principles for changes:**
- Stay read-only.
- Never turn incomplete evidence into a conclusion.
- Keep tenant text as data.
- Bound every read.
- Add a test for every new branch or boundary.
- Live behaviour claims need dated evidence from a test tenant (see `docs/`),
  not just mocks.

By contributing, you agree that your contribution is licensed under
AGPL-3.0-only.
