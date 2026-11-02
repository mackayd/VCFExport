Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Core\VcfDm.Model.psm1') -ErrorAction Stop
Import-Module (Join-Path $root 'Core\VcfDm.Security.psm1') -ErrorAction Stop
Import-Module (Join-Path $root 'Core\VcfDm.Status.psm1') -ErrorAction Stop

function New-VcfDmInventoryRuntime {
    # Each vCenter gets isolated caches and an explicitly scoped SDK session.
    $functionsPath = Join-Path $PSScriptRoot 'VcfDm.Inventory.Functions.ps1'
    return New-Module -Name VcfExportInventoryRuntime -ArgumentList $functionsPath -ScriptBlock {
        param($FunctionsPath)
        Set-StrictMode -Off # Optional SDK fields can be absent on supported object types.
        . $FunctionsPath
        function Write-InlineProgress { } # Progress is provided by the enclosing collector.
        function Get-RemoteCertificateInfo {
            param($ComputerName)
            # Read certificate metadata through the already authenticated vCenter session.
            $hostObject = $script:HostObjects | Where-Object Name -EQ $ComputerName | Select-Object -First 1
            if ($hostObject.ExtensionData.ConfigManager.CertificateManager) {
                $manager = Get-View -Id $hostObject.ExtensionData.ConfigManager.CertificateManager -Property CertificateInfo -Server $script:Server
                $cert = $manager.CertificateInfo
                if ($cert) { return [pscustomobject]@{Subject=$cert.Subject; Issuer=$cert.Issuer; NotBefore=$cert.NotBefore; NotAfter=$cert.NotAfter} }
            }
        }
        function Initialize-InventorySession {
            param($Server)
            $script:Server = $Server
            # Scope every SDK lookup to this vCenter, even in an existing multi-server shell.
            $script:PSDefaultParameterValues = @{}
            foreach ($command in @('Get-View','Get-VM','Get-Template','Get-VMHost','Get-Cluster','Get-Datacenter','Get-ResourcePool','Get-Datastore','Get-AdvancedSetting','Get-HardDisk','Get-VMGuestDisk','Get-ScsiController','Get-Snapshot','Get-VMHostNetwork','Get-VMHostNetworkAdapter','Get-VMHostService','Get-VirtualSwitch','Get-VirtualPortGroup','Get-VDSwitch','Get-VDPortgroup','Get-EsxCli','Get-VIEvent')) {
                if ((Get-Command $command -ErrorAction SilentlyContinue).Parameters.ContainsKey('Server')) {
                    $script:PSDefaultParameterValues["${command}:Server"] = $Server
                }
            }
            $script:VMObjects = @(Get-VM -Server $Server; Get-Template -Server $Server) | Sort-Object Id -Unique
            $script:HostObjects = @(Get-VMHost -Server $Server)
            $script:Clusters = @(Get-Cluster -Server $Server)
            $script:Pools = @(Get-ResourcePool -Server $Server)
            $script:Stores = @(Get-Datastore -Server $Server)
            $script:About = (Get-View -Id ServiceInstance -Server $Server).Content.About
        }
        function Invoke-InventoryDataset {
            param([string]$Name)
            $ErrorActionPreference = 'Stop'
            $vmArgs = @{vms=$script:VMObjects; about=$script:About; GetVMContextFn=${function:Get-VMContext}}
            switch ($Name) {
                {$_ -in @('vInfo','vCPU','vMemory','vDisk','vPartition','vSCSI','vNetwork','vFloppy','vCD','vSnapshot')} { & "Get-$Name" @vmArgs }
                'vTools' { Get-vTools @vmArgs -PlatformToolsRequiredVersion 'UNKNOWN (offline; inspect ToolsStatus2)' }
                'vRP' { Get-vRP -rpools $script:Pools -about $script:About }
                'vCluster' { Get-vCluster -clusters $script:Clusters -about $script:About }
                {$_ -in @('vHost','vHBA','vNIC','vSwitch','vPort','vSC_VMK')} { & "Get-$Name" -ESXhosts $script:HostObjects -about $script:About }
                'vTLShost' {
                    foreach ($hostObject in $script:HostObjects) {
                        $cli = Get-EsxCli -VMHost $hostObject -V2 -Server $script:Server
                        $serverProfile = $cli.system.tls.server.get.Invoke().Profile
                        $protocols = $null
                        if ($serverProfile -eq 'MANUAL') {
                            $tlsArgs = $cli.system.tls.server.get.CreateArgs(); $tlsArgs.protocolversions = $true
                            $protocols = $cli.system.tls.server.get.Invoke($tlsArgs).ProtocolVersions -join ','
                        }
                        [pscustomobject]@{Name=$hostObject.Name; ServerTLSProfile=$serverProfile; ClientTLSProfile=$cli.system.tls.client.get.Invoke().Profile; DisabledProtocols=($hostObject.ExtensionData.Config.Option | Where-Object Key -EQ 'UserVars.ESXiVPsDisabledProtocols').Value; ExplicitProtocols=$protocols}
                    }
                }
                'dvSwitch' { Get-vdvSwitch -about $script:About -Server $script:Server }
                'dvPort' { Get-vdvPort -about $script:About -Server $script:Server }
                'vDatastore' { Get-vDatastore -datastores $script:Stores -about $script:About }
                'vLicense' { Get-vLicense -about $script:About -Server $script:Server }
                'vHealth' {
                    # Request only alarm events at the server; retain the original 14-day scope.
                    $si = Get-View -Id ServiceInstance -Server $script:Server
                    $manager = Get-View -Id $si.Content.EventManager -Server $script:Server
                    $filter = New-Object VMware.Vim.EventFilterSpec
                    $filter.EventTypeId = @('AlarmStatusChangedEvent')
                    $filter.Time = New-Object VMware.Vim.EventFilterSpecByTime
                    $filter.Time.BeginTime = [datetime]::UtcNow.AddDays(-14)
                    $ref = $manager.CreateCollectorForEvents($filter)
                    $reader = Get-View -Id $ref -Server $script:Server
                    try {
                        $reader.RewindCollector()
                        do {
                            $batch = @($reader.ReadNextEvents(200))
                            foreach ($event in $batch | Where-Object { $_.To -in @('yellow','red') }) {
                                [pscustomobject]@{AlarmName=$event.Alarm.Name; AlarmStatus=[string]$event.To; AlarmData=$event.CreatedTime; CreatedUTC=$event.CreatedTime; EntityId=$event.Entity.Entity.Value; Entity=$event.Entity.Name; Message=$event.FullFormattedMessage; EventId=$event.Key; 'VI SDK Server'=$script:About.FullName; 'VI SDK UUID'=$script:About.InstanceUuid}
                            }
                        } while ($batch.Count -gt 0)
                    } finally { $reader.DestroyCollector() }
                }
                'vZombieFiles' {
                    foreach ($ds in $script:Stores | Where-Object { $_.Type -in @('VMFS','vsan') -and $_.ExtensionData.Summary.MultipleHostAccess }) {
                        $known = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                        foreach ($vm in $script:VMObjects) { foreach ($file in $vm.ExtensionData.LayoutEx.File) { if ($file.Name) { [void]$known.Add(($file.Name -replace '/+','/')) } } }
                        $browser = Get-View -Id $ds.ExtensionData.Browser -Server $script:Server
                        $spec = New-Object VMware.Vim.HostDatastoreBrowserSearchSpec
                        $spec.MatchPattern = @('*.vmdk','*.vmx')
                        $spec.Details = New-Object VMware.Vim.FileQueryFlags
                        $spec.Details.FileSize = $true; $spec.Details.Modification = $true
                        foreach ($folder in $browser.SearchDatastoreSubFolders("[$($ds.Name)]", $spec)) {
                            foreach ($file in $folder.File) {
                                $path = ($folder.FolderPath.TrimEnd('/') + '/' + $file.Path) -replace '/+','/'
                                if (-not $known.Contains($path)) { [pscustomobject]@{Datastore=$ds.Name; DatastoreId=$ds.ExtensionData.MoRef.Value; FilePath=$path; FileSizeGB=[math]::Round($file.FileSize/1GB,3); Modified=$file.Modification; Finding='UNREFERENCED_CANDIDATE'; Note='Review before removal; this tool never deletes files.'; 'VI SDK Server'=$script:About.FullName; 'VI SDK UUID'=$script:About.InstanceUuid} }
                            }
                        }
                    }
                }
            }
        }
        Export-ModuleMember -Function Initialize-InventorySession,Invoke-InventoryDataset
    }
}

