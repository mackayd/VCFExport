[CmdletBinding(DefaultParameterSetName = 'Live')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Live')]
    [ValidateNotNullOrEmpty()]
    [string] $SddcManager,

    [Parameter(ParameterSetName = 'Live')]
    [string] $SddcManagerAddress,

    [Parameter(Mandatory, ParameterSetName = 'Live')]
    [pscredential] $Credential,

    [Parameter(ParameterSetName = 'Live')]
    [pscredential] $VCenterCredential,

    [Parameter(ParameterSetName = 'Live')]
    [string[]] $VCenterFqdn,

    [Parameter(ParameterSetName = 'Live')]
    [hashtable] $VCenterAddressMap = @{},

    [Parameter(ParameterSetName = 'Live')]
    [ValidateSet('ONLINE', 'OFFLINE_DEPOT', 'AIR_GAPPED')]
    [string] $CollectionMode = 'AIR_GAPPED',

    [Parameter(ParameterSetName = 'Live')]
    [string] $LifecycleMetadataPath,

    [Parameter(Mandatory, ParameterSetName = 'Snapshot')]
    [ValidateNotNullOrEmpty()]
    [string] $SnapshotPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputPath,

    [ValidateSet('Json', 'Html', 'Excel', 'Csv')]
    [string[]] $OutputFormat = @('Json', 'Html', 'Excel'),

    [Parameter(ParameterSetName = 'Live')]
    [switch] $SkipCertificateCheck,

    [Parameter(ParameterSetName = 'Live')]
    [switch] $SkipVSphere,

    [Parameter(ParameterSetName = 'Live')]
    [switch] $SkipDatastoreFileScan,

    [switch] $RedactVMNames,
    [switch] $RedactFqdnDomains,
    [switch] $RedactIPAddresses,
    [switch] $RedactInfrastructureNames,
    [switch] $RedactNetworkNames,
    [switch] $RedactDatastoreNames,
    [switch] $RedactAccountNames
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleRoot = Join-Path $PSScriptRoot 'src'
Import-Module (Join-Path $moduleRoot 'Core\VcfDm.Model.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Core\VcfDm.Auth.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Core\VcfDm.Redaction.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Core\VcfDm.Status.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Collectors\VcfDm.SddcManager.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Collectors\VcfDm.Vsphere.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Lifecycle\VcfDm.OfflineMetadata.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Exporters\VcfDm.Json.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Exporters\VcfDm.Html.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Exporters\VcfDm.Excel.psm1') -Force
Import-Module (Join-Path $moduleRoot 'Exporters\VcfDm.Csv.psm1') -Force

if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
}
$resolvedOutput = (Resolve-Path -LiteralPath $OutputPath).Path

if ($PSCmdlet.ParameterSetName -eq 'Snapshot') {
    $snapshot = Import-VcfDmSnapshotJson -Path $SnapshotPath
    $htmlPath = $null
    $excelPath = $null
    $csvPath = $null
    if ($OutputFormat -contains 'Html') {
        $htmlPath = Join-Path $resolvedOutput ("VCFExport-{0}.html" -f $snapshot.SnapshotId)
        Export-VcfDmSnapshotHtml -Snapshot $snapshot -Path $htmlPath | Out-Null
    }
    if ($OutputFormat -contains 'Excel') {
        $excelPath = Join-Path $resolvedOutput ("VCFExport-{0}.xlsx" -f $snapshot.SnapshotId)
        Export-VcfDmSnapshotExcel -Snapshot $snapshot -Path $excelPath | Out-Null
    }
    if ($OutputFormat -contains 'Csv') {
        $csvPath = Join-Path $resolvedOutput ("VCFExport-{0}-csv" -f $snapshot.SnapshotId)
        Export-VcfDmSnapshotCsv -Snapshot $snapshot -Path $csvPath | Out-Null
    }
    [pscustomobject][ordered]@{
        SnapshotId = $snapshot.SnapshotId
        SchemaVersion = $snapshot.SchemaVersion
        JsonPath = (Resolve-Path -LiteralPath $SnapshotPath).Path
        HtmlPath = $htmlPath
        ExcelPath = $excelPath
        CsvPath = $csvPath
        LiveConnectionsUsed = $false
    }
    return
}

$knowledgeScope = switch ($CollectionMode) {
    'ONLINE' { 'ONLINE' }
    'OFFLINE_DEPOT' { 'OFFLINE_DEPOT' }
    default { if ($LifecycleMetadataPath) { 'AIR_GAPPED_METADATA_REFERENCE' } else { 'AIR_GAPPED_LOCAL_ONLY' } }
}
if ($LifecycleMetadataPath) { $knowledgeScope = 'AIR_GAPPED_METADATA_REFERENCE' }
$snapshot = New-VcfDmSnapshot -CollectionMode $CollectionMode -LifecycleKnowledgeScope $knowledgeScope

