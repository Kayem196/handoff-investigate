# Handoff Investigate

Before you change or remove an unfamiliar Entra group, find out which policies
use it.

Handoff Investigate is a free, **read-only** PowerShell tool for Microsoft 365
administrators. For a selected group, it finds explicit include and exclude
references in **Conditional Access** policies and **Intune device-compliance**
policy assignments. It keeps the original policy settings as evidence, tells
you what it could not check, and gives you specific manual checks before you
make a change.

It never changes your tenant. It needs no hosted service, Docker, database or
Handoff account. Optional AI runs only when you ask and approve sharing.

## Handoff workspace — first UI preview

Open the local Handoff-branded workspace from the standalone source folder:

```powershell
pwsh -NoProfile -File ./Start-Handoff.ps1
```

It opens your browser with saved investigations, friendly policy names,
expandable evidence and multi-turn chat. Add an OpenAI or Anthropic key in
**AI settings**, then approve sharing inside the app. The bundled fictional
example works for browsing without a key. No raw payload file or terminal chat
is needed.

**Microsoft 365** in the sidebar signs in your dedicated read-only reader, lists
visible groups and collects fresh evidence, each step confirmed in the app. Chat
discusses the selected saved observation; it cannot run reads or make changes.
Conversation history and keys stay in
the local host's memory for this session. See the
[workspace guide and security boundary](docs/WORKSPACE.md).

> **Preview (0.1.0-preview1).** This has been tested on Windows 11 with
> PowerShell 7.6.9 and verified against a test tenant. Read
> [what is and isn't verified](INSTALL.md#verified-and-not-yet-verified) before
> relying on it.

## What it does

- **Guided investigation.** Lists visible groups, then you pick one by number.
  Groups with the same name are distinguished by ID. It reads only that group's
  references, after you confirm. See `Start-HandoffGroupInvestigation`.
- **Honest coverage.** Partial reads, permission limits, unsupported targeting
  and timeouts are recorded and shown first. A missing reference is never
  presented as proof of absence.
- **Saved evidence.** Investigations are saved locally and append-only, with
  notes. Refreshing adds a new observation and shows what differs from the
  earlier one.
- **Reports.** Exports self-contained HTML (no scripts or external resources)
  and structured JSON.
- **Bounded reads.** Limits on pages, items, response size and time, with
  redirects refused. It uses delegated access through a dedicated, tenant-owned
  app registration with three read scopes.
- **Optional Axon.** Ask an AI model (Anthropic, OpenAI or Azure OpenAI) to
  explain a saved observation. Only an allow-listed summary is shared, and only
  after you type `SHARE`. The tenant ID is never sent.

## What it does not do

It doesn't say a group is unused, unnecessary or safe to delete. It doesn't
count affected people or predict lockouts. It doesn't evaluate filter rules,
group membership or other workloads such as configuration profiles, apps,
Teams/SharePoint, roles or third-party services. Each report lists the checks
you still need to make.

## Quick start

See **[INSTALL.md](INSTALL.md)** for requirements, installation, the one-time
reader registration and your first investigation. To try it with fictional data
and no tenant access:

```powershell
Import-Module Handoff
& "$((Get-Module Handoff).ModuleBase)/examples/export-investigation.ps1" `
    -OutDirectory (Join-Path $env:TEMP ('handoff-demo-' + [guid]::NewGuid()))
```

## Documentation

- [INSTALL.md](INSTALL.md): setup, permissions and removing access
- [Manual testing checklist](docs/USER-TESTING.md): first-session questions,
  expected evidence and optional Axon checks
- [Workspace guide](docs/WORKSPACE.md): local graphical chat, sharing and limitations
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): command reference, data contracts,
  limits and verification records
- [docs/KNOWN-ANSWER-CHECKS.md](docs/KNOWN-ANSWER-CHECKS.md),
  [docs/TRANSPORT-CHECKS.md](docs/TRANSPORT-CHECKS.md) and
  [docs/FIXTURE-SETUP.md](docs/FIXTURE-SETUP.md): how live behaviour was
  verified
- [SECURITY.md](SECURITY.md) and [CONTRIBUTING.md](CONTRIBUTING.md)

## Licence

AGPL-3.0-only. See [LICENSE](LICENSE).
