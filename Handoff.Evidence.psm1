#Requires -Version 7.5
# Local, append-only JSON evidence. No SDK, network, login or tenant writes.
Import-Module (Join-Path $PSScriptRoot 'Handoff.Investigation.psm1') -Scope Local
$script:MaxRecordBytes = 16MB
$script:MaxInvestigationBytes = 64MB

function Resolve-HandoffEvidencePath {
    param([string]$Path)
    $provider = $null
    $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
    if ($provider.Name -cne 'FileSystem') { throw 'Investigation paths must use the filesystem provider.' }
    return $resolved
}

function ConvertTo-HandoffCanonicalJson {
    param($Value)
    if ($Value -is [pscustomobject]) {
        $properties = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $properties[$property.Name] = $property.Value }
        return ConvertTo-HandoffCanonicalJson $properties
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $keys = [string[]]@($Value.Keys)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        $parts = foreach ($key in $keys) { ($key | ConvertTo-Json -Compress) + ':' + (ConvertTo-HandoffCanonicalJson $Value[$key]) }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [array]) {
        $parts = foreach ($item in $Value) { ConvertTo-HandoffCanonicalJson $item }
        return '[' + ($parts -join ',') + ']'
    }
    return ConvertTo-Json -InputObject $Value -Depth 64 -Compress -WarningAction Stop
}

function Write-HandoffEvidenceRecord {
    param([string]$Directory, [string]$Name, [System.Collections.IDictionary]$Record)
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $content = ConvertTo-Json -InputObject $Record -Depth 64 -Compress -WarningAction Stop -ErrorAction Stop
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($content)))
    $envelope = @{schemaVersion=1; sha256=$digest; content=$content} | ConvertTo-Json -Compress -Depth 4
    $bytes = $utf8.GetBytes($envelope)
    if ($bytes.Length -gt $script:MaxRecordBytes) { throw 'Evidence record exceeds the 16 MiB local storage limit.' }
    $temporary = Join-Path $Directory ('.handoff-staging-' + [guid]::NewGuid().ToString('D') + '.tmp')
    $created = $false
    $lock = $null
    try {
        $lockPath = Join-Path $Directory '.handoff-write.lock'
        if ((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Investigation lock must not be a link.' }
        # A persistent lock file is harmless after a crash; only the open handle locks it.
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $files = @(Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File -Force)
        if ($files.Count -ge 1000 -or (($files | Measure-Object Length -Sum).Sum + $bytes.Length) -gt $script:MaxInvestigationBytes) { throw 'Appending would exceed the investigation storage limit.' }
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $created = $true
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        # Same-directory rename publishes a complete record and never replaces evidence.
        [IO.File]::Move($temporary, (Join-Path $Directory $Name))
    } finally {
        if ($created -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        if ($lock) { $lock.Dispose() }
    }
}

function Read-HandoffEvidenceRecord {
    param([string]$File)
    $item = Get-Item -LiteralPath $File -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Evidence records must be ordinary files, not links.' }
    $stream = [IO.File]::Open($File, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -le 0 -or $stream.Length -gt $script:MaxRecordBytes) { throw 'Invalid evidence record size.' }
        $bytes = [byte[]]::new([int]$stream.Length)
        $stream.ReadExactly($bytes, 0, $bytes.Length)
        if ($stream.ReadByte() -ne -1) { throw 'Evidence record changed during reading.' }
    } finally { $stream.Dispose() }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $envelope = ConvertFrom-Json -InputObject $utf8.GetString($bytes) -AsHashtable -DateKind String -Depth 4 -ErrorAction Stop
    if ($envelope -isnot [System.Collections.IDictionary] -or $envelope.schemaVersion -ne 1 -or $envelope.content -isnot [string]) { throw 'Invalid evidence envelope.' }
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($envelope.content)))
    if ($digest -cne $envelope.sha256) { throw 'Evidence checksum mismatch; preserve the file and investigate.' }
    $record = ConvertFrom-Json -InputObject $envelope.content -AsHashtable -DateKind String -Depth 64 -ErrorAction Stop
    $id = [guid]::Empty
    $savedAt = [datetimeoffset]::MinValue
    if ($record -isnot [System.Collections.IDictionary] -or $record.schemaVersion -ne 1 -or
        -not [guid]::TryParse([string]$record.id, [ref]$id) -or $id -eq [guid]::Empty -or
        -not [datetimeoffset]::TryParseExact([string]$record.savedAt, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$savedAt)) { throw 'Invalid evidence record metadata.' }
    return $record
}