function ConvertTo-VcfDmInventoryRow {
    param($Row, [string]$Dataset, $Snapshot, [string]$VCenterFqdn, [int]$Index)
    $fields = [ordered]@{}
    foreach ($property in $Row.PSObject.Properties) {
        if ($property.Name -in @('LicenseKey','AssignedLicenses')) {
            $fields['MaskedLicenseId'] = ConvertTo-VcfDmMaskedLicenseId -Value ([string]$property.Value)
        } else {
            $value = $property.Value
            $fields[$property.Name] = if ($value -is [enum]) { [string]$value } elseif ($null -eq $value -or $value -is [string] -or $value -is [datetime] -or $value.GetType().IsPrimitive -or $value -is [decimal]) { $value } else { $value | ConvertTo-Json -Depth 8 -Compress }
        }
    }
    $fields['Source vCenter'] = $VCenterFqdn
    $fields['SnapshotId'] = $Snapshot.SnapshotId
    $fields['CollectedUTC'] = $Snapshot.CollectedUTC
    $fields['InventoryDataset'] = $Dataset
    $fields['InventoryRowId'] = Get-VcfDmObjectId -VCFInstanceId $VCenterFqdn -SourceSystemFqdn $VCenterFqdn -ObjectType INVENTORY_ROW -NativeObjectId "$Dataset/$Index"
    $vmId = Get-VcfDmPropertyValue $Row @('VM ID','VM_ID')
    if ($vmId) { $fields['VMId'] = [string]$vmId }
    $hostName = if ($Dataset -in @('vHost','vTLShost')) { Get-VcfDmPropertyValue $Row @('Name','Host') } else { Get-VcfDmPropertyValue $Row @('Host') }
    $hostRows = @($Snapshot.VSphere.vHost | Where-Object { $_.'Source vCenter' -eq $VCenterFqdn -and $_.Name -eq $hostName })
    if ($hostRows.Count -eq 1) { $fields['HostId'] = $hostRows[0].HostId }
    if ($Dataset -eq 'vHost' -and $fields.Contains('MemoryGB')) {
        $fields['MemoryMiB'] = $fields['MemoryGB']
        $fields['MemoryGB'] = [math]::Round([double]$fields['MemoryMiB']/1024,2)
        # Project swapped and ballooned memory from the VMs placed on this host.
        $vmIds = @($Snapshot.VSphere.vInfo | Where-Object { $_.'Source vCenter' -eq $VCenterFqdn -and $_.HostId -eq $fields.HostId } | ForEach-Object VMId)
        $memory = @($Snapshot.VSphere.vMemory | Where-Object { $_.'Source vCenter' -eq $VCenterFqdn -and $_.VMId -in $vmIds })
        $fields['VMMemorySwapped'] = ($memory | Measure-Object SwappedMiB -Sum).Sum
        $fields['VMMemoryBallooned'] = ($memory | Measure-Object BalloonedMiB -Sum).Sum
    }
    $nativeId = Get-VcfDmPropertyValue $Row @('ObjectID','Object ID')
    if ($nativeId) { $fields['NativeObjectId'] = [string]$nativeId }
    if ($Dataset -in @('dvSwitch','dvPort')) {
        $target = if ($Dataset -eq 'dvSwitch') { 'dvSwitches' } else { 'dvPorts' }
        $related = @($Snapshot.VSphere[$target] | Where-Object { $_.'Source vCenter' -eq $VCenterFqdn -and $_.Name -eq $fields.Name })
        if ($related.Count -eq 1) { $fields['NativeObjectId'] = if ($Dataset -eq 'dvSwitch') { $related[0].VDSwitchId } else { $related[0].PortgroupId } }
    }
    return [pscustomobject]$fields
}

