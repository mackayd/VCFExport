Set-StrictMode -Version Latest

$script:SchemaVersion = '1.1'
$script:CollectorVersion = '0.1.0'

$script:P0DatasetNames = @(
    'VCF_Summary',
    'VCF_Instances',
    'VCF_Domains',
    'VCF_Clusters',
    'VCF_Hosts',
    'VCF_vCenters',
    'VCF_SDDCManagers',
    'VCF_ManagementComponents',
    'VCF_Endpoints',
    'VCF_NetworkPools',
    'VCF_NSXClusters',
    'VCF_EdgeClusters',
    'VCF_Lifecycle',
    'VCF_BOM',
    'VCF_UpgradePaths',
    'VCF_ProductCatalog',
    'VCF_Depot',
    'VCF_ComponentDrift',
    'VCF_Certificates',
    'VCF_CredentialHealth',
    'VCF_Licensing',
    'VCF_Backups',
    'VCF_Compliance',
    'VCF_FIPS',
    'VCF_CollectionStatus'
)

$script:VSphereDatasetNames = @(
    'vInfo', 'vCPU', 'vMemory', 'vDisk', 'vPartition', 'vSCSI', 'vNetwork',
    'vFloppy', 'vCD', 'vSnapshot', 'vTools', 'vResourcePools', 'vCluster',
    'vHost', 'vTLShosts', 'vHBA', 'vNIC', 'vSwitch', 'vPort', 'dvSwitches',
    'dvPorts', 'vSC_VMK', 'vDatastore', 'vZombie', 'Licensing', 'Health'
)

$script:InventoryDatasetNames = @(
    'vInfo','vCPU','vMemory','vDisk','vPartition','vSCSI','vNetwork','vFloppy','vCD',
    'vSnapshot','vTools','vRP','vCluster','vHost','vTLShost','vHBA','vNIC','vSwitch',
    'vPort','dvSwitch','dvPort','vSC_VMK','vDatastore','vZombieFiles','vLicense','vHealth'
)

function Get-VcfDmSchemaVersion {
    [CmdletBinding()]
    param()
    return $script:SchemaVersion
}

function Get-VcfDmCollectorVersion {
    [CmdletBinding()]
    param()
    return $script:CollectorVersion
}

function Get-VcfDmDatasetNames {
    [CmdletBinding()]
    param(
        [switch] $VSphere,
        [switch] $Inventory
    )

    if ($Inventory) { return @($script:InventoryDatasetNames) }
    if ($VSphere) {
        return @($script:VSphereDatasetNames)
    }
    return @($script:P0DatasetNames)
}

function New-VcfDmSnapshot {
    [CmdletBinding()]
    param(
        [ValidateSet('ONLINE', 'OFFLINE_DEPOT', 'AIR_GAPPED')]
        [string] $CollectionMode = 'AIR_GAPPED',

        [ValidateSet('ONLINE', 'OFFLINE_DEPOT', 'AIR_GAPPED_LOCAL_ONLY', 'AIR_GAPPED_METADATA_REFERENCE')]
        [string] $LifecycleKnowledgeScope = 'AIR_GAPPED_LOCAL_ONLY',

        [datetime] $CollectedUTC = [datetime]::UtcNow,

        [string] $SnapshotId = [guid]::NewGuid().Guid
    )

    $datasets = [ordered]@{}
    foreach ($name in $script:P0DatasetNames) {
        $datasets[$name] = @()
    }

    $vsphere = [ordered]@{}
    foreach ($name in $script:VSphereDatasetNames) {
        $vsphere[$name] = @()
    }

    $detailed = [ordered]@{}
    foreach ($name in $script:InventoryDatasetNames) { $detailed[$name] = @() }

    return [ordered]@{
        SchemaVersion            = $script:SchemaVersion
        SnapshotId               = $SnapshotId
        CollectorVersion         = $script:CollectorVersion
        CollectedUTC             = $CollectedUTC.ToUniversalTime().ToString('o')
        CollectionMode           = $CollectionMode
        LifecycleKnowledgeScope  = $LifecycleKnowledgeScope
        ReportStatus             = 'REPORT PARTIALLY COMPLETE'
        Sources                  = @()
        LifecycleKnowledge       = [ordered]@{
            DeployedVersion                     = $null
            LocalCatalogLatestKnownVersion       = $null
            LocalCatalogPublishedUTC             = $null
            LocalCatalogAgeDays                  = $null
            DepotSyncStatus                      = $null
            DepotLastSyncUTC                     = $null
            ReferenceMetadataLatestKnownVersion  = $null
            BroadcomCurrentLatestStatus           = 'UNKNOWN'
            ReferenceMetadataSourceType           = $null
            ReferenceMetadataFileName             = $null
            ReferenceMetadataArchiveSha256        = $null
            ReferenceMetadataCreationUTC          = $null
            ReferenceMetadataPublishedUTC         = $null
            ReferenceMetadataAgeDays              = $null
            ReferenceProductCatalogVersion        = $null
            ReferenceProductCatalogSequence       = $null
            ReferenceSignaturePresent             = $false
            ReferenceSignatureValidationStatus    = 'NOT_PRESENT'
        }
        Datasets                 = $datasets
        VSphere                  = $vsphere
        Inventory                  = $detailed
        InventoryCollection      = [ordered]@{ Mode = 'NATIVE'; CategoryCount = $script:InventoryDatasetNames.Count }
    }
}

