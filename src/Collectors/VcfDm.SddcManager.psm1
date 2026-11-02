Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Core\VcfDm.Model.psm1') -ErrorAction Stop
Import-Module (Join-Path $root 'Core\VcfDm.Security.psm1') -ErrorAction Stop
Import-Module (Join-Path $root 'Core\VcfDm.Status.psm1') -ErrorAction Stop
Import-Module (Join-Path $root 'Core\VcfDm.Lifecycle.psm1') -ErrorAction Stop
Import-Module (Join-Path $root 'Lifecycle\VcfDm.OfflineMetadata.psm1') -ErrorAction Stop

function Get-VcfDmElements {
    param($InputObject)
    if ($null -eq $InputObject) { return @() }
    if ($InputObject.PSObject.Properties['Elements']) { return @($InputObject.Elements) }
    return @($InputObject)
}

function Join-VcfDmValues {
    param($Value, [string[]] $Paths = @('Name', 'Fqdn', 'Id', 'Type'))
    $output = foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        if ($item -is [string] -or $item.GetType().IsPrimitive) { [string]$item; continue }
        $candidate = Get-VcfDmPropertyValue -InputObject $item -Path $Paths
        if ($null -ne $candidate) { [string]$candidate }
    }
    return @($output | Where-Object { $_ }) -join '; '
}

function Get-VcfDmFirstProperty {
    param($Items, [Parameter(Mandatory)] [string] $Name)
    $first = @($Items | Select-Object -First 1)
    if ($first.Count -eq 0 -or $null -eq $first[0]) { return $null }
    return Get-VcfDmPropertyValue -InputObject $first[0] -Path @($Name)
}

function New-VcfDmCommonFields {
    param(
        [System.Collections.IDictionary] $Snapshot,
        [string] $VCFInstanceId,
        [string] $VCFInstanceName,
        [string] $DomainId,
        [string] $DomainName,
        [string] $SourceSystemType,
        [string] $SourceSystemId,
        [string] $SourceSystemFqdn,
        [string] $CollectionStatus = 'SUCCESS'
    )
    return [ordered]@{
        SnapshotId        = $Snapshot.SnapshotId
        CollectedUTC      = $Snapshot.CollectedUTC
        CollectorVersion  = $Snapshot.CollectorVersion
        SchemaVersion     = $Snapshot.SchemaVersion
        VCFInstanceId     = $VCFInstanceId
        VCFInstanceName   = $VCFInstanceName
        DomainId          = $DomainId
        DomainName        = $DomainName
        SourceSystemType  = $SourceSystemType
        SourceSystemId    = $SourceSystemId
        SourceSystemFqdn  = $SourceSystemFqdn
        CollectionStatus  = $CollectionStatus
        CollectionWarning = $null
    }
}

function New-VcfDmRow {
    param([System.Collections.IDictionary] $Common, [System.Collections.IDictionary] $Fields)
    $row = [ordered]@{}
    foreach ($key in $Common.Keys) { $row[$key] = $Common[$key] }
    foreach ($key in $Fields.Keys) { $row[$key] = $Fields[$key] }
    return [pscustomobject]$row
}

function Add-VcfDmStatusRow {
    param(
        [System.Collections.IDictionary] $Snapshot,
        [string] $CollectorName,
        [string] $SourceSystemFqdn,
        [datetime] $StartedUTC,
        [string] $Status,
        [int] $RowsCollected = 0,
        [string] $ErrorCategory,
        [string] $ErrorSummary,
        [int] $WarningCount = 0,
        [int] $ErrorCount = 0
    )
    $statusRow = New-VcfDmCollectionStatus -CollectorName $CollectorName -SourceSystemType SDDC_MANAGER -SourceSystemFqdn $SourceSystemFqdn -StartedUTC $StartedUTC -CompletedUTC ([datetime]::UtcNow) -Status $Status -RowsCollected $RowsCollected -WarningCount $WarningCount -ErrorCount $ErrorCount -ErrorCategory $ErrorCategory -ErrorSummary $ErrorSummary -ApiVersion 'v1' -CollectorVersion $Snapshot.CollectorVersion
    Add-VcfDmDatasetRow -Snapshot $Snapshot -Dataset VCF_CollectionStatus -Row $statusRow
}

function Get-VcfDmFailureStatus {
    param([string] $Category)
    switch ($Category) {
        'AUTHORIZATION' { 'NOT_AUTHORIZED' }
        'NOT_SUPPORTED' { 'NOT_SUPPORTED' }
        'CONNECTIVITY' { 'UNREACHABLE' }
        default { 'COLLECTION_FAILED' }
    }
}

function Invoke-VcfDmProjectedCollector {
    param(
        [System.Collections.IDictionary] $Snapshot,
        [string] $CollectorName,
        [string] $SourceSystemFqdn,
        [string] $Dataset,
        [string] $RequiredCommand,
        [scriptblock] $Operation,
        [scriptblock] $Project
    )

    $started = [datetime]::UtcNow
    if ($RequiredCommand -and -not (Get-Command $RequiredCommand -ErrorAction SilentlyContinue)) {
        Add-VcfDmStatusRow -Snapshot $Snapshot -CollectorName $CollectorName -SourceSystemFqdn $SourceSystemFqdn -StartedUTC $started -Status NOT_SUPPORTED -ErrorCategory NOT_SUPPORTED -ErrorSummary "Required read operation $RequiredCommand is unavailable."
        return @()
    }
    try {
        $raw = & $Operation
        $rows = @(& $Project $raw)
        foreach ($row in $rows) {
            if ($null -ne $row) { Add-VcfDmDatasetRow -Snapshot $Snapshot -Dataset $Dataset -Row $row }
        }
        Add-VcfDmStatusRow -Snapshot $Snapshot -CollectorName $CollectorName -SourceSystemFqdn $SourceSystemFqdn -StartedUTC $started -Status SUCCESS -RowsCollected $rows.Count
        return @($rows)
    }
    catch {
        $category = Get-VcfDmErrorCategory -ErrorRecord $_
        $summary = ConvertTo-VcfDmSafeErrorText -Text $_.Exception.Message
        Add-VcfDmStatusRow -Snapshot $Snapshot -CollectorName $CollectorName -SourceSystemFqdn $SourceSystemFqdn -StartedUTC $started -Status (Get-VcfDmFailureStatus $category) -ErrorCategory $category -ErrorSummary $summary -ErrorCount 1
        return @()
    }
    finally { $raw = $null }
}