function Get-HandoffSavedEvaluation {
    param([guid]$TenantId, [guid]$GroupId, [System.Collections.IDictionary]$Snapshot)
    foreach ($key in $Snapshot.Keys) {
        if ($key -cnotin @('schemaVersion','tenantId','groupId','group','collectedAt','collection','conditionalAccess','compliance')) { throw 'Only a policy snapshot may be saved, not authentication or arbitrary session data.' }
    }
    foreach ($candidate in @($Snapshot.groupId, $Snapshot.group.id)) {
        if ($null -ne $candidate) {
            $id = [guid]::Empty
            if (-not [guid]::TryParse([string]$candidate, [ref]$id) -or $id -ne $GroupId) { throw 'Snapshot group binding does not match the investigation.' }
        }
    }
    return Get-HandoffGroupPolicyReference -TenantId $TenantId -GroupId $GroupId -Snapshot $Snapshot
}

function Get-HandoffInvestigation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][guid]$GroupId
    )
    if ($TenantId -eq [guid]::Empty -or $GroupId -eq [guid]::Empty) { throw 'Nonempty tenant and group IDs are required.' }
    $directory = Get-Item -LiteralPath (Resolve-HandoffEvidencePath $Path) -Force -ErrorAction Stop
    if (-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Choose an ordinary local investigation directory.' }
    $manifest = Read-HandoffEvidenceRecord (Join-Path $directory.FullName 'investigation.json')
    if ($manifest.kind -cne 'investigation' -or $manifest.tenantId -cne $TenantId.ToString() -or $manifest.groupId -cne $GroupId.ToString()) { throw 'Investigation identity does not match the selected tenant and group.' }
    $files = @(Get-ChildItem -LiteralPath $directory.FullName -Filter '*.json' -File -Force)
    if ($files.Count -gt 1000 -or ($files | Measure-Object Length -Sum).Sum -gt $script:MaxInvestigationBytes) { throw 'Investigation exceeds the local read limit (1,000 records or 64 MiB).' }
    $observations = [Collections.Generic.List[object]]::new()
    $notes = [Collections.Generic.List[object]]::new()
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($file in $files) {
        if ($file.Name -ceq 'investigation.json') { continue }
        $record = Read-HandoffEvidenceRecord $file.FullName
        if ($record.kind -cnotin @('observation','note') -or $file.Name -cne ($record.kind + '-' + $record.id + '.json') -or
            $record.investigationId -cne $manifest.id -or $record.tenantId -cne $manifest.tenantId -or $record.groupId -cne $manifest.groupId -or
            -not $ids.Add($record.id)) { throw 'Invalid, duplicated or foreign investigation record.' }
        if ($record.kind -ceq 'observation') {
            if ($record.evaluator -cne 'group_policy_reference_v1' -or $record.snapshot -isnot [System.Collections.IDictionary]) { throw 'Unsupported saved observation.' }
            $evaluated = Get-HandoffSavedEvaluation -TenantId $TenantId -GroupId $GroupId -Snapshot $record.snapshot
            if ((ConvertTo-HandoffCanonicalJson $evaluated) -cne (ConvertTo-HandoffCanonicalJson $record.evaluation)) { throw 'Saved evaluation does not match its original snapshot and evaluator version.' }
            $observations.Add($record)
        } else {
            if ($record.text -isnot [string] -or [string]::IsNullOrWhiteSpace($record.text) -or $record.text.Length -gt 16000) { throw 'Invalid saved note.' }
            $notes.Add($record)
        }
    }
    foreach ($note in $notes) {
        if (@($observations | Where-Object id -CEQ $note.observationId).Count -ne 1) { throw 'A note refers to a missing observation.' }
    }
    return [pscustomobject]@{
        schemaVersion=1; investigationId=$manifest.id; tenantId=$manifest.tenantId; groupId=$manifest.groupId
        observations=@($observations | Sort-Object savedAt,id); notes=@($notes | Sort-Object savedAt,id)
    }
}

