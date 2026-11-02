Set-StrictMode -Version Latest

function ConvertTo-VcfDmVersionParts {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Version)

    $versionMatches = [regex]::Matches($Version, '\d+')
    if ($versionMatches.Count -eq 0) { throw "Version '$Version' does not contain numeric release components." }
    $parts = [System.Collections.Generic.List[long]]::new()
    foreach ($versionMatch in $versionMatches) { $parts.Add([long]$versionMatch.Value) }
    while ($parts.Count -lt 5) { $parts.Add(0) }
    return @($parts)
}

function Compare-VcfDmVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ReferenceVersion,
        [Parameter(Mandatory)] [string] $DifferenceVersion
    )

    $left = ConvertTo-VcfDmVersionParts -Version $ReferenceVersion
    $right = ConvertTo-VcfDmVersionParts -Version $DifferenceVersion
    $count = [math]::Max($left.Count, $right.Count)
    for ($i = 0; $i -lt $count; $i++) {
        $l = if ($i -lt $left.Count) { $left[$i] } else { 0 }
        $r = if ($i -lt $right.Count) { $right[$i] } else { 0 }
        if ($l -lt $r) { return -1 }
        if ($l -gt $r) { return 1 }
    }
    return 0
}

function Get-VcfDmLifecycleAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DeployedVersion,
        [string] $LocalCatalogLatestKnownVersion,
        [string] $ReferenceMetadataLatestKnownVersion,
        [ValidateSet('ONLINE', 'OFFLINE_DEPOT', 'AIR_GAPPED_LOCAL_ONLY', 'AIR_GAPPED_METADATA_REFERENCE')]
        [string] $LifecycleKnowledgeScope,
        [switch] $CurrentExternalSourceAuthoritative
    )

    $newerLocal = $null
    if ($LocalCatalogLatestKnownVersion) {
        $newerLocal = (Compare-VcfDmVersion -ReferenceVersion $DeployedVersion -DifferenceVersion $LocalCatalogLatestKnownVersion) -lt 0
    }
    $newerReference = $null
    if ($ReferenceMetadataLatestKnownVersion) {
        $newerReference = (Compare-VcfDmVersion -ReferenceVersion $DeployedVersion -DifferenceVersion $ReferenceMetadataLatestKnownVersion) -lt 0
    }

    $upgradeAvailable = 'UNKNOWN'
    $basis = 'NONE'
    $confidence = 'UNKNOWN'
    $state = 'LATEST_EXTERNAL_STATUS_UNKNOWN'
    if ($null -ne $newerReference -and $LifecycleKnowledgeScope -eq 'AIR_GAPPED_METADATA_REFERENCE') {
        $upgradeAvailable = if ($newerReference) { 'YES' } else { 'NO' }
        $basis = 'REFERENCE_CATALOG'
        $confidence = 'OFFICIAL_POINT_IN_TIME_REFERENCE'
        $state = if ($newerReference) { 'NEWER_RELEASE_KNOWN_REFERENCE' } else { 'LATEST_EXTERNAL_STATUS_UNKNOWN' }
    }
    elseif ($null -ne $newerLocal) {
        $upgradeAvailable = if ($newerLocal) { 'YES' } else { 'NO' }
        $basis = 'LOCAL_CATALOG'
        $confidence = 'AUTHORITATIVE_LOCAL'
        $state = if ($newerLocal) { 'NEWER_RELEASE_KNOWN_LOCAL' } else { 'NO_NEWER_RELEASE_KNOWN_LOCAL' }
    }

    return [pscustomobject][ordered]@{
        DeployedVersion                     = $DeployedVersion
        LocalCatalogLatestKnownVersion       = $LocalCatalogLatestKnownVersion
        ReferenceMetadataLatestKnownVersion  = $ReferenceMetadataLatestKnownVersion
        LifecycleKnowledgeScope              = $LifecycleKnowledgeScope
        NewerReleaseKnownLocal               = if ($null -eq $newerLocal) { 'UNKNOWN' } elseif ($newerLocal) { 'YES' } else { 'NO' }
        NewerReleaseKnownReference           = if ($null -eq $newerReference) { 'UNKNOWN' } elseif ($newerReference) { 'YES' } else { 'NO' }
        UpgradeAvailable                     = $upgradeAvailable
        UpgradeAssessmentBasis               = $basis
        AssessmentConfidence                 = $confidence
        LifecycleResult                      = $state
        BroadcomCurrentLatestStatus          = if ($CurrentExternalSourceAuthoritative) { 'KNOWN_FROM_CURRENT_AUTHORITATIVE_SOURCE' } else { 'UNKNOWN' }
        AssessmentNote                       = if ($CurrentExternalSourceAuthoritative) { 'Current external metadata was explicitly marked authoritative.' } else { 'Local or supplied point-in-time metadata does not prove Broadcom current global latest availability.' }
    }
}

function Get-VcfDmBomStatus {
    [CmdletBinding()]
    param(
        [AllowNull()] [string] $ActualVersion,
        [AllowNull()] [string] $ExpectedVersion
    )

    if (-not $ActualVersion -or -not $ExpectedVersion) { return 'UNKNOWN' }
    if ((Compare-VcfDmVersion -ReferenceVersion $ActualVersion -DifferenceVersion $ExpectedVersion) -eq 0) { return 'CURRENT_DEPLOYED_BOM' }
    return 'DRIFTED_FROM_DEPLOYED_BOM'
}

Export-ModuleMember -Function @('Compare-VcfDmVersion', 'Get-VcfDmLifecycleAssessment', 'Get-VcfDmBomStatus')