function Invoke-VcfDmPasswordExpirationQuery {
    param(
        [Parameter(Mandatory)] $ServerConnection,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ResourceType,
        [string] $DomainId,
        [string] $DomainName,
        [ValidateRange(10, 300)] [int] $TimeoutSeconds = 120
    )

    $specificationArguments = @{ ResourceType = $ResourceType }
    if ($DomainName) { $specificationArguments.DomainName = $DomainName }
    $specification = Initialize-VcfCredentialsExpirationSpec @specificationArguments
    $task = Invoke-VcfGetPasswordExpiration -Server $ServerConnection -CredentialsExpirationSpec $specification -ErrorAction Stop
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([string]$task.Status -match '^(IN_PROGRESS|PENDING|SCHEDULED)$') {
        if ([datetime]::UtcNow -ge $deadline) {
            throw "Password-expiration query for resource type '$ResourceType' did not complete within $TimeoutSeconds seconds."
        }
        Start-Sleep -Milliseconds 750
        $task = Invoke-VcfGetPasswordExpirationByTaskID -Server $ServerConnection -Id $task.Id -ErrorAction Stop
    }
    if ([string]$task.Status -ne 'COMPLETED') {
        throw "Password-expiration query for resource type '$ResourceType' completed with status '$($task.Status)'."
    }

    foreach ($element in @($task.Elements | Where-Object { $null -ne $_ })) {
        [pscustomobject]@{
            DomainId = $DomainId
            DomainName = $DomainName
            RequestedResourceType = $ResourceType
            TaskCompletionTimestamp = $task.CompletionTimestamp
            Element = $element
        }
    }
}

function Get-VcfDmManagementModel {
    param($Components)
    if ($Components -and ($Components.SddcLcm -or $Components.VspCluster -or $Components.Vidb)) { return 'VCF_MANAGEMENT_SERVICES' }
    if ($Components -and ($Components.FleetLcm -or $Components.VcfOperationsFleetManagement)) { return 'FLEET_MANAGEMENT' }
    return 'UNKNOWN'
}

function ConvertTo-VcfDmLiveCatalogRows {
    param($Catalog)
    if (-not $Catalog) { return @() }
    $rows = [System.Collections.Generic.List[object]]::new()
    $groups = Get-VcfDmPropertyValue -InputObject $Catalog -Path @('Patches')
    if ($groups -is [System.Collections.IDictionary]) {
        foreach ($componentType in $groups.Keys) {
            foreach ($patch in @($groups[$componentType])) {
                $bundles = @(Get-VcfDmPropertyValue -InputObject $patch -Path @('Artifacts.Bundles'))
                if (@($bundles).Count -eq 0) { $bundles = ,$null }
                foreach ($bundle in $bundles) {
                    $binaries = @(if ($bundle) { Get-VcfDmPropertyValue -InputObject $bundle -Path @('Binaries') })
                    if (@($binaries).Count -eq 0) { $binaries = ,$null }
                    foreach ($binary in $binaries) {
                        $rows.Add([pscustomobject][ordered]@{
                            CatalogSource = 'SDDC_MANAGER'; CatalogVersion = $Catalog.Version; SequenceNumber = $Catalog.SequenceNumber
                            CreationUTC = $Catalog.CreationTime; PublishedUTC = $Catalog.PublishedTime; ProductVersion = $patch.ProductVersion
                            ReleaseDate = $patch.ReleaseDate; Description = $patch.Description
                            BundleId = if ($bundle) { $bundle.Id } else { $null }; BundleType = if ($bundle) { $bundle.Type } else { $null }
                            BundleName = if ($bundle) { $bundle.Name } else { $null }; BinaryFileName = if ($binary) { $binary.FileName } else { $null }
                            BinarySize = if ($binary) { $binary.Size } else { $null }; BinaryChecksum = if ($binary) { $binary.Checksum } else { $null }
                            MetadataTags = [string]$componentType; CatalogAgeDays = $null; CollectionStatus = 'SUCCESS'
                        })
                    }
                }
            }
        }
    }
    return @($rows)
}

