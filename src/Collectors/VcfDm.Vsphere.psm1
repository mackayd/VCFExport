Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Core\VcfDm.Model.psm1') -ErrorAction Stop
Import-Module (Join-Path $root 'Core\VcfDm.Security.psm1') -ErrorAction Stop
Import-Module (Join-Path $root 'Core\VcfDm.Status.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'VcfDm.Inventory.psm1') -ErrorAction Stop

function Get-VcfDmVsphereContext {
    param([System.Collections.IDictionary] $Snapshot, [string] $VCenterFqdn)
    $vcRows = @($Snapshot.Datasets.VCF_vCenters | Where-Object { $_.VCenterFqdn -ieq $VCenterFqdn })
    $vc = if ($vcRows.Count) { $vcRows[0] } else { $null }
    $instanceId = if ($vc) { $vc.VCFInstanceId } else { Get-VcfDmObjectId -VCFInstanceId $VCenterFqdn -SourceSystemId $VCenterFqdn -SourceSystemFqdn $VCenterFqdn -ObjectType VCF_INSTANCE -NativeObjectId $VCenterFqdn }
    return [pscustomobject]@{
        VCFInstanceId = $instanceId
        VCFInstanceName = if ($vc) { $vc.VCFInstanceName } else { $VCenterFqdn }
        DomainId = if ($vc) { $vc.DomainId } else { $null }
        DomainName = if ($vc) { $vc.DomainName } else { $null }
        VCenterId = if ($vc) { $vc.VCenterId } else { $VCenterFqdn }
    }
}

function New-VcfDmVsphereRow {
    param(
        [System.Collections.IDictionary] $Snapshot,
        $Context,
        [string] $VCenterFqdn,
        [string] $ObjectType,
        [string] $NativeObjectId,
        [string] $ObjectName,
        [System.Collections.IDictionary] $Fields
    )
    $row = [ordered]@{
        SnapshotId      = $Snapshot.SnapshotId
        CollectedUTC    = $Snapshot.CollectedUTC
        CollectorVersion = $Snapshot.CollectorVersion
        SchemaVersion   = $Snapshot.SchemaVersion
        'VCF Instance'  = $Context.VCFInstanceName
        'VCF Instance Id' = $Context.VCFInstanceId
        'VCF Domain'    = $Context.DomainName
        'VCF Domain Id' = $Context.DomainId
        'Source vCenter' = $VCenterFqdn
        'VCF Object Id' = Get-VcfDmObjectId -VCFInstanceId $Context.VCFInstanceId -SourceSystemId $Context.VCenterId -SourceSystemFqdn $VCenterFqdn -ObjectType $ObjectType -NativeObjectId $NativeObjectId -ObjectName $ObjectName
    }
    foreach ($key in $Fields.Keys) { $row[$key] = $Fields[$key] }
    return [pscustomobject]$row
}

function Add-VcfDmVsphereRows {
    param([System.Collections.IDictionary] $Snapshot, [string] $Dataset, $Rows)
    foreach ($row in @($Rows)) {
        if ($null -ne $row) { Add-VcfDmDatasetRow -Snapshot $Snapshot -Dataset $Dataset -Row $row -VSphere }
    }
}

function Get-VcfDmSnapshotNodes {
    param($Nodes)
    foreach ($node in @($Nodes)) {
        if ($null -eq $node) { continue }
        $node
        $children = Get-VcfDmPropertyValue -InputObject $node -Path @('ChildSnapshotList')
        if ($children) { Get-VcfDmSnapshotNodes -Nodes $children }
    }
}

function Add-VcfDmVsphereStatus {
    param(
        [System.Collections.IDictionary] $Snapshot,
        [string] $VCenterFqdn,
        [datetime] $Started,
        [string] $Status,
        [int] $Rows,
        [string] $Category,
        [string] $Summary
    )
    $statusRow = New-VcfDmCollectionStatus -CollectorName "vSphere.Inventory.$VCenterFqdn" -SourceSystemType VCENTER -SourceSystemFqdn $VCenterFqdn -StartedUTC $Started -CompletedUTC ([datetime]::UtcNow) -Status $Status -RowsCollected $Rows -ErrorCount $(if ($Status -eq 'SUCCESS') { 0 } else { 1 }) -ErrorCategory $Category -ErrorSummary $Summary -AuthenticationMode PSCredential -ApiVersion 'vSphere SDK' -CollectorVersion $Snapshot.CollectorVersion
    Add-VcfDmDatasetRow -Snapshot $Snapshot -Dataset VCF_CollectionStatus -Row $statusRow
}

function Invoke-VcfDmVsphereCollection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Snapshot,
        [Parameter(Mandatory)] [string[]] $VCenterFqdn,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [hashtable] $ServerAddressMap = @{},
        [switch] $SkipCertificateCheck,
        [switch] $SkipDatastoreFileScan
    )

    Import-Module VMware.VimAutomation.Core -MinimumVersion 13.5.0 -ErrorAction Stop -WarningAction SilentlyContinue
    if ($SkipCertificateCheck) {
        Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
    }

    foreach ($sourceVCenter in $VCenterFqdn) {
        $started = [datetime]::UtcNow
        $serverAddress = if ($ServerAddressMap.ContainsKey($sourceVCenter)) { [string]$ServerAddressMap[$sourceVCenter] } else { $sourceVCenter }
        $viServer = $null
        try {
            $viServer = Connect-VIServer -Server $serverAddress -Credential $Credential -Force -ErrorAction Stop
            $context = Get-VcfDmVsphereContext -Snapshot $Snapshot -VCenterFqdn $sourceVCenter

            $vmProperties = @('Name','Runtime','Config','ConfigStatus','Guest','Summary','Snapshot','Datastore','Network','ResourcePool','ResourceConfig','Parent','LayoutEx')
            $hostProperties = @('Name','Runtime','Summary','Hardware','Config','Datastore','Vm','Parent')
            $clusterProperties = @('Name','Summary','ConfigurationEx','Host','Datastore','OverallStatus','Parent')
            $datastoreProperties = @('Name','Summary','Info','Host','Vm','OverallStatus','Parent')
            $vms = @(Get-View -ViewType VirtualMachine -Property $vmProperties -Server $viServer -ErrorAction Stop)
            $hosts = @(Get-View -ViewType HostSystem -Property $hostProperties -Server $viServer -ErrorAction Stop)
            $clusters = @(Get-View -ViewType ClusterComputeResource -Property $clusterProperties -Server $viServer -ErrorAction Stop)
            $datastores = @(Get-View -ViewType Datastore -Property $datastoreProperties -Server $viServer -ErrorAction Stop)
            $resourcePools = @(Get-View -ViewType ResourcePool -Property @('Name','Summary','Config','Owner','Vm','ResourcePool') -Server $viServer -ErrorAction Stop)

            $hostById = @{}
            foreach ($hostView in $hosts) { $hostById[[string]$hostView.MoRef.Value] = $hostView }
            $clusterById = @{}
            foreach ($clusterView in $clusters) { $clusterById[[string]$clusterView.MoRef.Value] = $clusterView }

            foreach ($vm in $vms) {
                $vmId = $vm.MoRef.Value
                $hostId = if ($vm.Runtime.Host) { [string]$vm.Runtime.Host.Value } else { $null }
                $hostForVm = if ($hostId -and $hostById.ContainsKey($hostId)) { $hostById[$hostId] } else { $null }
                $clusterId = if ($hostForVm -and $hostForVm.Parent) { [string]$hostForVm.Parent.Value } else { $null }
                $clusterForVm = if ($clusterId -and $clusterById.ContainsKey($clusterId)) { $clusterById[$clusterId] } else { $null }
                $devices = @($vm.Config.Hardware.Device)
                $disks = @($devices | Where-Object { $_.GetType().Name -eq 'VirtualDisk' })
                $nics = @($devices | Where-Object { $_.GetType().Name -match '^Virtual(E1000|Vmxnet|Sriov)' })
                $guestNetworks = @(Get-VcfDmPropertyValue $vm @('Guest.Net'))
                $guestIps = @($guestNetworks | ForEach-Object { Get-VcfDmPropertyValue $_ @('IpAddress') } | Where-Object { $_ })
                Add-VcfDmVsphereRows -Snapshot $Snapshot -Dataset vInfo -Rows (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter VM $vmId $vm.Name ([ordered]@{
                    Name = $vm.Name; PowerState = [string]$vm.Runtime.PowerState; Template = [bool]$vm.Config.Template
                    ConfigStatus = [string]$vm.ConfigStatus; GuestState = [string]$vm.Guest.GuestState; GuestHostName = $vm.Guest.HostName
                    PrimaryIpAddress = @($guestIps | Select-Object -First 1); CpuCount = $vm.Config.Hardware.NumCPU
                    MemoryGiB = [math]::Round($vm.Config.Hardware.MemoryMB / 1024, 2); NicCount = $nics.Count; DiskCount = $disks.Count
                    ProvisionedGiB = [math]::Round($vm.Summary.Storage.Committed / 1GB, 2); UncommittedGiB = [math]::Round($vm.Summary.Storage.Uncommitted / 1GB, 2)
                    GuestConfigured = $vm.Config.GuestFullName; GuestTools = $vm.Guest.GuestFullName; HardwareVersion = $vm.Config.Version
                    Firmware = $vm.Config.Firmware; ChangeVersion = $vm.Config.ChangeVersion; InstanceUuid = $vm.Config.InstanceUuid; BiosUuid = $vm.Config.Uuid
                    Annotation = $vm.Config.Annotation; ConnectionState = [string]$vm.Runtime.ConnectionState; BootTime = $vm.Runtime.BootTime
                    VMId = $vmId; HostId = $hostId; HostName = if ($hostForVm) { $hostForVm.Name } else { $null }
                    ClusterId = $clusterId; ClusterName = if ($clusterForVm) { $clusterForVm.Name } else { $null }
                    ResourcePoolId = if ($vm.ResourcePool) { $vm.ResourcePool.Value } else { $null }
                    DatastoreIds = @($vm.Datastore | ForEach-Object { $_.Value }) -join ';'
                    NetworkIds = @($vm.Network | ForEach-Object { $_.Value }) -join ';'
                }))
                Add-VcfDmVsphereRows $Snapshot vCPU (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter VM_CPU $vmId $vm.Name ([ordered]@{ VMId = $vmId; VM = $vm.Name; CPUs = $vm.Config.Hardware.NumCPU; CoresPerSocket = $vm.Config.Hardware.NumCoresPerSocket; CpuHotAddEnabled = $vm.Config.CpuHotAddEnabled; CpuHotRemoveEnabled = $vm.Config.CpuHotRemoveEnabled; ReservationMHz = $vm.ResourceConfig.CpuAllocation.Reservation; LimitMHz = $vm.ResourceConfig.CpuAllocation.Limit; Shares = $vm.ResourceConfig.CpuAllocation.Shares.Shares }))
                Add-VcfDmVsphereRows $Snapshot vMemory (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter VM_MEMORY $vmId $vm.Name ([ordered]@{ VMId = $vmId; VM = $vm.Name; MemoryGiB = [math]::Round($vm.Config.Hardware.MemoryMB / 1024, 2); ReservationMiB = $vm.ResourceConfig.MemoryAllocation.Reservation; LimitMiB = $vm.ResourceConfig.MemoryAllocation.Limit; Shares = $vm.ResourceConfig.MemoryAllocation.Shares.Shares; HotAddEnabled = $vm.Config.MemoryHotAddEnabled; BalloonedMiB = [math]::Round($vm.Summary.QuickStats.BalloonedMemory, 2); SwappedMiB = [math]::Round($vm.Summary.QuickStats.SwappedMemory, 2) }))

                foreach ($disk in $disks) {
                    Add-VcfDmVsphereRows $Snapshot vDisk (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter VIRTUAL_DISK "$vmId/$($disk.Key)" "$($vm.Name)/$($disk.DeviceInfo.Label)" ([ordered]@{ VMId = $vmId; VM = $vm.Name; Disk = $disk.DeviceInfo.Label; CapacityGiB = [math]::Round($disk.CapacityInBytes / 1GB, 2); FileName = $disk.Backing.FileName; DatastoreId = Get-VcfDmPropertyValue $disk @('Backing.Datastore.Value'); DiskMode = $disk.Backing.DiskMode; ThinProvisioned = $disk.Backing.ThinProvisioned; EagerlyScrub = $disk.Backing.EagerlyScrub; ControllerKey = $disk.ControllerKey; UnitNumber = $disk.UnitNumber }))
                }
                foreach ($guestDisk in @($vm.Guest.Disk)) {
                    if ($null -eq $guestDisk) { continue }
                    $diskPath = Get-VcfDmPropertyValue $guestDisk @('DiskPath', 'Path')
                    if (-not $diskPath) { continue }
                    $capacity = Get-VcfDmPropertyValue $guestDisk @('Capacity')
                    $freeSpace = Get-VcfDmPropertyValue $guestDisk @('FreeSpace')
                    Add-VcfDmVsphereRows $Snapshot vPartition (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter GUEST_PARTITION "$vmId/$diskPath" "$($vm.Name)/$diskPath" ([ordered]@{ VMId = $vmId; VM = $vm.Name; Path = $diskPath; CapacityGiB = if ($capacity) { [math]::Round($capacity / 1GB, 2) } else { $null }; FreeGiB = if ($null -ne $freeSpace) { [math]::Round($freeSpace / 1GB, 2) } else { $null } }))
                }
                foreach ($controller in @($devices | Where-Object { $_.GetType().Name -match '(?i)(SCSI|LsiLogic|ParaVirtual).*Controller$' })) {
                    Add-VcfDmVsphereRows $Snapshot vSCSI (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter SCSI_CONTROLLER "$vmId/$($controller.Key)" "$($vm.Name)/$($controller.DeviceInfo.Label)" ([ordered]@{ VMId = $vmId; VM = $vm.Name; Controller = $controller.DeviceInfo.Label; Type = $controller.GetType().Name; BusNumber = $controller.BusNumber; SharedBus = [string]$controller.SharedBus; DeviceCount = @($controller.Device).Count }))
                }
                foreach ($nic in $nics) {
                    $distributedPortgroupId = Get-VcfDmPropertyValue $nic @('Backing.Port.PortgroupKey')
                    $networkName = Get-VcfDmPropertyValue $nic @('Backing.DeviceName', 'Backing.Port.PortgroupKey')
                    Add-VcfDmVsphereRows $Snapshot vNetwork (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter VM_NIC "$vmId/$($nic.Key)" "$($vm.Name)/$($nic.DeviceInfo.Label)" ([ordered]@{ VMId = $vmId; VM = $vm.Name; Adapter = $nic.DeviceInfo.Label; AdapterType = $nic.GetType().Name; NetworkId = $distributedPortgroupId; NetworkReferenceType = if ($distributedPortgroupId) { 'DISTRIBUTED_PORTGROUP_ID' } else { 'STANDARD_PORTGROUP_NAME' }; Network = $networkName; MacAddress = $nic.MacAddress; Connected = $nic.Connectable.Connected; StartConnected = $nic.Connectable.StartConnected; AddressType = $nic.AddressType }))
                }
                foreach ($floppy in @($devices | Where-Object { $_.GetType().Name -match 'Floppy' })) {
                    Add-VcfDmVsphereRows $Snapshot vFloppy (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter FLOPPY "$vmId/$($floppy.Key)" $floppy.DeviceInfo.Label ([ordered]@{ VMId = $vmId; VM = $vm.Name; Device = $floppy.DeviceInfo.Label; Connected = $floppy.Connectable.Connected; StartConnected = $floppy.Connectable.StartConnected; Backing = Get-VcfDmPropertyValue $floppy @('Backing.FileName', 'Backing.DeviceName') }))
                }
                foreach ($cd in @($devices | Where-Object { $_.GetType().Name -match 'Cdrom' })) {
                    Add-VcfDmVsphereRows $Snapshot vCD (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter CDROM "$vmId/$($cd.Key)" $cd.DeviceInfo.Label ([ordered]@{ VMId = $vmId; VM = $vm.Name; Device = $cd.DeviceInfo.Label; Connected = $cd.Connectable.Connected; StartConnected = $cd.Connectable.StartConnected; Backing = Get-VcfDmPropertyValue $cd @('Backing.FileName', 'Backing.DeviceName') }))
                }
                $snapshotRoots = if ($vm.Snapshot) { @($vm.Snapshot.RootSnapshotList) } else { @() }
                foreach ($snapshotNode in Get-VcfDmSnapshotNodes -Nodes $snapshotRoots) {
                    $snapshotName = Get-VcfDmPropertyValue $snapshotNode @('Name')
                    $snapshotId = Get-VcfDmPropertyValue $snapshotNode @('Snapshot.Value', 'Id')
                    Add-VcfDmVsphereRows $Snapshot vSnapshot (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter VM_SNAPSHOT "$vmId/$snapshotId" "$($vm.Name)/$snapshotName" ([ordered]@{ VMId = $vmId; VM = $vm.Name; Snapshot = $snapshotName; Description = Get-VcfDmPropertyValue $snapshotNode @('Description'); Created = Get-VcfDmPropertyValue $snapshotNode @('CreateTime'); State = [string](Get-VcfDmPropertyValue $snapshotNode @('State')); Quiesced = Get-VcfDmPropertyValue $snapshotNode @('Quiesced') }))
                }
                Add-VcfDmVsphereRows $Snapshot vTools (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter VM_TOOLS $vmId $vm.Name ([ordered]@{ VMId = $vmId; VM = $vm.Name; ToolsStatus = [string]$vm.Guest.ToolsStatus; ToolsRunningStatus = [string]$vm.Guest.ToolsRunningStatus; ToolsVersion = $vm.Guest.ToolsVersion; ToolsVersionStatus = [string]$vm.Guest.ToolsVersionStatus2; GuestId = $vm.Config.GuestId; GuestFamily = $vm.Guest.GuestFamily }))
            }

            foreach ($pool in $resourcePools) {
                Add-VcfDmVsphereRows $Snapshot vResourcePools (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter RESOURCE_POOL $pool.MoRef.Value $pool.Name ([ordered]@{ ResourcePoolId = $pool.MoRef.Value; OwnerId = if ($pool.Owner) { $pool.Owner.Value } else { $null }; Name = $pool.Name; CpuReservationMHz = $pool.Config.CpuAllocation.Reservation; CpuLimitMHz = $pool.Config.CpuAllocation.Limit; CpuExpandableReservation = $pool.Config.CpuAllocation.ExpandableReservation; MemoryReservationMiB = $pool.Config.MemoryAllocation.Reservation; MemoryLimitMiB = $pool.Config.MemoryAllocation.Limit; MemoryExpandableReservation = $pool.Config.MemoryAllocation.ExpandableReservation; VmIds = @($pool.Vm | ForEach-Object { $_.Value }) -join ';'; VmCount = @($pool.Vm).Count; ChildPoolCount = @($pool.ResourcePool).Count }))
            }
            foreach ($cluster in $clusters) {
                Add-VcfDmVsphereRows $Snapshot vCluster (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter CLUSTER $cluster.MoRef.Value $cluster.Name ([ordered]@{ ClusterId = $cluster.MoRef.Value; Name = $cluster.Name; Status = [string]$cluster.OverallStatus; HostIds = @($cluster.Host | ForEach-Object { $_.Value }) -join ';'; DatastoreIds = @($cluster.Datastore | ForEach-Object { $_.Value }) -join ';'; HostCount = @($cluster.Host).Count; DatastoreCount = @($cluster.Datastore).Count; TotalCpuMHz = $cluster.Summary.TotalCpu; EffectiveCpuMHz = $cluster.Summary.EffectiveCpu; TotalMemoryGiB = [math]::Round($cluster.Summary.TotalMemory / 1GB, 2); EffectiveMemoryMiB = $cluster.Summary.EffectiveMemory; DASEnabled = $cluster.ConfigurationEx.DasConfig.Enabled; DRSEnabled = $cluster.ConfigurationEx.DrsConfig.Enabled; DRSBehavior = [string]$cluster.ConfigurationEx.DrsConfig.DefaultVmBehavior }))
            }
            foreach ($hostView in $hosts) {
                $hostId = $hostView.MoRef.Value
                $serialInfo = @($hostView.Hardware.SystemInfo.OtherIdentifyingInfo | Where-Object { [string]$_.IdentifierType -match 'ServiceTag|SerialNumber' } | Select-Object -First 1)
                $serial = if ($serialInfo.Count) { Get-VcfDmPropertyValue $serialInfo[0] @('IdentifierValue') } else { $null }
                $clusterId = if ($hostView.Parent) { [string]$hostView.Parent.Value } else { $null }
                $clusterForHost = if ($clusterId -and $clusterById.ContainsKey($clusterId)) { $clusterById[$clusterId] } else { $null }
                Add-VcfDmVsphereRows $Snapshot vHost (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter HOST $hostId $hostView.Name ([ordered]@{ HostId = $hostId; ClusterId = $clusterId; ClusterName = if ($clusterForHost) { $clusterForHost.Name } else { $null }; Name = $hostView.Name; ConnectionState = [string]$hostView.Runtime.ConnectionState; PowerState = [string]$hostView.Runtime.PowerState; MaintenanceMode = $hostView.Runtime.InMaintenanceMode; Vendor = $hostView.Hardware.SystemInfo.Vendor; Model = $hostView.Hardware.SystemInfo.Model; Serial = $serial; CpuModel = $hostView.Hardware.CpuPkg[0].Description; CpuSockets = $hostView.Hardware.CpuInfo.NumCpuPackages; CpuCores = $hostView.Hardware.CpuInfo.NumCpuCores; CpuThreads = $hostView.Hardware.CpuInfo.NumCpuThreads; MemoryGiB = [math]::Round($hostView.Hardware.MemorySize / 1GB, 2); ESXiVersion = $hostView.Config.Product.Version; Build = $hostView.Config.Product.Build; BootTime = $hostView.Runtime.BootTime; VmIds = @($hostView.Vm | ForEach-Object { $_.Value }) -join ';'; DatastoreIds = @($hostView.Datastore | ForEach-Object { $_.Value }) -join ';'; VmCount = @($hostView.Vm).Count; DatastoreCount = @($hostView.Datastore).Count }))
                Add-VcfDmVsphereRows $Snapshot vTLShosts (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter HOST_TLS $hostId $hostView.Name ([ordered]@{ HostId = $hostId; Host = $hostView.Name; SslThumbprint = Get-VcfDmPropertyValue $hostView @('Summary.Config.SslThumbprint'); CertificateSubject = $null; CertificateIssuer = $null; CertificateExpiryUTC = $null; ValidationStatus = 'THUMBPRINT_ONLY' }))
                foreach ($hba in @($hostView.Config.StorageDevice.HostBusAdapter)) {
                    Add-VcfDmVsphereRows $Snapshot vHBA (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter HOST_HBA "$hostId/$($hba.Key)" "$($hostView.Name)/$($hba.Device)" ([ordered]@{ HostId = $hostId; Host = $hostView.Name; Device = $hba.Device; Model = $hba.Model; Driver = $hba.Driver; Status = [string]$hba.Status; Pci = $hba.Pci; Type = $hba.GetType().Name; WWNN = Get-VcfDmPropertyValue $hba @('NodeWorldWideName'); WWPN = Get-VcfDmPropertyValue $hba @('PortWorldWideName') }))
                }
                foreach ($pnic in @($hostView.Config.Network.Pnic)) {
                    Add-VcfDmVsphereRows $Snapshot vNIC (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter HOST_PNIC "$hostId/$($pnic.Key)" "$($hostView.Name)/$($pnic.Device)" ([ordered]@{ HostId = $hostId; Host = $hostView.Name; Device = $pnic.Device; Mac = $pnic.Mac; Driver = $pnic.Driver; LinkSpeedMb = Get-VcfDmPropertyValue $pnic @('LinkSpeed.SpeedMb'); FullDuplex = Get-VcfDmPropertyValue $pnic @('LinkSpeed.Duplex'); WakeOnLanSupported = $pnic.WakeOnLanSupported; Pci = $pnic.Pci }))
                }
                foreach ($vswitch in @($hostView.Config.Network.Vswitch | Where-Object { $null -ne $_ })) {
                    $switchKey = Get-VcfDmPropertyValue $vswitch @('Key', 'Name')
                    Add-VcfDmVsphereRows $Snapshot vSwitch (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter VSWITCH "$hostId/$switchKey" "$($hostView.Name)/$($vswitch.Name)" ([ordered]@{ HostId = $hostId; SwitchId = $switchKey; Host = $hostView.Name; Name = $vswitch.Name; Mtu = $vswitch.Mtu; Ports = $vswitch.NumPorts; Pnics = @($vswitch.Pnic) -join '; '; NicTeamingPolicy = Get-VcfDmPropertyValue $vswitch @('Spec.Policy.NicTeaming.Policy') }))
                }
                foreach ($portgroup in @($hostView.Config.Network.Portgroup | Where-Object { $null -ne $_ })) {
                    $portName = Get-VcfDmPropertyValue $portgroup @('Spec.Name', 'Key')
                    Add-VcfDmVsphereRows $Snapshot vPort (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter PORTGROUP "$hostId/$portName" "$($hostView.Name)/$portName" ([ordered]@{ HostId = $hostId; PortgroupId = Get-VcfDmPropertyValue $portgroup @('Key'); Host = $hostView.Name; Name = $portName; VlanId = Get-VcfDmPropertyValue $portgroup @('Spec.VlanId'); Vswitch = Get-VcfDmPropertyValue $portgroup @('Spec.VswitchName'); ActiveClients = @($portgroup.Port | Where-Object { $_.Connectee }).Count }))
                }
                foreach ($vmk in @($hostView.Config.Network.Vnic | Where-Object { $null -ne $_ })) {
                    Add-VcfDmVsphereRows $Snapshot vSC_VMK (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter VMKERNEL_NIC "$hostId/$($vmk.Key)" "$($hostView.Name)/$($vmk.Device)" ([ordered]@{ HostId = $hostId; Host = $hostView.Name; Device = $vmk.Device; Portgroup = $vmk.Portgroup; DvPortgroupKey = Get-VcfDmPropertyValue $vmk @('Spec.DistributedVirtualPort.PortgroupKey'); IpAddress = $vmk.Spec.Ip.IpAddress; SubnetMask = $vmk.Spec.Ip.SubnetMask; Mtu = $vmk.Spec.Mtu; Mac = $vmk.Spec.Mac }))
                }
            }
            foreach ($datastore in $datastores) {
                Add-VcfDmVsphereRows $Snapshot vDatastore (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter DATASTORE $datastore.MoRef.Value $datastore.Name ([ordered]@{ DatastoreId = $datastore.MoRef.Value; Name = $datastore.Name; Type = $datastore.Summary.Type; Accessible = $datastore.Summary.Accessible; Status = [string]$datastore.OverallStatus; CapacityGiB = [math]::Round($datastore.Summary.Capacity / 1GB, 2); FreeGiB = [math]::Round($datastore.Summary.FreeSpace / 1GB, 2); UncommittedGiB = [math]::Round($datastore.Summary.Uncommitted / 1GB, 2); Url = $datastore.Summary.Url; HostIds = @($datastore.Host | ForEach-Object { $_.Key.Value }) -join ';'; VmIds = @($datastore.Vm | ForEach-Object { $_.Value }) -join ';'; HostCount = @($datastore.Host).Count; VmCount = @($datastore.Vm).Count }))
            }

            $dvswitches = @(Get-VDSwitch -Server $viServer -ErrorAction SilentlyContinue)
            foreach ($dvs in $dvswitches) {
                Add-VcfDmVsphereRows $Snapshot dvSwitches (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter DISTRIBUTED_SWITCH $dvs.ExtensionData.MoRef.Value $dvs.Name ([ordered]@{ VDSwitchId = $dvs.ExtensionData.MoRef.Value; Name = $dvs.Name; Version = Get-VcfDmPropertyValue $dvs @('Version'); Mtu = Get-VcfDmPropertyValue $dvs @('Mtu'); NumPorts = Get-VcfDmPropertyValue $dvs @('NumPorts'); NumUplinkPorts = Get-VcfDmPropertyValue $dvs @('NumUplinkPorts'); Vendor = Get-VcfDmPropertyValue $dvs @('Vendor'); Contact = Get-VcfDmPropertyValue $dvs @('ContactDetails'); Description = Get-VcfDmPropertyValue $dvs @('Description', 'Notes') }))
            }
            foreach ($dvpg in @(Get-VDPortgroup -Server $viServer -ErrorAction SilentlyContinue)) {
                Add-VcfDmVsphereRows $Snapshot dvPorts (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter DISTRIBUTED_PORTGROUP $dvpg.ExtensionData.MoRef.Value $dvpg.Name ([ordered]@{ PortgroupId = $dvpg.ExtensionData.MoRef.Value; VDSwitchId = Get-VcfDmPropertyValue $dvpg @('VDSwitch.ExtensionData.MoRef.Value'); Name = $dvpg.Name; VDSwitch = Get-VcfDmPropertyValue $dvpg @('VDSwitch.Name'); NumPorts = Get-VcfDmPropertyValue $dvpg @('NumPorts'); PortBinding = [string](Get-VcfDmPropertyValue $dvpg @('PortBinding')); VlanConfiguration = [string](Get-VcfDmPropertyValue $dvpg @('VlanConfiguration')) }))
            }

            # A datastore-browser orphan scan is intentionally not performed in
            # v0.1; it is expensive and the normalized dataset remains explicit.
            $licenseManager = Get-View -Id LicenseManager-LicenseManager -Server $viServer -Property Licenses -ErrorAction SilentlyContinue
            foreach ($license in @($licenseManager.Licenses)) {
                Add-VcfDmVsphereRows $Snapshot Licensing (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter LICENSE $license.EditionKey $license.Name ([ordered]@{ Name = $license.Name; EditionKey = $license.EditionKey; Total = $license.Total; Used = $license.Used; CostUnit = $license.CostUnit; ExpirationDate = Get-VcfDmPropertyValue $license @('Properties.ExpirationDate') }))
            }
            foreach ($entity in @($vms + $hosts + $clusters + $datastores | Where-Object { $_.OverallStatus -in @('yellow', 'red') })) {
                Add-VcfDmVsphereRows $Snapshot Health (New-VcfDmVsphereRow $Snapshot $context $sourceVCenter HEALTH "$($entity.MoRef.Value)/$($entity.OverallStatus)" $entity.Name ([ordered]@{ Name = $entity.Name; ObjectType = $entity.MoRef.Type; OverallStatus = [string]$entity.OverallStatus; Finding = 'Object overall status is not green'; RemediationSummary = 'Review active vCenter alarms.' }))
            }

            $totalRows = 0
            foreach ($dataset in Get-VcfDmDatasetNames -VSphere) { $totalRows += @($Snapshot.VSphere[$dataset] | Where-Object { $_.'Source vCenter' -eq $sourceVCenter }).Count }
            Add-VcfDmVsphereStatus -Snapshot $Snapshot -VCenterFqdn $sourceVCenter -Started $started -Status SUCCESS -Rows $totalRows
            Invoke-VcfDmInventoryCollection -Snapshot $Snapshot -Server $viServer -VCenterFqdn $sourceVCenter -SkipDatastoreFileScan:$SkipDatastoreFileScan
            $Snapshot.Sources = @($Snapshot.Sources) + @([pscustomobject][ordered]@{ SourceSystemType = 'VCENTER'; SourceSystemId = $context.VCenterId; SourceSystemFqdn = $sourceVCenter; VCFInstanceId = $context.VCFInstanceId; DomainId = $context.DomainId })

            $vcRow = @($Snapshot.Datasets.VCF_vCenters | Where-Object { $_.VCenterFqdn -ieq $sourceVCenter } | Select-Object -First 1)
            if ($vcRow.Count) {
                $vcRow[0].Build = $viServer.Build
                $vcRow[0].DatacenterCount = @(Get-Datacenter -Server $viServer).Count
                $vcRow[0].ClusterCount = $clusters.Count
                $vcRow[0].HostCount = $hosts.Count
                $vcRow[0].VmCount = $vms.Count
            }
        }
        catch {
            $category = Get-VcfDmErrorCategory -ErrorRecord $_
            $status = switch ($category) { 'AUTHORIZATION' { 'NOT_AUTHORIZED' }; 'CONNECTIVITY' { 'UNREACHABLE' }; default { 'COLLECTION_FAILED' } }
            Add-VcfDmVsphereStatus -Snapshot $Snapshot -VCenterFqdn $sourceVCenter -Started $started -Status $status -Rows 0 -Category $category -Summary (ConvertTo-VcfDmSafeErrorText $_.Exception.Message)
        }
        finally {
            if ($viServer) { Disconnect-VIServer -Server $viServer -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
        }
    }
}

Export-ModuleMember -Function 'Invoke-VcfDmVsphereCollection'