if ($LifecycleMetadataPath) {
    $metadataStarted = [datetime]::UtcNow
    try {
        $metadata = Read-VcfDmOfflineMetadata -Path $LifecycleMetadataPath
        foreach ($property in @($snapshot.LifecycleKnowledge.Keys)) {
            if ($metadata.PSObject.Properties[$property]) { $snapshot.LifecycleKnowledge[$property] = $metadata.$property }
        }
        foreach ($row in @($metadata.ProductCatalogRows)) {
            $row.CatalogAgeDays = $metadata.ReferenceMetadataAgeDays
            Add-VcfDmDatasetRow -Snapshot $snapshot -Dataset VCF_ProductCatalog -Row $row
        }
        $status = New-VcfDmCollectionStatus -CollectorName OfflineMetadata -SourceSystemType OFFLINE_METADATA -SourceSystemFqdn ([System.IO.Path]::GetFileName($LifecycleMetadataPath)) -StartedUTC $metadataStarted -CompletedUTC ([datetime]::UtcNow) -Status SUCCESS -RowsCollected @($metadata.ProductCatalogRows).Count -AuthenticationMode NONE -ApiVersion 'VCF 9.x metadata' -CollectorVersion $snapshot.CollectorVersion
        Add-VcfDmDatasetRow -Snapshot $snapshot -Dataset VCF_CollectionStatus -Row $status
    }
    catch {
        throw "Offline lifecycle metadata validation failed: $($_.Exception.Message)"
    }
}
else {
    $status = New-VcfDmCollectionStatus -CollectorName OfflineMetadata -SourceSystemType OFFLINE_METADATA -SourceSystemFqdn NOT_SUPPLIED -StartedUTC ([datetime]::UtcNow) -CompletedUTC ([datetime]::UtcNow) -Status NOT_SUPPLIED -RowsCollected 0 -AuthenticationMode NONE -ApiVersion 'VCF 9.x metadata' -CollectorVersion $snapshot.CollectorVersion
    Add-VcfDmDatasetRow -Snapshot $snapshot -Dataset VCF_CollectionStatus -Row $status
}

$sddcConnection = $null
try {
    $connectionTarget = if ($SddcManagerAddress) { $SddcManagerAddress } else { $SddcManager }
    $sddcConnection = Connect-VcfDmSddcManager -Server $connectionTarget -Credential $Credential -SkipCertificateCheck:$SkipCertificateCheck
    $null = Invoke-VcfDmSddcManagerCollection -Snapshot $snapshot -ServerConnection $sddcConnection -ServerFqdn $SddcManager
}
finally {
    if ($sddcConnection) { Disconnect-VcfDmSddcManager -Server $sddcConnection }
}

if (-not $SkipVSphere) {
    $vcTargets = @(if ($VCenterFqdn) { $VCenterFqdn } else { $snapshot.Datasets.VCF_vCenters | Select-Object -ExpandProperty VCenterFqdn -Unique })
    if ($vcTargets.Count) {
        $vcCredentialToUse = if ($VCenterCredential) { $VCenterCredential } else { $Credential }
        Invoke-VcfDmVsphereCollection -Snapshot $snapshot -VCenterFqdn $vcTargets -Credential $vcCredentialToUse -ServerAddressMap $VCenterAddressMap -SkipCertificateCheck:$SkipCertificateCheck -SkipDatastoreFileScan:$SkipDatastoreFileScan
    }
}

Set-VcfDmReportStatus -Snapshot $snapshot | Out-Null
if (@($snapshot.Datasets.VCF_Summary).Count) {
    $snapshot.Datasets.VCF_Summary[0].CollectionStatus = if ($snapshot.ReportStatus -eq 'REPORT COMPLETE') { 'SUCCESS' } else { 'PARTIAL' }
    $snapshot.Datasets.VCF_Summary[0].CollectionWarning = if ($snapshot.ReportStatus -eq 'REPORT COMPLETE') { $null } else { 'One or more collectors did not complete successfully; review VCF_CollectionStatus.' }
}

$redactionOptions = @{
    RedactVMNames = [bool]$RedactVMNames
    RedactFqdnDomains = [bool]$RedactFqdnDomains
    RedactIPAddresses = [bool]$RedactIPAddresses
    RedactInfrastructureNames = [bool]$RedactInfrastructureNames
    RedactNetworkNames = [bool]$RedactNetworkNames
    RedactDatastoreNames = [bool]$RedactDatastoreNames
    RedactAccountNames = [bool]$RedactAccountNames
}
if ($redactionOptions.Values -contains $true) {
    $snapshot = Invoke-VcfDmRedaction -InputObject $snapshot -Options $redactionOptions
}

$jsonPath = Join-Path $resolvedOutput ("VCFExport-{0}.json" -f $snapshot.SnapshotId)
Export-VcfDmSnapshotJson -Snapshot $snapshot -Path $jsonPath | Out-Null

# Reload is intentional: presentation exports must prove they have no dependency
# on a live API session or in-memory collector object. JSON remains the
# authoritative artifact for every live collection, regardless of selected views.
$reloadedSnapshot = Import-VcfDmSnapshotJson -Path $jsonPath
$htmlPath = $null
$excelPath = $null
$csvPath = $null
if ($OutputFormat -contains 'Html') {
    $htmlPath = Join-Path $resolvedOutput ("VCFExport-{0}.html" -f $snapshot.SnapshotId)
    Export-VcfDmSnapshotHtml -Snapshot $reloadedSnapshot -Path $htmlPath | Out-Null
}
if ($OutputFormat -contains 'Excel') {
    $excelPath = Join-Path $resolvedOutput ("VCFExport-{0}.xlsx" -f $snapshot.SnapshotId)
    Export-VcfDmSnapshotExcel -Snapshot $reloadedSnapshot -Path $excelPath | Out-Null
}

if ($OutputFormat -contains 'Csv') {
    $csvPath = Join-Path $resolvedOutput ("VCFExport-{0}-csv" -f $snapshot.SnapshotId)
    Export-VcfDmSnapshotCsv -Snapshot $reloadedSnapshot -Path $csvPath | Out-Null
}

[pscustomobject][ordered]@{
    SnapshotId = $reloadedSnapshot.SnapshotId
    SchemaVersion = $reloadedSnapshot.SchemaVersion
    CollectorVersion = $reloadedSnapshot.CollectorVersion
    ReportStatus = $reloadedSnapshot.ReportStatus
    JsonPath = $jsonPath
    HtmlPath = $htmlPath
    ExcelPath = $excelPath
    CsvPath = $csvPath
    LiveConnectionsUsed = $true
}
