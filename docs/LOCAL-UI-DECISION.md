# Local workspace runtime decision

**Status:** Implemented for the first UI slice; owner UX acceptance pending.
**Date:** 9 November 2026.

## Context

The public product needs Handoff identity and conversation, not terminal Q&A.
It must remain independent of the wider application's database, organisation
authentication and execution engine. The validated readers and provider adapters
already use PowerShell 7 on Windows.

## Decision

Use a loopback-only PowerShell host with bundled browser assets for this slice.
Reuse Handoff's approved mark, Geist font and colour tokens; keep the existing
read-only evidence modules as the source of truth. The workspace imports no Graph
SDK or wider-app execution modules. Provider transport and context allow-listing
remain shared with Axon, with a separate prepared-request/in-app approval path.

The browser renders saved evidence and multi-turn chat. It is not advertised as
the live investigation agent. New predefined live reads require a subsequent
scoped design and acceptance step, rather than exposing arbitrary PowerShell or
the existing web application's full tool catalogue.

## Alternatives and trade-offs

- Reusing the full Next.js app would also pull in its organisation/auth/database
  boundaries. Reusing visual identity is useful; bypassing those dependencies or
  handing the public reader its write-capable routes is not a safe shortcut.
- A separate Node web app adds another runtime and distribution/build pipeline
  before the founder has accepted the experience.
- Electron/Tauri adds packaging, signing and bridge/security work; revisit for a
  polished desktop installer, not as a prerequisite for this first functional UI.
- A static mock alone cannot validate real conversation, key handling or sharing.

PowerShell's single-request local listener is deliberately modest: one user,
one process, a bounded request body and provider deadline, no LAN hosting, and an
explicit Stop action. A pending model request can occupy the host for up to its
120-second timeout. A blocked port or denied local-listener policy is a startup
failure, not a reason to bind to all interfaces or request elevation automatically.

## Acceptance boundaries

Unit tests and fictional, fake-provider browser tests verify local authority,
safe rendering, consent and continuity. The normal UI uses the real provider
adapters, but requires separate live multi-turn acceptance with an operator's
key and in-app approval. Owner usability, signed distribution, clean Sandbox UI
launch, screen readers and in-UI live collection are not inferred from those tests.
