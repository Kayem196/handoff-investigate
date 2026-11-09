param([string]$OutFile = (Join-Path $PSScriptRoot '../data/well-known-names.json'))
# Regenerates tenant-independent display names from Microsoft Learn. Run deliberately,
# review the diff, then commit. Names are presentation only; IDs stay authoritative.
$ErrorActionPreference = 'Stop'
$guid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
function Text([string]$Html) { ([Net.WebUtility]::HtmlDecode([regex]::Replace($Html, '<[^>]+>', ' ')) -replace '\s+', ' ').Trim() }
$sources = [ordered]@{
    roles = 'https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference'
    caApps = 'https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-conditional-access-cloud-apps'
    firstPartyApps = 'https://learn.microsoft.com/en-us/troubleshoot/entra/entra-id/governance/verify-first-party-apps-sign-in'
}
$roles = [ordered]@{}
$html = (Invoke-WebRequest $sources.roles -UseBasicParsing).Content
foreach ($m in [regex]::Matches($html, "<tr>\s*<td>\s*<a [^>]*>([^<]+)</a>\s*</td>\s*<td>.*?</td>\s*<td>\s*($guid)\s*</td>", 'Singleline')) {
    $roles[$m.Groups[2].Value] = Text $m.Groups[1].Value
}
$apps = [ordered]@{}
$text = Text (Invoke-WebRequest $sources.caApps -UseBasicParsing).Content
# The admin-portal list reads "Name app ID: GUID Name app ID: GUID ..."; each name runs from the previous entry.
$previous = $null
foreach ($m in [regex]::Matches($text, " app ID: ($guid)")) {
    $begin = $(if ($previous -and $m.Index - ($previous.Index + $previous.Length) -lt 120) { $previous.Index + $previous.Length } else { $text.LastIndexOf(':', $m.Index - 1) + 1 })
    $apps[$m.Groups[1].Value] = $text.Substring($begin, $m.Index - $begin).Trim()
    $previous = $m
}
foreach ($m in [regex]::Matches($text, "([A-Z][\w ]{2,60}?) \(($guid)\)")) { if (-not $apps.Contains($m.Groups[2].Value)) { $apps[$m.Groups[2].Value] = $m.Groups[1].Value.Trim() } }
$html = (Invoke-WebRequest $sources.firstPartyApps -UseBasicParsing).Content
foreach ($m in [regex]::Matches($html, '<tr>(.*?)</tr>', 'Singleline')) {
    $cells = @([regex]::Matches($m.Groups[1].Value, '<td>(.*?)</td>', 'Singleline') | ForEach-Object { Text $_.Groups[1].Value })
    if ($cells.Count -ge 2 -and $cells[1] -match "^$guid$") { $apps[$cells[1]] = $cells[0] }
}
if ($roles.Count -lt 100 -or $roles['62e90394-69f5-4237-9190-012177145e10'] -cne 'Global Administrator' -or $apps.Count -lt 5) { throw 'Unexpected Microsoft Learn format; nothing written.' }
[ordered]@{
    schemaVersion = 1; generatedAt = [datetimeoffset]::UtcNow.ToString('o'); sources = $sources
    note = 'Built-in role template IDs and first-party application IDs are identical in every tenant. Custom roles and other apps are not covered.'
    roles = $roles; applications = $apps
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutFile -Encoding utf8
[pscustomobject]@{ Roles = $roles.Count; Applications = $apps.Count; OutFile = (Resolve-Path $OutFile).Path }