function Save-HandoffInvestigationObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][guid]$GroupId,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot
    )
    # Evaluate the exact JSON data we will retain, not mutable caller-specific types.
    $json = ConvertTo-Json -InputObject $Snapshot -Depth 64 -Compress -WarningAction Stop -ErrorAction Stop
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $script:MaxRecordBytes) { throw 'Snapshot exceeds the local record size limit.' }
    $savedSnapshot = ConvertFrom-Json -InputObject $json -AsHashtable -DateKind String -Depth 64 -ErrorAction Stop
    $evaluation = Get-HandoffSavedEvaluation -TenantId $TenantId -GroupId $GroupId -Snapshot $savedSnapshot
    $fullPath = Resolve-HandoffEvidencePath $Path
    $null = [IO.Directory]::CreateDirectory($fullPath)
    if ((Get-Item -LiteralPath $fullPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Choose an ordinary local investigation directory.' }
    $manifestPath = Join-Path $fullPath 'investigation.json'
    if (-not [IO.File]::Exists($manifestPath)) {
        if (@(Get-ChildItem -LiteralPath $fullPath -Force | Where-Object Name -CNE '.handoff-write.lock').Count) { throw 'A new investigation needs an empty directory.' }
        $manifest = @{schemaVersion=1;kind='investigation';id=[guid]::NewGuid().ToString('D');tenantId=$TenantId.ToString();groupId=$GroupId.ToString();savedAt=[datetimeoffset]::UtcNow.ToString('o')}
        try { Write-HandoffEvidenceRecord $fullPath 'investigation.json' $manifest }
        catch { if (-not [IO.File]::Exists($manifestPath)) { throw } } # Another creator may have published the manifest first.
    }
    $existing = Get-HandoffInvestigation -Path $fullPath -TenantId $TenantId -GroupId $GroupId
    $record = @{schemaVersion=1;kind='observation';id=[guid]::NewGuid().ToString('D');investigationId=$existing.investigationId
        tenantId=$TenantId.ToString();groupId=$GroupId.ToString();savedAt=[datetimeoffset]::UtcNow.ToString('o')
        evaluator='group_policy_reference_v1';snapshot=$savedSnapshot;evaluation=$evaluation}
    Write-HandoffEvidenceRecord $fullPath ('observation-' + $record.id + '.json') $record
    return [pscustomobject]$record
}

function Add-HandoffInvestigationNote {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][guid]$GroupId,
        [Parameter(Mandatory)][guid]$ObservationId,
        [Parameter(Mandatory)][ValidateLength(1,16000)][string]$Text
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'A note must contain text.' }
    $existing = Get-HandoffInvestigation -Path $Path -TenantId $TenantId -GroupId $GroupId
    if (@($existing.observations | Where-Object id -CEQ $ObservationId.ToString()).Count -ne 1) { throw 'Choose an observation in this investigation.' }
    $record = @{schemaVersion=1;kind='note';id=[guid]::NewGuid().ToString('D');investigationId=$existing.investigationId
        tenantId=$TenantId.ToString();groupId=$GroupId.ToString();savedAt=[datetimeoffset]::UtcNow.ToString('o');observationId=$ObservationId.ToString();text=$Text}
    Write-HandoffEvidenceRecord (Resolve-HandoffEvidencePath $Path) ('note-' + $record.id + '.json') $record
    return [pscustomobject]$record
}

function Get-HandoffReferenceMap {
    param($References)
    $map = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($reference in $References) {
        $key = ConvertTo-Json -InputObject @($reference.source,$reference.policyId,$reference.relation,$reference.sourcePath,$reference.assignmentId) -Compress
        if (-not $map.TryAdd($key, $reference)) { throw 'Duplicate reference identities prevent an unambiguous comparison.' }
    }
    return ,$map
}