function Get-VcfDmObjectId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VCFInstanceId,
        [string] $SourceSystemId,
        [Parameter(Mandatory)] [string] $SourceSystemFqdn,
        [Parameter(Mandatory)] [string] $ObjectType,
        [string] $NativeObjectId,
        [string] $ObjectName
    )

    $source = if ([string]::IsNullOrWhiteSpace($SourceSystemId)) { $SourceSystemFqdn } else { $SourceSystemId }
    $native = if ([string]::IsNullOrWhiteSpace($NativeObjectId)) { $ObjectName } else { $NativeObjectId }
    if ([string]::IsNullOrWhiteSpace($native)) {
        throw 'NativeObjectId or ObjectName is required to construct a stable identity.'
    }

    $canonical = @($VCFInstanceId, $source, $ObjectType, $native) |
        ForEach-Object { ([string]$_).Trim().ToLowerInvariant() }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($canonical -join '|'))
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    $shortHash = ([Convert]::ToHexString($hash)).Substring(0, 24).ToLowerInvariant()
    return "urn:vcfdm:$($ObjectType.ToLowerInvariant()):$shortHash"
}

function Copy-VcfDmRecordMap {
    param($Record)
    $copy = [ordered]@{}
    if ($Record -is [System.Collections.IDictionary]) {
        foreach ($key in $Record.Keys) { $copy[$key] = $Record[$key] }
    } elseif ($null -ne $Record) {
        foreach ($property in $Record.PSObject.Properties) { $copy[$property.Name] = $property.Value }
    }
    return $copy
}

