Set-StrictMode -Version Latest

$securityModule = Join-Path (Split-Path $PSScriptRoot -Parent) 'Core\VcfDm.Security.psm1'
Import-Module $securityModule -ErrorAction Stop
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Core\VcfDm.Model.psm1') -ErrorAction Stop

$script:P0SheetOrder = @(
    'VCF_Summary', 'VCF_Instances', 'VCF_Domains', 'VCF_Lifecycle', 'VCF_BOM',
    'VCF_UpgradePaths', 'VCF_ComponentDrift', 'VCF_ProductCatalog', 'VCF_Depot',
    'VCF_ManagementComponents', 'VCF_SDDCManagers', 'VCF_vCenters', 'VCF_Clusters',
    'VCF_Hosts', 'VCF_Endpoints', 'VCF_NetworkPools', 'VCF_NSXClusters',
    'VCF_EdgeClusters', 'VCF_Certificates', 'VCF_CredentialHealth', 'VCF_Licensing',
    'VCF_Backups', 'VCF_Compliance', 'VCF_FIPS', 'VCF_CollectionStatus'
)

function Get-VcfDmContainerValue {
    param($Container, [string] $Name)
    if ($Container -is [System.Collections.IDictionary]) { return $Container[$Name] }
    return $Container.PSObject.Properties[$Name].Value
}

function Export-VcfDmSnapshotExcel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Snapshot,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Path
    )

    Import-Module ImportExcel -MinimumVersion 7.8.0 -ErrorAction Stop
    $safeSnapshot = Remove-VcfDmSecretFields -InputObject (ConvertTo-VcfDmCurrentSnapshot $Snapshot)
    $serializedSafetyCheck = $safeSnapshot | ConvertTo-Json -Depth 100 -Compress
    if (Test-VcfDmForbiddenContent -Text $serializedSafetyCheck) {
        throw 'Excel export was blocked because forbidden secret test content was detected.'
    }
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }

    $datasets = Get-VcfDmContainerValue -Container $safeSnapshot -Name 'Datasets'
    $vsphere = Get-VcfDmContainerValue -Container $safeSnapshot -Name 'VSphere'
    $detailed = if ($safeSnapshot.Contains('Inventory')) { $safeSnapshot['Inventory'] } else { $null }
    $sheetNames = @($script:P0SheetOrder)
    if ($vsphere) {
        $sheetNames += @($vsphere.Keys)
    }
    if ($detailed) { $sheetNames += @($detailed.Keys | ForEach-Object { 'INV_' + $_ }) }

    $first = $true
    foreach ($sheetName in $sheetNames) {
        if ($sheetName.Length -gt 31) { throw "Worksheet name '$sheetName' exceeds Excel's 31-character limit." }
        $rows = @(if ($sheetName.StartsWith('INV_') -and $detailed) {
            @($detailed[$sheetName.Substring(4)])
        }
        elseif ($datasets -and $datasets.Contains($sheetName)) {
            @($datasets[$sheetName])
        }
        elseif ($vsphere -and $vsphere.Contains($sheetName)) {
            @($vsphere[$sheetName])
        }
        else { @() })

        if ($rows.Count -eq 0) {
            $rows = @([pscustomobject][ordered]@{ CollectionStatus = 'NO_ROWS'; Note = 'Dataset was collected successfully with no rows, or its collector status is recorded on VCF_CollectionStatus.' })
        }
        # Reloaded JSON contains dictionaries; Excel expects property-based records.
        $rows = @($rows | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { [pscustomobject]$_ } else { $_ } })
        $parameters = @{
            Path          = $Path
            WorksheetName = $sheetName
            AutoFilter    = $true
            BoldTopRow    = $true
            FreezeTopRow  = $true
            AutoSize      = $true
        }
        if (-not $first) { $parameters.Append = $true }
        $rows | Export-Excel @parameters
        $first = $false
    }
    return (Get-Item -LiteralPath $Path)
}

Export-ModuleMember -Function 'Export-VcfDmSnapshotExcel'
