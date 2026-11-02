Set-StrictMode -Version Latest

function Connect-VcfDmSddcManager {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Server,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [switch] $SkipCertificateCheck
    )

    Import-Module VMware.Sdk.Vcf.SddcManager -MinimumVersion 13.5.0 -ErrorAction Stop -WarningAction SilentlyContinue
    $parameters = @{
        Server      = $Server
        Credential  = $Credential
        NotDefault  = $true
        ErrorAction = 'Stop'
    }
    if ($SkipCertificateCheck) { $parameters.IgnoreInvalidCertificate = $true }
    return Connect-VcfSddcManagerServer @parameters
}

function Disconnect-VcfDmSddcManager {
    [CmdletBinding()]
    param($Server)
    if ($Server) {
        Disconnect-VcfSddcManagerServer -Server $Server -ErrorAction SilentlyContinue | Out-Null
    }
}

Export-ModuleMember -Function @('Connect-VcfDmSddcManager', 'Disconnect-VcfDmSddcManager')

