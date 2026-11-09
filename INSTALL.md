# Install and set up Handoff investigation (preview)

Version 0.1.0-preview1. This is a read-only tool for one tenant at a time. It
answers which Conditional Access and Intune device-compliance policies
explicitly reference a group. It never changes your tenant.

## Supported combination

| Component | Requirement |
| --- | --- |
| OS | Windows 11 (tested build 10.0.26300, x64) |
| PowerShell | 7.5 or later; tested with **7.6.9** |
| Live collection only | `Microsoft.Graph.Authentication` **exactly 2.38.1**; other versions are refused |
| Licensing for live reads | Entra ID P1 (Conditional Access) and an active Intune licence |

Offline use needs no Graph SDK, network access, login, server or AI. That
covers evaluating supplied snapshots, saved investigations, notes, comparisons
and reports. Collection compiles one bundled C# file with `Add-Type`.
Environments that block `Add-Type`, such as Constrained Language Mode, are not
supported yet.

## 1. Install the module

Get the package folder, then check every file against `SHA256SUMS.txt`, from the
folder that contains both `Handoff/` and `SHA256SUMS.txt`:

```powershell
Get-Content ./SHA256SUMS.txt | ForEach-Object {
    $hash, $file = $_ -split '  ', 2
    if ((Get-FileHash "./Handoff/0.1.0/$file").Hash -ne $hash) { throw "Checksum mismatch: $file" }
}
```

Copy `Handoff/0.1.0` to your user module directory:

```powershell
$modules = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell/Modules'
Copy-Item ./Handoff -Destination $modules -Recurse
Import-Module Handoff
Get-Command -Module Handoff
```

Try the fictional example (no tenant access):

```powershell
$base = (Get-Module Handoff).ModuleBase
& "$base/examples/export-investigation.ps1" -OutDirectory (Join-Path $env:TEMP ('handoff-demo-' + [guid]::NewGuid()))
```

For live collection, install the pinned authentication module:

```powershell
Install-Module Microsoft.Graph.Authentication -RequiredVersion 2.38.1 -Scope CurrentUser
```

## 2. Create a dedicated reader registration (one time, per tenant)

Use a tenant-owned app registration only for this tool. Do not reuse other
applications' registrations. An administrator who is allowed to create
registrations and grant consent does this in the Entra admin center:

1. **App registrations → New registration.** Use a clear name, for example
   *Handoff Investigation Reader*. Choose **Single tenant**. Leave the redirect
   URI empty for now.
2. **Authentication → Add a platform → Mobile and desktop applications.** Add
   `http://localhost`. To use Windows' sign-in broker, also add
   `ms-appx-web://Microsoft.AAD.BrokerPlugin/<application-client-id>`. Set
   **Allow public client flows** to **Yes**, which device-code sign-in needs.
3. **API permissions → Microsoft Graph → Delegated.** Add exactly
   `GroupMember.Read.All`, `Policy.Read.All` and
   `DeviceManagementConfiguration.Read.All`. Remove `User.Read` if you don't
   need it. Add no application permissions, secrets or certificates.
4. **Consent.** These scopes need administrator consent. Grant it, then check
   which grants actually exist under
   **Enterprise applications → (the app) → Permissions**.
   The tested setup used a grant for one operator only. A tenant-wide grant is
   broader than that; choose it deliberately.

Record the tenant ID, application (client) ID and the operator's account in
your private notes. Delegated access is limited to what the signed-in operator
can see: their Entra roles, plus Intune RBAC scope tags and scope groups. The
tested operator was a Global Administrator. Minimum reader roles have not been
established.

To remove access later, delete the registration, or remove its consent grants.
Signing out of PowerShell does not revoke consent.

## 3. Run an investigation

Use a new `pwsh -NoProfile` window for each investigation:

```powershell
Import-Module Microsoft.Graph.Authentication -RequiredVersion 2.38.1
Connect-MgGraph -TenantId $tenantId -ClientId $clientId -ContextScope Process -NoWelcome `
    -Scopes GroupMember.Read.All, Policy.Read.All, DeviceManagementConfiguration.Read.All
Import-Module Handoff
Start-HandoffGroupInvestigation -TenantId $tenantId -ClientId $clientId -Account $account `
    -OutDirectory (Join-Path $env:LOCALAPPDATA ('Handoff/Investigations/' + [guid]::NewGuid()))
```

Add `-UseDeviceAuthentication` to `Connect-MgGraph` if a browser sign-in isn't
available. If Microsoft asks for new consent or shows an unexpected app,
tenant or account, stop. The guide also refuses a session with extra API scopes.
Close the window when finished.

Outputs are local plaintext evidence and reports. Keep them out of Git and
sync folders, and review them before sharing. Results cover only explicit
references in visible policies. They are not proof that a group is unused or
safe to delete; follow each report's manual checks.

## Optional: AI explanations (Axon)

Axon is optional, and Handoff is complete without it. To use it, bring your own
API key for Anthropic (recommended), OpenAI or an Azure OpenAI deployment.
Preview what would be sent with `-PreviewOnly`. Nothing is sent until you type
`SHARE`. See [Optional Axon explanations](docs/DEVELOPMENT.md#optional-axon-explanations)
for exactly what is shared and how failures are reported. Anthropic and OpenAI have been verified
live with fictional data; Azure OpenAI has not.

## Verified and not yet verified

The package build, checksums, an isolated module-path import, offline commands
and the packaged example have been checked on the development Windows machine.
Live reads have been accepted in one test tenant. Still unverified:

- a genuinely clean second machine or user profile
- other Windows and PowerShell versions
- PowerShell Gallery publication
- signed scripts and AllSigned execution policy
- proxies
- readers with fewer rights than Global Administrator
- large or multipage tenants
