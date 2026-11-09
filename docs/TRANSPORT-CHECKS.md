# Graph SDK transport: measured limits and release blockers

8 November 2026. The local Windows probe completed **16 observation checks** with
no tenant calls. PASS means the observations match the pinned SDK, including
unsafe defaults; it does **not** mean the collector is ready for public release.
No production transport policy was changed in this slice.

## Collector controls — 9 November 2026

The original 8 November observations below remain historical evidence. The new
collector path implements per-request redirect/ordinary-retry rejection, streamed
decompressed-response limits and a shared cancellation deadline. It uses the
existing SDK HTTP client and public Kiota request options; it does not rewrite
private middleware, extract credentials or change ambient SDK configuration.
The pinned SDK's cloud handler rewrites request URLs, so the production client
factory also rejects any effective endpoint other than the Global Graph origin.

The integration runner below uses the real SDK retry, redirect, authentication
and decompression pipeline with a fictional token. A test-only routing handler
and an explicitly loopback SDK environment map the collector's fixed resource
URLs to the fixture. Only binding and client routing are substituted in the
disposable process; the collector's read, parse, failure and partial-result paths
run normally. Its synthetic identity does not prove live delegated token refresh.

Windows 11 / PowerShell 7.6.9 / SDK 2.38.1 passed **25 collector integration
checks**, all **361 combined PowerShell tests** (42 public), and the original
**16 SDK observation checks**. There were zero failed/skipped Pester tests;
the combined suite retained its existing `Get-MgSubscribedSku` authentication
warning. The successful integration reports confirm helper cleanup and no tenant
calls. No real login, consent change, tenant mutation or VM deployment occurred.

```powershell
pwsh -NoProfile -File ./public-handoff/tests/transport/Invoke-CollectorTransportChecks.ps1 `
    -PythonPath 'C:\path\to\python.exe' `
    -OutFile (Join-Path $env:TEMP 'handoff-collector-new-run.json')
```

The checks cover exact-cap acceptance; content-length, chunked and compressed
oversize rejection; same-origin, host-changing, port-changing and all five
redirect statuses; ordinary/authentication retry counts; malformed JSON;
header/body timeouts; one deadline across multiple requests; external cancellation;
group failure; completed-page retention; SDK reset; the cloud endpoint guard;
and unchanged ambient settings/client/normal redirect behaviour after collection.
Reports stay outside Git. The runner cleans up its helper and clears only its
own fictional in-memory authentication context, avoiding shared SDK logout.

During fixture development, one failed setup sent a request to Graph with the
fixed fictional credential because the SDK rewrote the loopback URL to its
Global endpoint. No real credential, authenticated tenant read or tenant mutation
was used. Subsequent runs explicitly set and validate the fixture cloud endpoint;
the production guard rejects that test-only endpoint. Do not count the failed
setup as loopback-only validation.

The response cap is per decompressed response, not a total heap-allocation cap.
The deadline cancels async authentication/HTTP/streaming work; synchronous SDK
client initialisation and JSON conversion are checked at their boundaries, not
forcibly preempted. A shorter ambient SDK timeout may fail a read sooner. Only
the standard 2.38.1 pipeline in a dedicated process is supported. Custom clients,
concurrent environment/session mutation, live TLS/proxy behaviour, real delegated
refresh, Ctrl+C and clean-machine setup are not accepted by these local checks.
Retain the visible session guards and do not generalise local evidence to public
release approval.

### Live replay — 9 November 2026

