Set-StrictMode -Version Latest

$securityModule = Join-Path (Split-Path $PSScriptRoot -Parent) 'Core\VcfDm.Security.psm1'
Import-Module $securityModule -ErrorAction Stop
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Core\VcfDm.Model.psm1') -ErrorAction Stop

function Export-VcfDmSnapshotJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Snapshot,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Path,
        [int] $Depth = 100
    )

    $safeSnapshot = Remove-VcfDmSecretFields -InputObject (ConvertTo-VcfDmCurrentSnapshot $Snapshot)
    $json = $safeSnapshot | ConvertTo-Json -Depth $Depth
    if (Test-VcfDmForbiddenContent -Text $json) {
        throw 'Snapshot serialization was blocked because forbidden secret test content was detected.'
    }
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
    return (Get-Item -LiteralPath $Path)
}

function Import-VcfDmSnapshotJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Path
    )

    $json = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path, [System.Text.Encoding]::UTF8)
    if (Test-VcfDmForbiddenContent -Text $json) {
        throw 'Snapshot load was blocked because forbidden secret test content was detected.'
    }
    $snapshot = $json | ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop
    if (-not $snapshot.Contains('SchemaVersion') -or -not $snapshot.Contains('SnapshotId') -or -not $snapshot.Contains('Datasets')) {
        throw 'The supplied JSON is not a supported VCFExport snapshot.'
    }
    return ConvertTo-VcfDmCurrentSnapshot $snapshot
}

Export-ModuleMember -Function @('Export-VcfDmSnapshotJson', 'Import-VcfDmSnapshotJson')
