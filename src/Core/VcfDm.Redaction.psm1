Set-StrictMode -Version Latest

function New-VcfDmRedactionContext {
    [CmdletBinding()]
    param()
    return @{
        Maps = @{}
        Counters = @{}
    }
}

function Protect-VcfDmValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Context,
        [Parameter(Mandatory)] [string] $Category,
        [AllowNull()] $Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $Value }
    if (-not $Context.Maps.ContainsKey($Category)) {
        $Context.Maps[$Category] = @{}
        $Context.Counters[$Category] = 0
    }
    $key = ([string]$Value).ToLowerInvariant()
    if (-not $Context.Maps[$Category].ContainsKey($key)) {
        $Context.Counters[$Category]++
        $Context.Maps[$Category][$key] = '{0}-{1:d4}' -f $Category.ToUpperInvariant(), $Context.Counters[$Category]
    }
    return $Context.Maps[$Category][$key]
}

function Get-VcfDmRedactionCategory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $PropertyName,
        [hashtable] $Options
    )

    if ($Options.ContainsKey('RedactIPAddresses') -and $Options.RedactIPAddresses -and $PropertyName -match '(?i)(ip|ipaddress|ips|gateway|subnet|poolstart|poolend)$') { return 'IP' }
    if ($Options.ContainsKey('RedactAccountNames') -and $Options.RedactAccountNames -and $PropertyName -match '(?i)(account|username|user)$') { return 'ACCOUNT' }
    if ($Options.ContainsKey('RedactNetworkNames') -and $Options.RedactNetworkNames -and $PropertyName -match '(?i)(network|portgroup|switch|vlan|transportzone)name') { return 'NETWORK' }
    if ($Options.ContainsKey('RedactDatastoreNames') -and $Options.RedactDatastoreNames -and $PropertyName -match '(?i)datastore') { return 'DATASTORE' }
    if ($Options.ContainsKey('RedactVMNames') -and $Options.RedactVMNames -and $PropertyName -match '(?i)^(vm|vmname|name)$') { return 'VM' }
    if ($Options.ContainsKey('RedactFqdnDomains') -and $Options.RedactFqdnDomains -and $PropertyName -match '(?i)(fqdn|hostname|source vcenter)$') { return 'FQDN_DOMAIN' }
    if ($Options.ContainsKey('RedactInfrastructureNames') -and $Options.RedactInfrastructureNames -and $PropertyName -match '(?i)(fqdn|hostname|hostfqdn|vcenter|sddcmanager|componentname|resourcename)$') { return 'INFRA' }
    return $null
}

function Protect-VcfDmFqdnDomain {
    param([hashtable] $Context, [string] $Value)
    $parts = $Value -split '\.'
    if ($parts.Count -lt 2) { return Protect-VcfDmValue -Context $Context -Category DOMAIN -Value $Value }
    $hostLabel = $parts[0]
    $domain = ($parts[1..($parts.Count - 1)] -join '.')
    return "$hostLabel.$(Protect-VcfDmValue -Context $Context -Category DOMAIN -Value $domain)"
}

function Invoke-VcfDmRedaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [hashtable] $Options,
        [hashtable] $Context = (New-VcfDmRedactionContext)
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject.GetType().IsPrimitive -or $InputObject -is [datetime]) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $output = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $category = Get-VcfDmRedactionCategory -PropertyName ([string]$key) -Options $Options
            if ($category -and ($InputObject[$key] -is [string])) {
                $output[$key] = if ($category -eq 'FQDN_DOMAIN') { Protect-VcfDmFqdnDomain -Context $Context -Value $InputObject[$key] } else { Protect-VcfDmValue -Context $Context -Category $category -Value $InputObject[$key] }
            }
            else {
                $output[$key] = Invoke-VcfDmRedaction -InputObject $InputObject[$key] -Options $Options -Context $Context
            }
        }
        return $output
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        return @($InputObject | ForEach-Object { Invoke-VcfDmRedaction -InputObject $_ -Options $Options -Context $Context })
    }
    $outputObject = [ordered]@{}
    foreach ($property in $InputObject.PSObject.Properties) {
        $category = Get-VcfDmRedactionCategory -PropertyName $property.Name -Options $Options
        if ($category -and ($property.Value -is [string])) {
            $outputObject[$property.Name] = if ($category -eq 'FQDN_DOMAIN') { Protect-VcfDmFqdnDomain -Context $Context -Value $property.Value } else { Protect-VcfDmValue -Context $Context -Category $category -Value $property.Value }
        }
        else {
            $outputObject[$property.Name] = Invoke-VcfDmRedaction -InputObject $property.Value -Options $Options -Context $Context
        }
    }
    return [pscustomobject]$outputObject
}

Export-ModuleMember -Function @('New-VcfDmRedactionContext', 'Protect-VcfDmValue', 'Invoke-VcfDmRedaction')
