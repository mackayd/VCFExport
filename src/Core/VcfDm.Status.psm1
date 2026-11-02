Set-StrictMode -Version Latest

function New-VcfDmCollectionStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $CollectorName,
        [Parameter(Mandatory)] [string] $SourceSystemType,
        [Parameter(Mandatory)] [string] $SourceSystemFqdn,
        [Parameter(Mandatory)] [datetime] $StartedUTC,
        [Parameter(Mandatory)] [datetime] $CompletedUTC,
        [ValidateSet('SUCCESS', 'PARTIAL', 'NOT_DEPLOYED', 'NOT_SUPPORTED', 'NOT_AUTHORIZED', 'UNREACHABLE', 'COLLECTION_FAILED', 'NOT_SUPPLIED', 'NOT_REQUESTED')]
        [string] $Status,
        [int] $RowsCollected = 0,
        [int] $WarningCount = 0,
        [int] $ErrorCount = 0,
        [string] $ErrorCategory,
        [string] $ErrorSummary,
        [string] $AuthenticationMode = 'PSCredential',
        [string] $ApiVersion,
        [string] $CollectorVersion = '0.1.0'
    )

    return [pscustomobject][ordered]@{
        CollectorName      = $CollectorName
        SourceSystemType   = $SourceSystemType
        SourceSystemFqdn   = $SourceSystemFqdn
        StartedUTC         = $StartedUTC.ToUniversalTime().ToString('o')
        CompletedUTC       = $CompletedUTC.ToUniversalTime().ToString('o')
        DurationSeconds    = [math]::Round(($CompletedUTC - $StartedUTC).TotalSeconds, 3)
        Status             = $Status
        RowsCollected      = $RowsCollected
        WarningCount       = $WarningCount
        ErrorCount         = $ErrorCount
        ErrorCategory      = $ErrorCategory
        ErrorSummary       = $ErrorSummary
        AuthenticationMode = $AuthenticationMode
        ApiVersion         = $ApiVersion
        CollectorVersion   = $CollectorVersion
    }
}

function Get-VcfDmErrorCategory {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord)

    $message = [string]$ErrorRecord.Exception.Message
    if ($message -match '(?i)401|unauthenticated|authentication') { return 'AUTHENTICATION' }
    if ($message -match '(?i)403|forbidden|not authorized|permission') { return 'AUTHORIZATION' }
    if ($message -match '(?i)certificate|SSL|TLS|trust') { return 'TLS' }
    if ($message -match '(?i)404|not found|not supported|410') { return 'NOT_SUPPORTED' }
    if ($message -match '(?i)timeout|timed out|unreachable|name resolution|connection refused') { return 'CONNECTIVITY' }
    if ($message -match '(?i)JSON|parse|format') { return 'DATA_FORMAT' }
    return 'UNEXPECTED'
}

Export-ModuleMember -Function @('New-VcfDmCollectionStatus', 'Get-VcfDmErrorCategory')