function Invoke-VcfDmSddcManagerCollection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Snapshot,
        [Parameter(Mandatory)] $ServerConnection,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerFqdn
    )

    $instanceId = Get-VcfDmObjectId -VCFInstanceId $ServerFqdn -SourceSystemId $ServerFqdn -SourceSystemFqdn $ServerFqdn -ObjectType VCF_INSTANCE -NativeObjectId $ServerFqdn
    $instanceName = $ServerFqdn
    $baseCommon = New-VcfDmCommonFields -Snapshot $Snapshot -VCFInstanceId $instanceId -VCFInstanceName $instanceName -SourceSystemType SDDC_MANAGER -SourceSystemId $ServerFqdn -SourceSystemFqdn $ServerFqdn

    $systemRows = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.System' -SourceSystemFqdn $ServerFqdn -Dataset VCF_Instances -RequiredCommand Invoke-VcfGetSystemRelease -Operation {
        Invoke-VcfGetSystemRelease -Server $ServerConnection -ErrorAction Stop
    } -Project {
        param($release)
        New-VcfDmRow -Common $baseCommon -Fields ([ordered]@{
            SDDCManagerId = $ServerFqdn; SDDCManagerFqdn = $ServerFqdn
            ManagementDomainId = $null; ManagementDomainName = $null; SystemRelease = $release.Version
            ManagementModel = 'UNKNOWN'; VCFOpsFqdn = $null; LifecycleEndpointType = 'SDDC_MANAGER'
        })
    }
    $systemRelease = if ($systemRows.Count) { $systemRows[0].SystemRelease } else { $null }

    $domains = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.Domains' -SourceSystemFqdn $ServerFqdn -Dataset VCF_Domains -RequiredCommand Invoke-VcfGetDomains -Operation {
        Invoke-VcfGetDomains -Server $ServerConnection -PageSize 1000 -ErrorAction Stop
    } -Project {
        param($response)
        foreach ($domain in Get-VcfDmElements $response) {
            $domainCommon = New-VcfDmCommonFields -Snapshot $Snapshot -VCFInstanceId $instanceId -VCFInstanceName $instanceName -DomainId $domain.Id -DomainName $domain.Name -SourceSystemType SDDC_MANAGER -SourceSystemId $ServerFqdn -SourceSystemFqdn $ServerFqdn
            New-VcfDmRow -Common $domainCommon -Fields ([ordered]@{
                DomainType = $domain.Type; VCenterId = Get-VcfDmPropertyValue $domain @('Vcenters.0.Id')
                VCenterFqdn = Get-VcfDmPropertyValue $domain @('Vcenters.0.Fqdn'); NSXClusterId = Get-VcfDmPropertyValue $domain @('NsxtCluster.Id')
                NSXManagerFqdns = Get-VcfDmPropertyValue $domain @('NsxtCluster.VipFqdn'); ClusterCount = @($domain.Clusters).Count
                HostCount = $null; NtpServers = Join-VcfDmValues $domain.NtpServers; DnsServers = Join-VcfDmValues $domain.DnsServers
                Tags = Join-VcfDmValues $domain.Tags; Capabilities = $null; CurrentVCFRelease = $systemRelease
                SelectedTargetRelease = $null; ImageComplianceStatus = $domain.UpgradeStatus; IsolationStatus = $domain.Status
            })
        }
    }

    $managementDomain = @($domains | Where-Object { $_.DomainType -match '(?i)MANAGEMENT' } | Select-Object -First 1)
    if ($systemRows.Count -and $managementDomain.Count) {
        $systemRows[0].ManagementDomainId = $managementDomain[0].DomainId
        $systemRows[0].ManagementDomainName = $managementDomain[0].DomainName
    }

    $clusters = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.Clusters' -SourceSystemFqdn $ServerFqdn -Dataset VCF_Clusters -RequiredCommand Invoke-VcfGetClusters -Operation {
        Invoke-VcfGetClusters -Server $ServerConnection -PageSize 1000 -ErrorAction Stop
    } -Project {
        param($response)
        foreach ($cluster in Get-VcfDmElements $response) {
            $domainId = Get-VcfDmPropertyValue $cluster @('Domain.Id')
            $domainName = Get-VcfDmPropertyValue $cluster @('Domain.Name')
            $common = New-VcfDmCommonFields -Snapshot $Snapshot -VCFInstanceId $instanceId -VCFInstanceName $instanceName -DomainId $domainId -DomainName $domainName -SourceSystemType SDDC_MANAGER -SourceSystemId $ServerFqdn -SourceSystemFqdn $ServerFqdn
            New-VcfDmRow -Common $common -Fields ([ordered]@{
                ClusterId = $cluster.Id; ClusterName = $cluster.Name; VCenterFqdn = Get-VcfDmPropertyValue $cluster @('Vcenter.Fqdn')
                HostCount = @($cluster.Hosts).Count; PrimaryDatastore = $cluster.PrimaryDatastoreName; DatastoreIds = $cluster.PrimaryDatastoreNativeId
                VdsIds = Join-VcfDmValues $cluster.VdsSpecs @('Id', 'Name'); StorageType = $cluster.PrimaryDatastoreType
                VsanEnabled = [bool]($cluster.PrimaryDatastoreType -match '(?i)VSAN'); VsanMode = $cluster.VsanClusterMode
                StretchedCluster = $cluster.IsStretched; Tags = Join-VcfDmValues $cluster.Tags; ImageCompliance = if ($cluster.IsImageBased) { 'IMAGE_BASED' } else { 'BASELINE_OR_UNKNOWN' }
                LifecycleState = $cluster.Status
            })
        }
    }

    $hosts = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.Hosts' -SourceSystemFqdn $ServerFqdn -Dataset VCF_Hosts -RequiredCommand Invoke-VcfGetHosts -Operation {
        Invoke-VcfGetHosts -Server $ServerConnection -PageSize 1000 -ErrorAction Stop
    } -Project {
        param($response)
        foreach ($hostItem in Get-VcfDmElements $response) {
            $domainId = Get-VcfDmPropertyValue $hostItem @('Domain.Id'); $domainName = Get-VcfDmPropertyValue $hostItem @('Domain.Name')
            $common = New-VcfDmCommonFields -Snapshot $Snapshot -VCFInstanceId $instanceId -VCFInstanceName $instanceName -DomainId $domainId -DomainName $domainName -SourceSystemType SDDC_MANAGER -SourceSystemId $ServerFqdn -SourceSystemFqdn $ServerFqdn
            New-VcfDmRow -Common $common -Fields ([ordered]@{
                HostId = $hostItem.Id; HostFqdn = $hostItem.Fqdn; ClusterId = Get-VcfDmPropertyValue $hostItem @('Cluster.Id')
                VCenterFqdn = Get-VcfDmFirstProperty ($domains | Where-Object DomainId -eq $domainId) 'VCenterFqdn'
                ManagementIp = Get-VcfDmPropertyValue $hostItem @('IpAddresses.0._IpAddress', 'IpAddresses.0.IpAddress')
                CurrentESXVersion = $hostItem.EsxiVersion; Build = Get-VcfDmPropertyValue $hostItem @('SoftwareInfo.Build')
                LifecycleManaged = $hostItem.IsLifecycleManaged; VsanWitness = $hostItem.IsVsanWitnessHost; Standalone = $hostItem.IsStandalone
                Vendor = $hostItem.HardwareVendor; Model = $hostItem.HardwareModel; Serial = $hostItem.SerialNumber
                CpuModel = $null; CpuSockets = $null; CpuCores = Get-VcfDmPropertyValue $hostItem @('Cpu.Cores', 'Cpu.CpuCores')
                MemoryGiB = if ($hostItem.Memory.TotalCapacityMB) { [math]::Round($hostItem.Memory.TotalCapacityMB / 1024, 2) } else { $null }
                MaintenanceMode = $null; ConnectionState = $hostItem.Status; ImageCompliance = $hostItem.ConfigurationStatus
            })
        }
    }

    foreach ($domainRow in $domains) {
        $domainRow.HostCount = @($hosts | Where-Object DomainId -eq $domainRow.DomainId).Count
    }

    $vcenters = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.vCenters' -SourceSystemFqdn $ServerFqdn -Dataset VCF_vCenters -RequiredCommand Invoke-VcfGetVcenters -Operation {
        Invoke-VcfGetVcenters -Server $ServerConnection -PageSize 1000 -ErrorAction Stop
    } -Project {
        param($response)
        foreach ($vc in Get-VcfDmElements $response) {
            $domainId = Get-VcfDmPropertyValue $vc @('Domain.Id'); $domainName = Get-VcfDmFirstProperty ($domains | Where-Object DomainId -eq $domainId) 'DomainName'
            $common = New-VcfDmCommonFields -Snapshot $Snapshot -VCFInstanceId $instanceId -VCFInstanceName $instanceName -DomainId $domainId -DomainName $domainName -SourceSystemType SDDC_MANAGER -SourceSystemId $ServerFqdn -SourceSystemFqdn $ServerFqdn
            New-VcfDmRow -Common $common -Fields ([ordered]@{
                VCenterId = $vc.Id; VCenterFqdn = $vc.Fqdn; Version = $vc.Version; Build = $null; InstanceUuid = $vc.VcInstanceId
                DatacenterCount = $null; ClusterCount = @($clusters | Where-Object DomainId -eq $domainId).Count
                HostCount = @($hosts | Where-Object DomainId -eq $domainId).Count; VmCount = $null
                EnhancedLinkedModeDomain = $null; LifecycleStatus = $vc.Status; CertificateExpiryUTC = $null
            })
        }
    }

    $sddcManagers = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.Appliances' -SourceSystemFqdn $ServerFqdn -Dataset VCF_SDDCManagers -RequiredCommand Invoke-VcfGetSddcManagers -Operation {
        Invoke-VcfGetSddcManagers -Server $ServerConnection -ErrorAction Stop
    } -Project {
        param($response)
        foreach ($manager in Get-VcfDmElements $response) {
            $domainId = Get-VcfDmPropertyValue $manager @('Domain.Id'); $domainName = Get-VcfDmFirstProperty ($domains | Where-Object DomainId -eq $domainId) 'DomainName'
            $common = New-VcfDmCommonFields -Snapshot $Snapshot -VCFInstanceId $instanceId -VCFInstanceName $instanceName -DomainId $domainId -DomainName $domainName -SourceSystemType SDDC_MANAGER -SourceSystemId $manager.Id -SourceSystemFqdn $manager.Fqdn
            New-VcfDmRow -Common $common -Fields ([ordered]@{
                SDDCManagerId = $manager.Id; Fqdn = $manager.Fqdn; IpAddress = $manager.IpAddress; Version = $manager.Version
                Build = $null; ManagementDomainId = $domainId; Services = $null; FipsMode = $null; BackupConfigured = $null; CertificateExpiryUTC = $null
            })
        }
    }

    $managementComponentsRaw = $null
    $managementComponents = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.ManagementComponents' -SourceSystemFqdn $ServerFqdn -Dataset VCF_ManagementComponents -RequiredCommand Invoke-VcfGetVcfManagementComponents -Operation {
        $script:managementComponentsRaw = Invoke-VcfGetVcfManagementComponents -Server $ServerConnection -ErrorAction Stop
        $script:managementComponentsRaw
    } -Project {
        param($response)
        $logical = @{
            VcfOperationsFleetManagement='FLEET_LIFECYCLE'; VcfOperations='OPERATIONS'; VcfOperationsCollector='OPERATIONS_COLLECTOR'
            VcfAutomation='AUTOMATION'; VspCluster='IDENTITY'; SddcLcm='SDDC_LIFECYCLE'; FleetLcm='FLEET_LIFECYCLE'
            VcfOperationsLogs='LOG_MANAGEMENT'; TelemetryAcceptor='TELEMETRY'; Vidb='DATA_PLATFORM'; Salt='CONFIGURATION_MANAGEMENT'; SaltRaas='CONFIGURATION_MANAGEMENT'
        }
        foreach ($property in $response.PSObject.Properties | Where-Object { $_.Name -ne 'AdditionalProperties' -and $null -ne $_.Value }) {
            $component = $property.Value; $fqdn = Get-VcfDmPropertyValue $component @('Fqdn', 'LoadBalancerFqdn')
            $componentId = Get-VcfDmObjectId -VCFInstanceId $instanceId -SourceSystemId $ServerFqdn -SourceSystemFqdn $ServerFqdn -ObjectType MANAGEMENT_COMPONENT -NativeObjectId $property.Name
            New-VcfDmRow -Common $baseCommon -Fields ([ordered]@{
                ComponentId = $componentId; ComponentType = $logical[$property.Name]; ComponentName = $property.Name; Fqdn = $fqdn
                Version = Get-VcfDmPropertyValue $component @('Version'); DeploymentType = $component.DeploymentType
                DeploymentStatus = $component.DeploymentStatus; NodeType = $null; ApplianceSize = $null
                ManagementModel = Get-VcfDmManagementModel $response; NativeComponentType = $property.Name
            })
        }
    }
    $managementModel = if ($managementComponents.Count) { $managementComponents[0].ManagementModel } else { 'UNKNOWN' }
    if ($systemRows.Count) {
        $systemRows[0].ManagementModel = $managementModel
        $systemRows[0].VCFOpsFqdn = Get-VcfDmFirstProperty ($managementComponents | Where-Object ComponentType -eq OPERATIONS) 'Fqdn'
    }
    $script:managementComponentsRaw = $null

    $null = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.Endpoints' -SourceSystemFqdn $ServerFqdn -Dataset VCF_Endpoints -RequiredCommand Invoke-VcfGetDomainEndpoints -Operation {
        $all = @(); foreach ($domain in $domains) { $all += Get-VcfDmElements (Invoke-VcfGetDomainEndpoints -Server $ServerConnection -Id $domain.DomainId -ErrorAction Stop) }; $all
    } -Project {
        param($response)
        foreach ($endpoint in @($response)) {
            $fqdn = Get-VcfDmPropertyValue $endpoint @('Fqdn', 'Hostname', 'Host')
            New-VcfDmRow -Common $baseCommon -Fields ([ordered]@{
                EndpointId = Get-VcfDmPropertyValue $endpoint @('Id', 'ResourceId'); ComponentType = Get-VcfDmPropertyValue $endpoint @('Type', 'ResourceType')
                ComponentName = Get-VcfDmPropertyValue $endpoint @('Name', 'ResourceName'); Fqdn = $fqdn; IpAddress = Get-VcfDmPropertyValue $endpoint @('IpAddress')
                Protocol = Get-VcfDmPropertyValue $endpoint @('Protocol'); Port = Get-VcfDmPropertyValue $endpoint @('Port'); Url = Get-VcfDmPropertyValue $endpoint @('Url')
                ReachabilityStatus = 'DISCOVERED'; TlsSubject = $null; TlsExpiryUTC = $null
            })
        }
    }

    $null = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.NetworkPools' -SourceSystemFqdn $ServerFqdn -Dataset VCF_NetworkPools -RequiredCommand Invoke-VcfGetNetworkPool -Operation {
        Invoke-VcfGetNetworkPool -Server $ServerConnection -ErrorAction Stop
    } -Project {
        param($response)
        foreach ($pool in Get-VcfDmElements $response) {
            foreach ($network in @($pool.Networks)) {
                $ipPool = @($network.IpPools)[0]
                New-VcfDmRow -Common $baseCommon -Fields ([ordered]@{
                    NetworkPoolId = $pool.Id; NetworkPoolName = $pool.Name; NetworkId = $network.Id; NetworkType = $network.Type
                    VlanId = $network.VlanId; Mtu = $network.Mtu; Subnet = $network.Subnet; Gateway = $network.Gateway; PrefixLength = $network.Mask
                    Ipv6Gateway = $null; Ipv6PrefixLength = $null; IpPoolStart = Get-VcfDmPropertyValue $ipPool @('Start', 'StartIpAddress')
                    IpPoolEnd = Get-VcfDmPropertyValue $ipPool @('End', 'EndIpAddress'); UsedIpCount = $network.UsedIpCount; FreeIpCount = $network.FreeIpCount
                    DnsServers = $null; NtpServers = $null
                })
            }
        }
    }

    $nsxClusters = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.NSXClusters' -SourceSystemFqdn $ServerFqdn -Dataset VCF_NSXClusters -RequiredCommand Invoke-VcfGetNsxClusters -Operation {
        Invoke-VcfGetNsxClusters -Server $ServerConnection -PageSize 1000 -ErrorAction Stop
    } -Project {
        param($response)
        foreach ($nsx in Get-VcfDmElements $response) {
            New-VcfDmRow -Common $baseCommon -Fields ([ordered]@{
                NSXClusterId = $nsx.Id; DomainId = Join-VcfDmValues $nsx.Domains @('Id'); ManagerFqdns = Join-VcfDmValues $nsx.Nodes @('Fqdn')
                ManagerIps = Join-VcfDmValues $nsx.Nodes @('IpAddress'); VipFqdn = $nsx.VipFqdn; VipIp = $nsx.Vip; Version = $nsx.Version
                TransportZones = $null; IpPools = $null; ProjectCount = $null; VpcConfigurationPresent = $null; CertificateExpiryUTC = $null
            })
        }
    }

    $edgeClusters = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.EdgeClusters' -SourceSystemFqdn $ServerFqdn -Dataset VCF_EdgeClusters -RequiredCommand Invoke-VcfGetEdgeClusters -Operation {
        Invoke-VcfGetEdgeClusters -Server $ServerConnection -ErrorAction Stop
    } -Project {
        param($response)
        foreach ($edge in Get-VcfDmElements $response) {
            New-VcfDmRow -Common $baseCommon -Fields ([ordered]@{
                EdgeClusterId = $edge.Id; EdgeClusterName = $edge.Name; NSXClusterId = Get-VcfDmPropertyValue $edge @('NsxTCluster.Id', 'NsxClusterId')
                DomainId = Get-VcfDmPropertyValue $edge @('Domain.Id', 'DomainId'); MemberCount = @($edge.Nodes).Count
                MemberNodeIds = Join-VcfDmValues $edge.Nodes @('Id'); DeploymentType = Get-VcfDmPropertyValue $edge @('Type', 'DeploymentType')
                TransportNodeStatus = $edge.Status; Tier0Associations = $null
            })
        }
    }

    $releaseRows = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.Releases' -SourceSystemFqdn $ServerFqdn -Dataset VCF_UpgradePaths -RequiredCommand Invoke-VcfGetFutureReleases -Operation {
        $allFuture = @()
        foreach ($domain in $domains) {
            foreach ($release in Get-VcfDmElements (Invoke-VcfGetFutureReleases -Server $ServerConnection -DomainId $domain.DomainId -ErrorAction Stop)) {
                $allFuture += [pscustomobject]@{ Domain = $domain; Release = $release }
            }
        }
        $allFuture
    } -Project {
        param($response)
        foreach ($item in @($response | Where-Object { $null -ne $_ })) {
                $domain = $item.Domain
                $release = $item.Release
                $common = New-VcfDmCommonFields -Snapshot $Snapshot -VCFInstanceId $instanceId -VCFInstanceName $instanceName -DomainId $domain.DomainId -DomainName $domain.DomainName -SourceSystemType SDDC_MANAGER -SourceSystemId $ServerFqdn -SourceSystemFqdn $ServerFqdn
                New-VcfDmRow -Common $common -Fields ([ordered]@{
                    CurrentRelease = $domain.CurrentVCFRelease; CandidateRelease = $release.Version; Applicable = $true
                    Compatible = $true; SteppingStoneRequired = $null; UpgradeSequence = Join-VcfDmValues (Get-VcfDmPropertyValue $release @('UpgradeOrder', 'UpgradeSequence'))
                    BlockedReason = Get-VcfDmPropertyValue $release @('NotApplicableReason', 'BlockedReason'); ImpactMessage = Get-VcfDmPropertyValue $release @('ImpactMessage'); RemediationMessage = Get-VcfDmPropertyValue $release @('RemediationMessage'); SourceCatalog = 'SDDC_MANAGER'; CatalogPublishedUTC = $null
                })
        }
    }
    $localReleaseVersions = @($releaseRows | Where-Object Applicable | Select-Object -ExpandProperty CandidateRelease -Unique)
    $localLatest = if ($localReleaseVersions.Count) { Get-VcfDmLatestVersion -Versions $localReleaseVersions } else { $systemRelease }
    foreach ($domain in $domains) {
        $assessment = if ($domain.CurrentVCFRelease) { Get-VcfDmLifecycleAssessment -DeployedVersion $domain.CurrentVCFRelease -LocalCatalogLatestKnownVersion $localLatest -ReferenceMetadataLatestKnownVersion $Snapshot.LifecycleKnowledge.ReferenceMetadataLatestKnownVersion -LifecycleKnowledgeScope $Snapshot.LifecycleKnowledgeScope } else { $null }
        $common = New-VcfDmCommonFields -Snapshot $Snapshot -VCFInstanceId $instanceId -VCFInstanceName $instanceName -DomainId $domain.DomainId -DomainName $domain.DomainName -SourceSystemType SDDC_MANAGER -SourceSystemId $ServerFqdn -SourceSystemFqdn $ServerFqdn
        Add-VcfDmDatasetRow -Snapshot $Snapshot -Dataset VCF_Lifecycle -Row (New-VcfDmRow -Common $common -Fields ([ordered]@{
            DomainType = $domain.DomainType; CurrentVCFRelease = $domain.CurrentVCFRelease; SystemFloorRelease = $systemRelease; SelectedTargetRelease = $domain.SelectedTargetRelease
            LatestApplicableLocalRelease = $localLatest; LatestApplicableReferenceRelease = $Snapshot.LifecycleKnowledge.ReferenceMetadataLatestKnownVersion
            UpgradeAvailable = if ($assessment) { $assessment.UpgradeAvailable } else { 'UNKNOWN' }; UpgradeAssessmentBasis = if ($assessment) { $assessment.UpgradeAssessmentBasis } else { 'NONE' }
            AssessmentConfidence = if ($assessment) { $assessment.AssessmentConfidence } else { 'UNKNOWN' }; UpgradeSequence = $null; CompatibilityStatus = $null
            PrecheckStatus = $null; LifecycleKnowledgeScope = $Snapshot.LifecycleKnowledgeScope; CatalogPublishedUTC = $null; CatalogAgeDays = $null
        }))
    }

    $systemBom = @()
    $bomStarted = [datetime]::UtcNow
    try {
        $systemRaw = Invoke-VcfGetSystemRelease -Server $ServerConnection -ErrorAction Stop
        $systemBom = @($systemRaw.Bom | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Version = $_.Version; PublicName = $_.PublicName } })
        foreach ($domain in $domains) {
            foreach ($expected in $systemBom) {
                $actual = switch -Regex ($expected.Name) {
                    'VCENTER' { Get-VcfDmFirstProperty ($vcenters | Where-Object DomainId -eq $domain.DomainId) 'Version'; break }
                    'ESX' { Get-VcfDmFirstProperty ($hosts | Where-Object DomainId -eq $domain.DomainId) 'CurrentESXVersion'; break }
                    'NSX' { Get-VcfDmFirstProperty ($nsxClusters | Where-Object { $_.DomainId -match [regex]::Escape($domain.DomainId) }) 'Version'; break }
                    'SDDC' { Get-VcfDmFirstProperty $sddcManagers 'Version'; break }
                    default { $null }
                }
                $status = Get-VcfDmBomStatus -ActualVersion $actual -ExpectedVersion $expected.Version
                $common = New-VcfDmCommonFields -Snapshot $Snapshot -VCFInstanceId $instanceId -VCFInstanceName $instanceName -DomainId $domain.DomainId -DomainName $domain.DomainName -SourceSystemType SDDC_MANAGER -SourceSystemId $ServerFqdn -SourceSystemFqdn $ServerFqdn
                Add-VcfDmDatasetRow -Snapshot $Snapshot -Dataset VCF_BOM -Row (New-VcfDmRow -Common $common -Fields ([ordered]@{
                    ComponentType = $expected.Name; ComponentName = $expected.PublicName; ActualVersion = $actual; ActualBuild = $null
                    CurrentReleaseExpectedVersion = $expected.Version; CurrentReleaseExpectedBuild = $null; VersionMatchesCurrentBOM = if ($status -eq 'CURRENT_DEPLOYED_BOM') { $true } elseif ($status -eq 'DRIFTED_FROM_DEPLOYED_BOM') { $false } else { $null }
                    TargetRelease = $domain.SelectedTargetRelease; TargetVersion = $null; LocalLatestKnownTargetVersion = $localLatest
                    ReferenceLatestKnownTargetVersion = $Snapshot.LifecycleKnowledge.ReferenceMetadataLatestKnownVersion; VersionDriftStatus = $status
                    DriftDetails = if ($status -eq 'DRIFTED_FROM_DEPLOYED_BOM') { "Expected $($expected.Version); actual $actual" } else { $null }
                    LifecycleKnowledgeScope = $Snapshot.LifecycleKnowledgeScope; AssessmentConfidence = if ($actual) { 'AUTHORITATIVE_LOCAL' } else { 'UNKNOWN' }
                }))
            }
        }
        Add-VcfDmStatusRow -Snapshot $Snapshot -CollectorName 'SDDCManager.BOM' -SourceSystemFqdn $ServerFqdn -StartedUTC $bomStarted -Status SUCCESS -RowsCollected @($Snapshot.Datasets.VCF_BOM).Count
    }
    catch {
        $category = Get-VcfDmErrorCategory $_; Add-VcfDmStatusRow -Snapshot $Snapshot -CollectorName 'SDDCManager.BOM' -SourceSystemFqdn $ServerFqdn -StartedUTC $bomStarted -Status (Get-VcfDmFailureStatus $category) -ErrorCategory $category -ErrorSummary (ConvertTo-VcfDmSafeErrorText $_.Exception.Message) -ErrorCount 1
    }
    finally { $systemRaw = $null }

    $catalogRows = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.ProductCatalog' -SourceSystemFqdn $ServerFqdn -Dataset VCF_ProductCatalog -RequiredCommand Invoke-VcfGetProductVersionCatalogContent -Operation {
        Invoke-VcfGetProductVersionCatalogContent -Server $ServerConnection -ErrorAction Stop
    } -Project { param($catalog) ConvertTo-VcfDmLiveCatalogRows $catalog }
    $catalogPublished = Get-VcfDmFirstProperty $catalogRows 'PublishedUTC'
    $catalogAgeDays = $null
    if ($catalogPublished) {
        $catalogDate = [datetime]::MinValue
        if ([datetime]::TryParse([string]$catalogPublished, [ref]$catalogDate)) { $catalogAgeDays = [math]::Max(0, [math]::Floor(([datetime]::UtcNow - $catalogDate.ToUniversalTime()).TotalDays)) }
    }
    foreach ($catalogRow in @($catalogRows)) { $catalogRow.CatalogAgeDays = $catalogAgeDays }
    foreach ($lifecycleRow in @($Snapshot.Datasets.VCF_Lifecycle)) { $lifecycleRow.CatalogPublishedUTC = $catalogPublished; $lifecycleRow.CatalogAgeDays = $catalogAgeDays }
    $Snapshot.LifecycleKnowledge.LocalCatalogPublishedUTC = $catalogPublished
    $Snapshot.LifecycleKnowledge.LocalCatalogAgeDays = $catalogAgeDays

    $depotRows = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.Depot' -SourceSystemFqdn $ServerFqdn -Dataset VCF_Depot -RequiredCommand Invoke-VcfGetDepotSyncInfo -Operation {
        [pscustomobject]@{ Sync = Invoke-VcfGetDepotSyncInfo -Server $ServerConnection -ErrorAction Stop; Bundles = Invoke-VcfGetBundles -Server $ServerConnection -ErrorAction Stop }
    } -Project {
        param($rawDepot)
        $sync = $rawDepot.Sync; $bundles = Get-VcfDmElements $rawDepot.Bundles
        New-VcfDmRow -Common $baseCommon -Fields ([ordered]@{
            DepotMode = 'UNKNOWN'; DepotUrl = $null; OnlineDepotStatus = $null; OfflineDepotStatus = $null
            SyncStatus = $sync.SyncStatus; LastSyncCompletionUTC = $sync.LastSyncCompletionTimestamp; SyncErrorMessage = ConvertTo-VcfDmSafeErrorText $sync.ErrorMessage
            KnownBundleCount = @($bundles).Count; DownloadedBundleCount = @($bundles | Where-Object { (Get-VcfDmPropertyValue $_ @('DownloadStatus', 'Status')) -match '(?i)DOWNLOADED|AVAILABLE' }).Count
            CatalogPublishedUTC = $catalogPublished; LifecycleKnowledgeScope = $Snapshot.LifecycleKnowledgeScope
        })
    }
    $Snapshot.LifecycleKnowledge.DepotSyncStatus = Get-VcfDmFirstProperty $depotRows 'SyncStatus'
    $Snapshot.LifecycleKnowledge.DepotLastSyncUTC = Get-VcfDmFirstProperty $depotRows 'LastSyncCompletionUTC'

    $null = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.ComponentDrift' -SourceSystemFqdn $ServerFqdn -Dataset VCF_ComponentDrift -RequiredCommand Invoke-VcfGetComponentVersionDrift -Operation {
        $all = @()
        # Component drift is queried only for identities that the public API
        # maps unambiguously in v0.1. NSX/ESX drift remains represented by the
        # independent deployed-BOM comparison when native drift is unavailable.
        foreach ($vc in $vcenters) { $all += Get-VcfDmElements (Invoke-VcfGetComponentVersionDrift -Server $ServerConnection -ComponentType VCENTER -ComponentId $vc.VCenterId -Size 1000 -ErrorAction Stop) }
        $all
    } -Project {
        param($response)
        foreach ($drift in Get-VcfDmElements $response) {
            New-VcfDmRow -Common $baseCommon -Fields ([ordered]@{
                DomainId = Get-VcfDmPropertyValue $drift @('DomainId'); ComponentType = $drift.ComponentType; ComponentId = $drift.ComponentId
                ComponentName = $drift.ComponentName; ExpectedVersion = Get-VcfDmPropertyValue $drift @('TargetVersion', 'ExpectedVersion')
                ActualVersion = Get-VcfDmPropertyValue $drift @('CurrentVersion', 'ActualVersion'); DriftDetected = Get-VcfDmPropertyValue $drift @('DriftDetected')
                DriftType = $drift.ComponentVersionStatus; DriftDetails = Get-VcfDmPropertyValue $drift @('StatusText', 'Details'); ImageCompliance = $null
            })
        }
    }

    $certificateRows = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.Certificates' -SourceSystemFqdn $ServerFqdn -Dataset VCF_Certificates -RequiredCommand Invoke-VcfGetCertificatesByDomain -Operation {
        # VCF 9.1 requires a positive pageNumber whenever pageSize is supplied;
        # omitting it causes the server to return VCF_RUNTIME_ERROR instead of page 1.
        $all = @(); foreach ($domain in $domains) { $all += Get-VcfDmElements (Invoke-VcfGetCertificatesByDomain -Server $ServerConnection -Id $domain.DomainId -PageNumber 1 -PageSize 1000 -ErrorAction Stop) }; $all
    } -Project {
        param($response)
        foreach ($certificate in @($response)) {
            $expires = Get-VcfDmPropertyValue $certificate @('NotAfter', 'ExpirationDate', 'ExpiresAt', 'ValidTo')
            $days = $null; if ($expires) { $expiryDate = [datetime]::MinValue; if ([datetime]::TryParse([string]$expires, [ref]$expiryDate)) { $days = [math]::Floor(($expiryDate.ToUniversalTime() - [datetime]::UtcNow).TotalDays) } }
            New-VcfDmRow -Common $baseCommon -Fields ([ordered]@{
                ResourceId = Get-VcfDmPropertyValue $certificate @('ResourceId', 'Id'); ResourceType = Get-VcfDmPropertyValue $certificate @('ResourceType', 'Type')
                ResourceName = Get-VcfDmPropertyValue $certificate @('ResourceName', 'Name', 'Fqdn'); DomainId = Get-VcfDmPropertyValue $certificate @('DomainId', 'Domain')
                CertificateSubject = Get-VcfDmPropertyValue $certificate @('Subject', 'CertificateSubject'); Issuer = Get-VcfDmPropertyValue $certificate @('Issuer', 'IssuedBy')
                SerialNumber = Get-VcfDmPropertyValue $certificate @('SerialNumber'); Thumbprint = Get-VcfDmPropertyValue $certificate @('Thumbprint', 'Fingerprint')
                SanDnsNames = Join-VcfDmValues (Get-VcfDmPropertyValue $certificate @('SubjectAlternativeNames', 'SubjectAlternativeName', 'SanDnsNames'))
                ValidFromUTC = Get-VcfDmPropertyValue $certificate @('NotBefore', 'StartDate', 'ValidFrom'); ExpiresUTC = $expires; DaysRemaining = $days
                AutoRenewConfigured = Get-VcfDmPropertyValue $certificate @('AutoRenewConfigured'); ValidationStatus = Get-VcfDmPropertyValue $certificate @('Status', 'ValidationStatus', 'ExpirationStatus')
                RiskState = if ($null -eq $days) { 'UNKNOWN' } elseif ($days -lt 0) { 'EXPIRED' } elseif ($days -le 30) { 'CRITICAL' } elseif ($days -le 90) { 'WARNING' } else { 'OK' }
            })
        }
    }

    $credentialQueries = [System.Collections.Generic.List[object]]::new()
    $credentialQueryKeys = @{}
    foreach ($domain in $domains) {
        $resourceTypes = @()
        if (@($hosts | Where-Object DomainId -eq $domain.DomainId).Count) { $resourceTypes += 'ESXI' }
        if (@($vcenters | Where-Object DomainId -eq $domain.DomainId).Count) { $resourceTypes += 'VCENTER' }
        if (@($nsxClusters | Where-Object DomainId -eq $domain.DomainId).Count) { $resourceTypes += 'NSXT_MANAGER' }
        if (@($edgeClusters | Where-Object DomainId -eq $domain.DomainId).Count) { $resourceTypes += 'NSXT_EDGE' }
        foreach ($resourceType in $resourceTypes) {
            $key = "$($domain.DomainName)|$resourceType"
            if (-not $credentialQueryKeys.ContainsKey($key)) {
                $credentialQueryKeys[$key] = $true
                $credentialQueries.Add([pscustomobject]@{ DomainId = $domain.DomainId; DomainName = $domain.DomainName; ResourceType = $resourceType })
            }
        }
    }
    if ($managementModel -eq 'VCF_MANAGEMENT_SERVICES') {
        $credentialQueries.Add([pscustomobject]@{ DomainId = $null; DomainName = $null; ResourceType = 'VSP' })
    }

    $credentialHealthRows = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.CredentialHealth' -SourceSystemFqdn $ServerFqdn -Dataset VCF_CredentialHealth -RequiredCommand Invoke-VcfGetPasswordExpiration -Operation {
        foreach ($query in $credentialQueries) {
            Invoke-VcfDmPasswordExpirationQuery -ServerConnection $ServerConnection -ResourceType $query.ResourceType -DomainId $query.DomainId -DomainName $query.DomainName
        }
    } -Project {
        param($response)
        foreach ($queryResult in @($response)) {
            $credential = $queryResult.Element
            $resource = $credential.Resource
            $expiration = $credential.Expiry
            $expires = Get-VcfDmPropertyValue $expiration @('ExpiryDate')
            $days = $null
            if ($expires) {
                $expiryDate = [datetime]::MinValue
                if ([datetime]::TryParse([string]$expires, [ref]$expiryDate)) {
                    $days = [math]::Floor(($expiryDate.ToUniversalTime() - [datetime]::UtcNow).TotalDays)
                }
            }
            $connectivityError = ConvertTo-VcfDmSafeErrorText (Get-VcfDmPropertyValue $expiration @('ConnectivityErrorDetails'))
            New-VcfDmRow -Common $baseCommon -Fields ([ordered]@{
                DomainId = $queryResult.DomainId
                DomainName = $queryResult.DomainName
                CredentialId = Get-VcfDmPropertyValue $credential @('Id')
                ResourceId = Get-VcfDmPropertyValue $resource @('ResourceId')
                RequestedResourceType = $queryResult.RequestedResourceType
                ResourceType = Get-VcfDmPropertyValue $resource @('ResourceType')
                ResourceName = Get-VcfDmPropertyValue $resource @('ResourceName')
                AccountName = Get-VcfDmPropertyValue $credential @('Username')
                CredentialType = 'PASSWORD'
                ExpiryUTC = $expires
                DaysRemaining = $days
                ExpirationStatus = Get-VcfDmPropertyValue $expiration @('Status')
                LastCheckedUTC = if (Get-VcfDmPropertyValue $expiration @('LastCheckedDate')) { Get-VcfDmPropertyValue $expiration @('LastCheckedDate') } else { $queryResult.TaskCompletionTimestamp }
                ConnectivityStatus = Get-VcfDmPropertyValue $expiration @('ConnectivityStatus')
                CollectionWarning = $connectivityError
                CollectionStatus = 'SUCCESS'
            })
        }
    }

    $null = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.Licensing' -SourceSystemFqdn $ServerFqdn -Dataset VCF_Licensing -RequiredCommand Invoke-VcfGetLicenseKeys -Operation {
        [pscustomobject]@{ System = Invoke-VcfGetSystemLicensingInfo -Server $ServerConnection -ErrorAction Stop; Keys = Invoke-VcfGetLicenseKeys -Server $ServerConnection -ErrorAction Stop }
    } -Project {
        param($response)
        foreach ($license in Get-VcfDmElements $response.Keys) {
            New-VcfDmRow -Common $baseCommon -Fields ([ordered]@{
                Scope = 'VCF_INSTANCE'; DomainId = $null; ProductType = $license.ProductType; LicenseEdition = Get-VcfDmPropertyValue $license @('Edition', 'ProductVersion')
                LicenseState = Get-VcfDmPropertyValue $license @('Status', 'LicenseKeyStatus'); ExpirationUTC = Get-VcfDmPropertyValue $license @('ExpirationDate')
                SubscriptionMode = Get-VcfDmPropertyValue $response.System @('SubscriptionMode', 'LicensingMode'); EntitlementSummary = Get-VcfDmPropertyValue $license @('Description')
                MaskedLicenseId = ConvertTo-VcfDmMaskedLicenseId (Get-VcfDmPropertyValue $license @('Key', 'LicenseKey', 'Id'))
            })
        }
    }

    $backupRows = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.Backups' -SourceSystemFqdn $ServerFqdn -Dataset VCF_Backups -RequiredCommand Invoke-VcfGetBackupConfiguration -Operation {
        Invoke-VcfGetBackupConfiguration -Server $ServerConnection -ErrorAction Stop
    } -Project {
        param($backup)
        $locations = @($backup.BackupLocations); if ($locations.Count -eq 0) { $locations = @($null) }
        foreach ($location in $locations) {
            New-VcfDmRow -Common $baseCommon -Fields ([ordered]@{
                ComponentType = 'SDDC_MANAGER'; ComponentName = $ServerFqdn; BackupConfigured = $backup.IsConfigured
                BackupProtocol = if ($location) { $location.Protocol } else { $null }; BackupServer = if ($location) { $location.Server } else { $null }
                BackupPath = if ($location) { $location.DirectoryPath } else { $null }; Schedule = Join-VcfDmValues $backup.BackupSchedules @('Name', 'Type')
                Retention = Get-VcfDmPropertyValue $backup @('RetentionPolicy', 'BackupRetentionPolicy'); LastKnownBackupUTC = $null
                LastKnownBackupStatus = $null; BackupLocationReachability = $null
            })
        }
    }

    $complianceRows = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.Compliance' -SourceSystemFqdn $ServerFqdn -Dataset VCF_Compliance -RequiredCommand Invoke-VcfGetComplianceAuditHistory -Operation {
        Invoke-VcfGetComplianceAuditHistory -Server $ServerConnection -ErrorAction Stop
    } -Project {
        param($response)
        foreach ($audit in Get-VcfDmElements $response) {
            New-VcfDmRow -Common $baseCommon -Fields ([ordered]@{
                AuditId = $audit.Id; DomainId = Get-VcfDmPropertyValue $audit @('DomainId'); StandardId = Get-VcfDmPropertyValue $audit @('StandardId')
                StandardName = Get-VcfDmPropertyValue $audit @('StandardName'); ConfigurationId = Get-VcfDmPropertyValue $audit @('ConfigurationId')
                ResourceId = Get-VcfDmPropertyValue $audit @('ResourceId'); ResourceType = Get-VcfDmPropertyValue $audit @('ResourceType')
                FindingId = Get-VcfDmPropertyValue $audit @('FindingId'); FindingSeverity = Get-VcfDmPropertyValue $audit @('Severity', 'FindingSeverity')
                FindingStatus = Get-VcfDmPropertyValue $audit @('Status', 'FindingStatus'); FindingDescription = Get-VcfDmPropertyValue $audit @('Description', 'FindingDescription')
                RemediationSummary = Get-VcfDmPropertyValue $audit @('Remediation', 'RemediationSummary'); AuditUTC = Get-VcfDmPropertyValue $audit @('CreationTime', 'AuditTime')
            })
        }
    }

    $fipsRows = Invoke-VcfDmProjectedCollector -Snapshot $Snapshot -CollectorName 'SDDCManager.FIPS' -SourceSystemFqdn $ServerFqdn -Dataset VCF_FIPS -RequiredCommand Invoke-VcfGetFIPSConfiguration -Operation {
        [pscustomobject]@{ Config = Invoke-VcfGetFIPSConfiguration -Server $ServerConnection -ErrorAction Stop; Module = Invoke-VcfGetFIPSModuleInfo -Server $ServerConnection -ErrorAction Stop }
    } -Project {
        param($response)
        New-VcfDmRow -Common $baseCommon -Fields ([ordered]@{
            FipsEnabled = $response.Config.Enabled; ModuleName = Get-VcfDmPropertyValue $response.Module @('Name', 'ModuleName')
            ModuleVersion = Get-VcfDmPropertyValue $response.Module @('Version', 'ModuleVersion'); ModuleStatus = Get-VcfDmPropertyValue $response.Module @('Status', 'ModuleStatus')
        })
    }

    foreach ($managerRow in $sddcManagers) {
        $managerRow.FipsMode = Get-VcfDmFirstProperty $fipsRows 'FipsEnabled'
        $managerRow.BackupConfigured = Get-VcfDmFirstProperty $backupRows 'BackupConfigured'
        $managerRow.CertificateExpiryUTC = Get-VcfDmFirstProperty ($certificateRows | Where-Object ResourceName -eq $managerRow.Fqdn) 'ExpiresUTC'
    }

    $summaryFields = [ordered]@{
        ManagementDomainId = if ($managementDomain.Count) { $managementDomain[0].DomainId } else { $null }; ManagementDomainName = if ($managementDomain.Count) { $managementDomain[0].DomainName } else { $null }
        SystemRelease = $systemRelease; DomainCount = $domains.Count; ClusterCount = $clusters.Count; HostCount = $hosts.Count; VCenterCount = $vcenters.Count
        NSXClusterCount = $nsxClusters.Count; VCFOpsPresent = @($managementComponents | Where-Object ComponentType -eq OPERATIONS).Count -gt 0
        ManagementServicesPresent = $managementModel -eq 'VCF_MANAGEMENT_SERVICES'; LifecycleKnowledgeScope = $Snapshot.LifecycleKnowledgeScope
        DepotMode = Get-VcfDmFirstProperty $depotRows 'DepotMode'; DepotSyncStatus = Get-VcfDmFirstProperty $depotRows 'SyncStatus'
        DepotLastSyncUTC = Get-VcfDmFirstProperty $depotRows 'LastSyncCompletionUTC'; CatalogPublishedUTC = $catalogPublished
        LifecycleOverallStatus = if (@($Snapshot.Datasets['VCF_BOM'] | Where-Object { $_.VersionDriftStatus -eq 'DRIFTED_FROM_DEPLOYED_BOM' }).Count) { 'DRIFT_DETECTED' } else { 'NO_DRIFT_DETECTED_OR_UNKNOWN' }
        CertificateRiskCount = @($certificateRows | Where-Object { $_.RiskState -in @('EXPIRED', 'CRITICAL', 'WARNING') }).Count
        CredentialExpiryRiskCount = @($credentialHealthRows | Where-Object { $_.ExpirationStatus -in @('EXPIRED', 'CRITICAL', 'WARNING') }).Count
        ComplianceFindingCount = @($complianceRows).Count; BackupStatus = if (@($backupRows | Where-Object { $_.BackupConfigured }).Count) { 'CONFIGURED' } else { 'NOT_CONFIGURED_OR_UNKNOWN' }
    }
    Add-VcfDmDatasetRow -Snapshot $Snapshot -Dataset VCF_Summary -Row (New-VcfDmRow -Common $baseCommon -Fields $summaryFields)
    Add-VcfDmStatusRow -Snapshot $Snapshot -CollectorName 'SDDCManager.Summary' -SourceSystemFqdn $ServerFqdn -StartedUTC ([datetime]::UtcNow) -Status SUCCESS -RowsCollected 1

    $Snapshot.Sources = @($Snapshot.Sources) + @([pscustomobject][ordered]@{ SourceSystemType = 'SDDC_MANAGER'; SourceSystemId = $ServerFqdn; SourceSystemFqdn = $ServerFqdn; VCFInstanceId = $instanceId })
    $Snapshot.LifecycleKnowledge.DeployedVersion = $systemRelease
    $Snapshot.LifecycleKnowledge.LocalCatalogLatestKnownVersion = $localLatest
    return [pscustomobject]@{ VCFInstanceId = $instanceId; VCFInstanceName = $instanceName; SystemRelease = $systemRelease; Domains = $domains; vCenters = $vcenters; ManagementModel = $managementModel }
}

Export-ModuleMember -Function 'Invoke-VcfDmSddcManagerCollection'
