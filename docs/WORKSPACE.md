# Handoff workspace: first graphical slice

From the standalone source directory, run:

```powershell
pwsh -NoProfile -File ./Start-Handoff.ps1
```

The browser opens automatically. PowerShell hosts the local UI; you do not
operate a terminal chat, install Node, use Docker or create a Handoff account.
For an installed module, import Handoff and run `Start-Handoff.ps1` from its
module directory, as shown in [INSTALL.md](../INSTALL.md).

## What you can do now

- Browse verified saved investigations from the current user's local
  `Handoff/Investigations` folder, or the bundled fictional **Support team** sample.
- Inspect friendly policy names, inclusion/exclusion relationships, policy states,
  coverage and manual checks. Stable IDs and raw settings remain expandable details.
  Names that were never collected are explicitly unresolved, not invented.
- Add an OpenAI or Anthropic key and model in **AI settings**. This configures the
  session without contacting the provider. Azure OpenAI is not in this first UI;
  its separate command-line adapter remains experimental.
- Ask a question, review a plain-English sharing dialog, and select **Allow & send
  question** or **Keep local**. The exact technical request is available inside the
  dialog but is not the default experience.
- Ask follow-up questions with the prior user/assistant messages as context. Up to
  ten answered questions fit in one conversation, subject to a 256 KiB total
  provider-request limit. Start a new conversation when the limit is reached.

Sharing approval is bound to the loaded investigation/observation, provider and
model for this process. Each subsequent **Send** shares its question, conversation
context and selected evidence. Changing provider settings, starting a new
conversation or forgetting the key revokes the relevant approval and history.
Different investigations have separate conversations and approvals.

## Important limits

**This is saved-evidence conversation, not the completed live investigation agent.**
The workspace does not sign in, load Graph, refresh an observation, discover
unsaved groups, resolve additional directory names or run tenant operations.
The supported live-read UI/tools are the next slice, not a hidden capability.
For now, collect through the [read-only guide](../INSTALL.md#3-run-an-investigation),
then restart the workspace to load the new saved evidence. It loads the newest
observation from each accepted investigation folder, not arbitrary uploaded reports.

CA and Intune device compliance remain the only supported policy families. Neither
chat nor evidence can prove safe deletion, effective population or lockout impact.
The prior console single-answer adapter has been checked live; this new multi-turn
UI must receive its own live-provider acceptance. Mocked browser tests are not
evidence of live API compatibility or tenant authentication.

## Local and provider data boundaries

- The host listens only on `127.0.0.1` (default port 43187). It is not suitable for
  LAN access, internet hosting, reverse proxies or multiple users. HTTP is used on
  loopback only. Provider API traffic is HTTPS.
- The launcher supplies a random session capability in the local URL fragment.
  API requests require that token plus the exact loopback host and same origin;
  it is not a replacement for OS account security. Do not share the session URL.
  A local process running as your user is outside this boundary.
- Keys, messages and approvals stay in host memory. The app does not save them to
  disk or browser storage. Stop the host to clear the session; do not rely on
  closing a browser tab. An idle host stops after one hour without local requests.
- Provider keys are sent only as provider authentication headers, never as model
  context. Group/policy/assignment names, IDs, matched settings, questions and chat
  context go to your selected provider after approval and are subject to its terms.
  Private notes are excluded. The constructed envelope omits the tenant ID, but
  policy text and your messages are not automatically redacted.
- Saved files are read and validated without being rewritten. At most 20 newest
  investigation folders and 64 MiB aggregate evidence are considered; unreadable,
  linked, corrupted or over-budget evidence is reported as not loaded, not absent.
- All tenant/model text is rendered as text with limited safe formatting, not HTML.
  Static assets are bundled locally under a restrictive CSP. No telemetry or CDN
  is used. A temporary fictional evidence journal is created for the sample.

Use **AI settings → Forget key & chats** to keep browsing without AI, or
**Stop workspace → Stop & forget session** to stop the host. Saved investigations
remain on disk. The key field is cleared after use; password-manager/OS behaviour
and host memory protection are not controlled by Handoff.

## Verification

`tests/Workspace.Tests.ps1` checks consent, ticket replay/expiry, scope isolation,
bounded conversation history, key exclusion and host/origin/session guards.
`tests/browser/verify-workspace.mjs` starts a fictional-only host with a fake
provider, exercises HTTP and browser flows, and saves desktop/mobile screenshots.
See [browser checks](../tests/browser/README.md). No real key, provider request or
tenant operation is used by that browser suite.

The UI reuses Handoff's approved violet/white palette and exact mark geometry.
The bundled Geist font is unchanged from the wider app and retains its separate
SIL Open Font License in `workspace/Geist-OFL.txt`; other project code is AGPL-3.0-only.