The [fresh delegated known-answer replay](KNOWN-ANSWER-CHECKS.md#new-transport-live-replay--9-november-2026)
passed all six checks on committed source `84748980`: three exact fixture
reference cases, request-budget exhaustion, wrong-tenant preflight and unchanged
ambient request settings. The recorded collector/helper hashes match that source.
The run used the intended reader and three read scopes over the existing HTTPS
service path, with 4 MiB response caps and 120-second deadlines. It preserved
earlier evidence, made no tenant changes and exited its dedicated process.
This closes the repeated basic sign-in/service-read gate, not real refresh/claims
challenge, denied-reader, live pagination/failure, TLS/proxy variants, clean setup
or Ctrl+C acceptance. Raw evidence stays private.

## Reproduce

Use a fresh Windows `pwsh -NoProfile` process with PowerShell 7, installed
Microsoft.Graph.Authentication **2.38.1** and an existing Python 3 interpreter.
Python is a test-fixture dependency only; the investigation modules do not need it.
From the source root, replace the interpreter path with the installed Python path
and use an output filename that does not already exist:

```powershell
pwsh -NoProfile -File ./public-handoff/tests/transport/Invoke-TransportProbe.ps1 `
    -PythonPath 'C:\path\to\python.exe' `
    -OutFile (Join-Path $env:TEMP 'handoff-transport-new-run.json')
```

The script refuses an existing Graph session, creates its own fictional-token
session, and starts a hidden Python fixture bound only to `127.0.0.1` on two
ephemeral ports. It validates the loopback URLs before issuing requests. No token,
tenant or account is accepted as input. The Authorization header is a fixed
fictional value, explicitly supplied for redirect testing. There is no Microsoft
login, consent, application provisioning, TLS trust-store change or tenant call.

The probe creates a fresh server on every run, counts SDK HTTP requests including
redirect targets (excluding its own statistics queries), records sixteen cases,
and asserts the expected outcomes.
It stops its own helper and removes its generated temporary files in `finally`.
The output JSON is retained. The test explicitly clears only its own fictional
in-memory SDK context: the pinned SDK's ordinary disconnect path deletes the
shared authentication record even with a process-scoped session.

This is a separate integration probe, not part of Pester's SDK-boundary unit
suite. It needs local loopback access; the Codex execution sandbox blocked that
networking, so the successful Windows run used normal local access for both
fixture and client. No user or firewall setting was changed.

## Tested identity and provenance

- Windows 11, build 10.0.26300 x64; PowerShell 7.6.9; .NET 10.0.14.
- Installed authentication assembly version 2.38.1.0, SHA-256
  `61445D72E7B6F4A77023265636F14F81A862338E2E72413F197D26486AE6823E`.
- Official source reference: tag `v2.38.1`, commit
  `b3d0ce5ac752b34701ab3af4c26fc3c2d45d36e7`. Source reference and observed
  assembly identity are recorded separately; this is not a reproducible-build
  attestation.
- The JSON report and source snapshots are retained in local evidence outside
  the shareable source tree. `helperStopped = true`, `tenantCalls = 0`.

## Observations

The fixture uses HTTP loopback and a user-provided fictional token, not a live
delegated credential or Microsoft's service. HTTPS/TLS, proxy behaviour and live
delegated refresh are outside these measurements.

| Case | Observed SDK 2.38.1 behaviour |
| --- | --- |
| Defaults | Client timeout 300 seconds; three retries; initial retry delay three seconds; retry time limit zero |
| 503 then recovery | Third attempt succeeded; fixture returned `Retry-After: 0` |
| Persistent 503 | Four HTTP attempts with `MaxRetry = 3`, then failure |
| Retries disabled | One 503 attempt with `MaxRetry = 0` |
| Persistent 401 | **Two** HTTP attempts despite `MaxRetry = 0` |
| Delayed headers | Configured one-second timeout failed at approximately one second |
| Delayed body | Same timeout held even with `OutputType HttpResponseMessage`; that output mode did not provide streaming headers-only completion |
| Same-origin redirect | Followed; two HTTP requests; fictional Authorization retained |
| Different host redirect | Followed; two HTTP requests; Authorization absent at target |
| Different port redirect | Followed; two HTTP requests; Authorization absent at target |
| Content-length body | JSON containing an 8 MiB string was accepted and converted to a hashtable |
| Chunked body | Same 8 MiB string accepted without Content-Length |
| Compressed body | Same 8 MiB decompressed string accepted |
| Content-length with 1 MiB HTTP buffer cap | Rejected before JSON conversion |
| Chunked with same cap | Rejected before JSON conversion |
| Compressed with same cap | Rejected after decompression reached the cap, before JSON conversion |
| Explicit pipeline stop | Local in-flight request stopped promptly, well below the five-second fixture response delay |

The three uncapped large-body cases caused approximately **128–144 MiB of
cumulative managed allocations** apiece in the measured calls. This is an
allocation counter, not peak memory, live retained memory or a universal ratio.
The body had only one item: the collector's retained-item count cannot bound
response allocation. The cap was applied directly to the SDK-created
`HttpClient.MaxResponseContentBufferSize` before its first use, after resetting
that test's request context. The production collector does not yet do this.

These observations agree with the pinned source:

- [HTTP client construction](https://github.com/microsoftgraph/msgraph-sdk-powershell/blob/v2.38.1/src/Authentication/Authentication/Helpers/HttpHelpers.cs)
  installs retry and redirect middleware and uses the configured client timeout.
- [The SDK's authentication handler](https://github.com/microsoftgraph/msgraph-sdk-powershell/blob/v2.38.1/src/Authentication/Authentication/Handlers/AuthenticationHandler.cs)
  has a separate 401 retry path, independent of normal retry middleware settings.
- [Invoke-MgGraphRequest](https://github.com/microsoftgraph/msgraph-sdk-powershell/blob/v2.38.1/src/Authentication/Authentication/Cmdlets/InvokeMgGraphRequest.cs)
  calls `HttpClient.SendAsync` without headers-only completion, then reads the
  content as a string for hashtable conversion. Its stop handler cancels its
  request token.
- [Set-MgRequestContext](https://github.com/microsoftgraph/msgraph-sdk-powershell/blob/v2.38.1/src/Authentication/Authentication/Cmdlets/RequestContext/SetMgRequestContext.cs)
  changes the shared SDK request context and resets its cached HTTP client.
  Setting a timeout or buffer cap once is not proof that subsequent SDK client
  resets preserve it.
- [SDK logout](https://github.com/microsoftgraph/msgraph-sdk-powershell/blob/v2.38.1/src/Authentication/Authentication.Core/Utilities/AuthenticationHelpers.cs)
  clears the shared authentication record. The synthetic probe avoids that
  logout path and never signs a real account out.

## Consequences for the collector

This section records the 8 November gap and design requirements. The new local
implementation above addresses the combined controls; live release acceptance
and the explicitly listed limits remain open.

Current `MaxRequests` counts SDK invocations, not HTTP attempts. The snapshot
metadata says this explicitly. Retry settings alone cannot turn it into a strict
HTTP-attempt budget, and a per-request timeout is not a whole-investigation
deadline. SDK redirects also happen below Handoff's next-link path/host checks.
Dropping Authorization at a foreign target does not make redirected evidence a
verified read of the intended Graph resource.

The next transport change must address these together:

1. Bound decompressed response bytes before JSON conversion, preserving the cap
   across every request and any SDK client reset. Limit settings must not
   silently alter another caller's ambient SDK session.
2. Reject redirects before following them. Checking the final URL after a
   redirect does not prevent an unintended request.
3. Apply cancellation and a total investigation deadline across authentication,
   HTTP attempts and response processing; withhold interrupted observations.
4. Exercise those controls at the **collector** boundary, including partial
   evidence retention, SDK session changes and fixed error codes. Keep original
   evidence immutable and do not extract access tokens to build another client.

The public request-context cmdlet exposes retry/timeout controls, but no
redirect or response-byte controls. The platform buffer cap is a demonstrated
building block, not a completed solution. Do not promote this report to release
approval or silently patch private middleware fields to claim the gate is closed.
Minimum reader-role and wider live failure acceptance remain separate from this
transport work.