function Compare-HandoffInvestigationObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][guid]$GroupId,
        [Parameter(Mandatory)][guid]$EarlierObservationId,
        [Parameter(Mandatory)][guid]$LaterObservationId
    )
    $investigation = Get-HandoffInvestigation -Path $Path -TenantId $TenantId -GroupId $GroupId
    $earlier = @($investigation.observations | Where-Object id -CEQ $EarlierObservationId.ToString())
    $later = @($investigation.observations | Where-Object id -CEQ $LaterObservationId.ToString())
    if ($earlier.Count -ne 1 -or $later.Count -ne 1 -or $EarlierObservationId -eq $LaterObservationId -or
        [datetimeoffset]::Parse($earlier[0].evaluation.collectedAt) -gt [datetimeoffset]::Parse($later[0].evaluation.collectedAt)) { throw 'Choose distinct observations in collection-time order from this investigation.' }
    $before = Get-HandoffReferenceMap $earlier[0].evaluation.references
    $after = Get-HandoffReferenceMap $later[0].evaluation.references
    $new = [Collections.Generic.List[object]]::new()
    $missing = [Collections.Generic.List[object]]::new()
    $changed = [Collections.Generic.List[object]]::new()
    foreach ($key in $after.Keys) {
        if (-not $before.ContainsKey($key)) { $new.Add($after[$key]) }
        elseif ((ConvertTo-HandoffCanonicalJson $before[$key]) -cne (ConvertTo-HandoffCanonicalJson $after[$key])) { $changed.Add(@{before=$before[$key];after=$after[$key]}) }
    }
    foreach ($key in $before.Keys) { if (-not $after.ContainsKey($key)) { $missing.Add($before[$key]) } }
    $policyChanges = [Collections.Generic.List[object]]::new()
    foreach ($source in @('conditionalAccess','compliance')) {
        $maps = @()
        foreach ($observation in @($earlier[0],$later[0])) {
            $map = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
            foreach ($policy in $observation.snapshot[$source].policies) {
                $id = [guid]::Empty
                if ([guid]::TryParse([string]$policy.id, [ref]$id) -and $id -ne [guid]::Empty) {
                    $configuration = [ordered]@{}
                    foreach ($key in $policy.Keys) {
                        if ($key -cnotin @('assignmentsStatus','assignmentsCollection')) { $configuration[$key] = $policy[$key] }
                    }
                    if (-not $map.TryAdd($id.ToString(), $configuration)) { throw 'Duplicate policy identities prevent an unambiguous comparison.' }
                }
            }
            $maps += ,$map
        }
        $relevantIds = @(@($before.Values) + @($after.Values) | Where-Object source -CEQ $source | ForEach-Object policyId | Sort-Object -Unique)
        foreach ($id in $relevantIds) {
            $old = $(if ($maps[0].ContainsKey($id)) { $maps[0][$id] } else { $null })
            $current = $(if ($maps[1].ContainsKey($id)) { $maps[1][$id] } else { $null })
            if ((ConvertTo-HandoffCanonicalJson $old) -cne (ConvertTo-HandoffCanonicalJson $current)) {
                $keys = @(if ($old) { $old.Keys }) + @(if ($current) { $current.Keys })
                $fields = @($keys | Sort-Object -Unique -CaseSensitive | Where-Object {
                    $null -eq $old -or $null -eq $current -or -not $old.Contains($_) -or -not $current.Contains($_) -or
                        (ConvertTo-HandoffCanonicalJson $old[$_]) -cne (ConvertTo-HandoffCanonicalJson $current[$_])
                })
                $policyChanges.Add(@{source=$source;policyId=$id;changedFields=$fields;before=$old;after=$current})
            }
        }
    }
    return [pscustomobject]@{
        claim='differences_between_observations_only';earlierObservationId=$EarlierObservationId.ToString();laterObservationId=$LaterObservationId.ToString()
        earlierCollectedAt=$earlier[0].evaluation.collectedAt;laterCollectedAt=$later[0].evaluation.collectedAt
        coverageBefore=$earlier[0].evaluation.coverage;coverageAfter=$later[0].evaluation.coverage
        newlyObserved=$new.ToArray();notObservedLater=$missing.ToArray();changedReferences=$changed.ToArray();policyChanges=$policyChanges.ToArray()
        summary=('Newly observed references: {0}; not observed later: {1}; changed references: {2}; differing referenced policies: {3}.' -f $new.Count,$missing.Count,$changed.Count,$policyChanges.Count)
        verification='These are observed differences, not proof of creation, deletion, effective access or safe group removal. Check source coverage, reader visibility and original policies.'
    }
}

Export-ModuleMember -Function Save-HandoffInvestigationObservation,Get-HandoffInvestigation,Add-HandoffInvestigationNote,Compare-HandoffInvestigationObservation