function ConvertTo-VcfDmCurrentSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Snapshot)

    # Import older captures without modifying the source object or source file.
    $current = Copy-VcfDmRecordMap $Snapshot
    if (-not $current.Contains('SchemaVersion') -or -not $current.Contains('SnapshotId') -or -not $current.Contains('Datasets')) {
        throw 'The supplied object is not a supported VCFExport snapshot.'
    }
    if ([string]$current.SchemaVersion -notin @('1.0', '1.1')) {
        throw "Unsupported VCFExport schema version '$($current.SchemaVersion)'."
    }
    $hasPreviousContainer = $current.Contains('DMTools')
    if ($current.Contains('Inventory') -and -not $hasPreviousContainer) {
        $current.SchemaVersion = $script:SchemaVersion
        return $current
    }

    $inventory = if ($current.Contains('Inventory')) { Copy-VcfDmRecordMap $current.Inventory } else { [ordered]@{} }
    $previous = if ($hasPreviousContainer) { Copy-VcfDmRecordMap $current['DMTools'] } else { [ordered]@{} }
    $names = @($script:InventoryDatasetNames) + @($inventory.Keys) + @($previous.Keys) | Select-Object -Unique
    foreach ($name in $names) {
        $records = [System.Collections.Generic.List[object]]::new()
        foreach ($row in @($inventory[$name]) + @($previous[$name])) {
            if ($null -eq $row) { continue }
            $record = Copy-VcfDmRecordMap $row
            foreach ($mapping in @(@('DMtoolsDataset','InventoryDataset'), @('DMtoolsRowId','InventoryRowId'))) {
                if ($record.Contains($mapping[0])) {
                    if (-not $record.Contains($mapping[1])) { $record[$mapping[1]] = $record[$mapping[0]] }
                    $record.Remove($mapping[0])
                }
            }
            if ($record.Contains('InventoryRowId')) { $record.InventoryRowId = [string]$record.InventoryRowId -replace ':dmtools_row:', ':inventory_row:' }
            $records.Add([pscustomobject]$record)
        }
        $inventory[$name] = @($records.ToArray())
    }
    $current.Inventory = $inventory
    $current.Remove('DMTools')
    $current.Remove('DMToolsProvenance')
    if (-not $current.Contains('InventoryCollection')) {
        $current.InventoryCollection = [ordered]@{ Mode = 'IMPORTED'; CategoryCount = $script:InventoryDatasetNames.Count }
    }
    $datasets = Copy-VcfDmRecordMap $current.Datasets
    if ($datasets.Contains('VCF_CollectionStatus')) {
        $datasets.VCF_CollectionStatus = @(foreach ($status in $datasets.VCF_CollectionStatus) {
            $record = Copy-VcfDmRecordMap $status
            if ($record.Contains('CollectorName')) { $record.CollectorName = [string]$record.CollectorName -replace '^(Synthetic\.)?DMtools\.', 'Inventory.' }
            if ($record.Contains('ApiVersion')) { $record.ApiVersion = [string]$record.ApiVersion -replace ' / DMtools beta', '' }
            [pscustomobject]$record
        })
    }
    $current.Datasets = $datasets
    $current.SchemaVersion = $script:SchemaVersion
    return $current
}

function Add-VcfDmDatasetRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Snapshot,
        [Parameter(Mandatory)] [string] $Dataset,
        [Parameter(Mandatory)] $Row,
        [switch] $VSphere,
        [switch] $Inventory
    )

    $containerName = if ($Inventory) { 'Inventory' } elseif ($VSphere) { 'VSphere' } else { 'Datasets' }
    $container = $Snapshot[$containerName]
    if (-not $container.Contains($Dataset)) {
        throw "Unknown $containerName dataset '$Dataset'."
    }
    $container[$Dataset] = @($container[$Dataset]) + @($Row)
}

function Set-VcfDmReportStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Snapshot
    )

    $statuses = @($Snapshot.Datasets.VCF_CollectionStatus)
    $badStates = @('PARTIAL', 'NOT_AUTHORIZED', 'UNREACHABLE', 'COLLECTION_FAILED')
    $coreNames = @('SDDCManager.System', 'SDDCManager.Domains', 'SDDCManager.Clusters', 'SDDCManager.Hosts', 'SDDCManager.vCenters')
    $core = @($statuses | Where-Object { $_.CollectorName -in $coreNames })
    $hasCoreFailure = @($core | Where-Object { $_.Status -in $badStates }).Count -gt 0
    $hasCollectionFailure = @($statuses | Where-Object { $_.Status -in $badStates }).Count -gt 0
    $missingCore = $core.Count -lt $coreNames.Count
    $Snapshot.ReportStatus = if ($hasCoreFailure -or $hasCollectionFailure -or $missingCore) { 'REPORT PARTIALLY COMPLETE' } else { 'REPORT COMPLETE' }
    return $Snapshot.ReportStatus
}

Export-ModuleMember -Function @(
    'Get-VcfDmSchemaVersion',
    'Get-VcfDmCollectorVersion',
    'Get-VcfDmDatasetNames',
    'New-VcfDmSnapshot',
    'ConvertTo-VcfDmCurrentSnapshot',
    'Get-VcfDmObjectId',
    'Add-VcfDmDatasetRow',
    'Set-VcfDmReportStatus'
)