function Invoke-VcfDmInventoryCollection {
    param($Snapshot, $Server, [string]$VCenterFqdn, [switch]$SkipDatastoreFileScan)
    $runtime = $null
    try {
        $runtime = New-VcfDmInventoryRuntime
        & $runtime { param($s) Initialize-InventorySession -Server $s } $Server
        foreach ($dataset in Get-VcfDmDatasetNames -Inventory) {
            $started = [datetime]::UtcNow; $status = 'SUCCESS'; $message = $null; $count = 0
            try {
                if ($dataset -eq 'vZombieFiles' -and $SkipDatastoreFileScan) { $status = 'NOT_REQUESTED'; $message = 'Datastore file scan skipped by operator.' }
                else {
                    $result = @(& $runtime {param($name) Invoke-InventoryDataset -Name $name} $dataset)
                    foreach ($row in $result) {
                        $count++
                        Add-VcfDmDatasetRow -Snapshot $Snapshot -Dataset $dataset -Inventory -Row (ConvertTo-VcfDmInventoryRow $row $dataset $Snapshot $VCenterFqdn $count)
                    }
                }
            } catch { $status = 'COLLECTION_FAILED'; $message = ConvertTo-VcfDmSafeErrorText $_.Exception.Message }
            $statusRow = New-VcfDmCollectionStatus -CollectorName "Inventory.$dataset" -SourceSystemType VCENTER -SourceSystemFqdn $VCenterFqdn -StartedUTC $started -CompletedUTC ([datetime]::UtcNow) -Status $status -RowsCollected $count -ErrorCount $(if ($status -eq 'COLLECTION_FAILED') {1} else {0}) -ErrorSummary $message -ApiVersion 'vSphere SDK' -CollectorVersion (Get-VcfDmCollectorVersion)
            Add-VcfDmDatasetRow -Snapshot $Snapshot -Dataset VCF_CollectionStatus -Row $statusRow
        }
    } finally { if ($runtime) { Remove-Module $runtime -ErrorAction SilentlyContinue } }
}

Export-ModuleMember -Function Invoke-VcfDmInventoryCollection
