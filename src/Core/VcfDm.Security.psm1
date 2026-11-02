Set-StrictMode -Version Latest

$script:ForbiddenPropertyPattern = '(?i)(password|passwd|secret|token|authorization|cookie|private.?key|activation.?code|download.?code|license.?key|refresh.?token|session)'
$script:KnownSecretValuePattern = '(?i)(TEST-(?:SECRET-PASSWORD|DOWNLOAD-TOKEN|ACTIVATION-CODE|REFRESH-TOKEN|SESSION-TOKEN|PRIVATE-KEY|FULL-LICENSE-KEY)|Bearer\s+TEST-TOKEN)'

function Get-VcfDmPropertyValue {
    [CmdletBinding()]
    param(
        $InputObject,
        [Parameter(Mandatory)] [string[]] $Path,
        $Default = $null
    )

    foreach ($candidate in $Path) {
        $current = $InputObject
        $found = $true
        foreach ($segment in ($candidate -split '\.')) {
            if ($null -eq $current) {
                $found = $false
                break
            }
            if ($current -is [System.Collections.IDictionary]) {
                if (-not $current.Contains($segment)) {
                    $found = $false
                    break
                }
                $current = $current[$segment]
            }
            else {
                $property = $current.PSObject.Properties[$segment]
                if ($null -eq $property) {
                    $found = $false
                    break
                }
                $current = $property.Value
            }
        }
        if ($found -and $null -ne $current) {
            return $current
        }
    }
    return $Default
}

function ConvertTo-VcfDmSafeRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $PropertyMap
    )

    $safe = [ordered]@{}
    foreach ($destination in $PropertyMap.Keys) {
        if ($destination -match $script:ForbiddenPropertyPattern) {
            throw "Unsafe destination property '$destination' is not permitted."
        }
        $definition = $PropertyMap[$destination]
        if ($definition -is [scriptblock]) {
            $safe[$destination] = & $definition $InputObject
        }
        else {
            $paths = if ($definition -is [System.Collections.IEnumerable] -and $definition -isnot [string]) {
                @($definition | ForEach-Object { [string]$_ })
            }
            else {
                @([string]$definition)
            }
            $safe[$destination] = Get-VcfDmPropertyValue -InputObject $InputObject -Path $paths
        }
    }
    return [pscustomobject]$safe
}

function Remove-VcfDmSecretFields {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] [AllowNull()] $InputObject
    )

    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [string] -or $InputObject.GetType().IsPrimitive -or $InputObject -is [datetime] -or $InputObject -is [decimal]) {
            return $InputObject
        }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $clean = [ordered]@{}
            foreach ($key in $InputObject.Keys) {
                if ([string]$key -match $script:ForbiddenPropertyPattern) { continue }
                $clean[[string]$key] = Remove-VcfDmSecretFields -InputObject $InputObject[$key]
            }
            return $clean
        }
        if ($InputObject -is [System.Collections.IEnumerable]) {
            # Unary comma prevents PowerShell from unrolling a one-element
            # array or turning an empty array into $null at the caller.
            return ,@($InputObject | ForEach-Object { Remove-VcfDmSecretFields -InputObject $_ })
        }
        $cleanObject = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            if ($property.Name -match $script:ForbiddenPropertyPattern) { continue }
            $cleanObject[$property.Name] = Remove-VcfDmSecretFields -InputObject $property.Value
        }
        return [pscustomobject]$cleanObject
    }
}

function ConvertTo-VcfDmMaskedLicenseId {
    [CmdletBinding()]
    param([AllowNull()] [string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return 'LICENSE-' + ([Convert]::ToHexString($hash)).Substring(0, 12)
}

function ConvertTo-VcfDmSafeErrorText {
    [CmdletBinding()]
    param([AllowNull()] [string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    $safe = $Text -replace '(?i)(authorization\s*[:=]\s*)([^,;\r\n]+)', '$1[REDACTED]'
    $safe = $safe -replace '(?i)((password|token|secret|licenseKey|activationCode)\s*[:=]\s*)([^,;\r\n]+)', '$1[REDACTED]'
    $safe = $safe -replace $script:KnownSecretValuePattern, '[REDACTED]'
    return $safe
}

function Test-VcfDmForbiddenContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Text
    )
    return $Text -match $script:KnownSecretValuePattern
}

Export-ModuleMember -Function @(
    'Get-VcfDmPropertyValue',
    'ConvertTo-VcfDmSafeRecord',
    'Remove-VcfDmSecretFields',
    'ConvertTo-VcfDmMaskedLicenseId',
    'ConvertTo-VcfDmSafeErrorText',
    'Test-VcfDmForbiddenContent'
)
