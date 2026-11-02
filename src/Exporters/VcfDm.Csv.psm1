Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\Core\VcfDm.Security.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\Core\VcfDm.Model.psm1') -ErrorAction Stop

function Export-VcfDmSnapshotCsv {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)][string]$Path)
    $safe = Remove-VcfDmSecretFields -InputObject (ConvertTo-VcfDmCurrentSnapshot $Snapshot)
    if (Test-VcfDmForbiddenContent ($safe | ConvertTo-Json -Depth 100 -Compress)) { throw 'CSV export blocked: forbidden secret content.' }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $manifest = @()
    foreach ($containerName in @('Datasets','VSphere','Inventory')) {
        if (-not $safe.Contains($containerName)) { continue }
        $container = $safe[$containerName]
        foreach ($name in $container.Keys) {
            $rows = @($container[$name])
            $fileName = "$containerName-$name.csv"
            $columns = @($rows | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_.Keys } else { $_.PSObject.Properties.Name } } | Select-Object -Unique)
            if ($rows.Count -gt 0) {
                $export = foreach ($row in $rows) {
                    $record = [ordered]@{}
                    foreach ($column in $columns) {
                        $value = Get-VcfDmPropertyValue $row @($column)
                        if ($null -ne $value -and $value -isnot [string] -and $value -isnot [datetime] -and -not $value.GetType().IsPrimitive -and $value -isnot [decimal]) { $value = $value | ConvertTo-Json -Depth 20 -Compress }
                        if ($value -is [string] -and $value -match '^[\s\u0000-\u001f]*[=+\-@]') { $value = "'" + $value }
                        $record[$column] = $value
                    }
                    [pscustomobject]$record
                }
                $export | Export-Csv -LiteralPath (Join-Path $Path $fileName) -Encoding utf8BOM -NoTypeInformation
            }
            $manifest += [pscustomobject]@{Container=$containerName; Dataset=$name; Rows=$rows.Count; Columns=$columns.Count; File=if($rows.Count){$fileName}else{''}; Note=if($rows.Count){''}else{'NO_ROWS; see VCF_CollectionStatus for outcome.'}}
        }
    }
    $manifest | Export-Csv -LiteralPath (Join-Path $Path 'manifest.csv') -Encoding utf8BOM -NoTypeInformation
    return Get-Item -LiteralPath $Path
}

Export-ModuleMember -Function Export-VcfDmSnapshotCsv
