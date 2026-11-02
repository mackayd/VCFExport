<#
VCFexport detailed vSphere inventory collectors.

MIT License

Copyright (c) 2025

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
#>

function Get-SafeValue {
    param(
        [Parameter(Mandatory = $false)] $Value,
        [Parameter(Mandatory = $false)] $Default = $null
    )
    if ($null -eq $Value) { return $Default }
    return $Value
}

function Join-NonEmpty {
    param(
        [Parameter(Mandatory = $false)] [object[]]$Values,
        [string]$Separator = ', '
    )
    if ($null -eq $Values) { return '' }
    $filtered = @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ } | Select-Object -Unique)
    if ($filtered.Count -eq 0) { return '' }
    return ($filtered -join $Separator)
}

function Get-VMAdvancedSettingValue {
    param(
        [Parameter(Mandatory = $true)] $VM,
        [Parameter(Mandatory = $true)] [string]$Name
    )

    if (-not $script:VMAdvancedSettingCache) { $script:VMAdvancedSettingCache = @{} }

    $vmKey = $null
    try { $vmKey = $VM.Id } catch {}
    if ([string]::IsNullOrWhiteSpace($vmKey)) { try { $vmKey = $VM.ExtensionData.MoRef.Value } catch {} }
    if ([string]::IsNullOrWhiteSpace($vmKey)) { $vmKey = [string]$VM.Name }
    $cacheKey = "$vmKey|$Name"

    if ($script:VMAdvancedSettingCache.ContainsKey($cacheKey)) {
        return $script:VMAdvancedSettingCache[$cacheKey]
    }

    $value = $null
    try { $value = (Get-AdvancedSetting -Entity $VM -Name $Name -ErrorAction Stop).Value } catch {}
    $script:VMAdvancedSettingCache[$cacheKey] = $value
    return $value
}

function Get-VMGuestNetworkDetails {
    param(
        [Parameter(Mandatory = $true)] $VM,
        [Parameter(Mandatory = $true)] $Nic
    )

    if (-not $script:VMGuestNetCache) { $script:VMGuestNetCache = @{} }

    $vmKey = $null
    try { $vmKey = $VM.Id } catch {}
    if ([string]::IsNullOrWhiteSpace($vmKey)) { try { $vmKey = $VM.ExtensionData.MoRef.Value } catch {} }
    if ([string]::IsNullOrWhiteSpace($vmKey)) { $vmKey = [string]$VM.Name }

    if (-not $script:VMGuestNetCache.ContainsKey($vmKey)) {
        $macMap = @{}
        try {
            foreach ($guestNet in @($VM.ExtensionData.Guest.Net)) {
                $guestMac = [string]$guestNet.MacAddress
                if ([string]::IsNullOrWhiteSpace($guestMac)) { continue }
                $macKey = $guestMac.ToLowerInvariant()

                $ipv4 = @()
                $ipv6 = @()
                foreach ($ip in @($guestNet.IpAddress)) {
                    if ([string]::IsNullOrWhiteSpace($ip)) { continue }
                    if ($ip -match ':') { $ipv6 += $ip } else { $ipv4 += $ip }
                }

                $dnsName = $null
                try {
                    if ($guestNet.DnsConfig -and -not [string]::IsNullOrWhiteSpace($guestNet.DnsConfig.HostName)) {
                        $dnsName = $guestNet.DnsConfig.HostName
                    }
                }
                catch {}

                $macMap[$macKey] = [PSCustomObject]@{
                    IPv4    = Join-NonEmpty -Values $ipv4
                    IPv6    = Join-NonEmpty -Values $ipv6
                    DnsName = $dnsName
                }
            }
        }
        catch {}
        $script:VMGuestNetCache[$vmKey] = $macMap
    }

    $nicKey = [string]$Nic.MacAddress
    if (-not [string]::IsNullOrWhiteSpace($nicKey)) {
        $nicKey = $nicKey.ToLowerInvariant()
        $macMap = $script:VMGuestNetCache[$vmKey]
        if ($macMap -and $macMap.ContainsKey($nicKey)) {
            return $macMap[$nicKey]
        }
    }

    return [PSCustomObject]@{ IPv4 = $null; IPv6 = $null; DnsName = $null }
}

function Get-VMRuleSummary {
    param(
        [Parameter(Mandatory = $true)] $VM
    )

    if (-not $script:ClusterRuleCache) { $script:ClusterRuleCache = @{} }

    $clusterId = $null
    try {
        if (-not (Test-IsTemplateLikeObject -vm $VM)) {
            $cluster = $VM | Get-Cluster -ErrorAction Stop
            if ($cluster) { $clusterId = $cluster.Id }
        }
    }
    catch {}

    if ([string]::IsNullOrWhiteSpace($clusterId)) {
        return [PSCustomObject]@{ RuleNames = $null; EnabledRuleNames = $null }
    }

    if (-not $script:ClusterRuleCache.ContainsKey($clusterId)) {
        $ruleIndex = @{}
        try {
            $clusterView = Get-View -Id $clusterId -ErrorAction Stop
            foreach ($rule in @($clusterView.ConfigurationEx.Rule)) {
                $vmRefs = @()
                if ($rule.PSObject.Properties.Name -contains 'Vm') { $vmRefs = @($rule.Vm) }
                foreach ($ref in $vmRefs) {
                    $vmId = $null
                    try { $vmId = $ref.Value } catch {}
                    if ([string]::IsNullOrWhiteSpace($vmId)) { continue }
                    if (-not $ruleIndex.ContainsKey($vmId)) {
                        $ruleIndex[$vmId] = [PSCustomObject]@{ Names = New-Object System.Collections.Generic.List[string]; Enabled = New-Object System.Collections.Generic.List[string] }
                    }
                    $ruleIndex[$vmId].Names.Add([string]$rule.Name)
                    if ($rule.Enabled) { $ruleIndex[$vmId].Enabled.Add([string]$rule.Name) }
                }
            }
        }
        catch {}
        $script:ClusterRuleCache[$clusterId] = $ruleIndex
    }

    $vmMoRef = $null
    try { $vmMoRef = $VM.ExtensionData.MoRef.Value } catch {}
    if ([string]::IsNullOrWhiteSpace($vmMoRef)) { return [PSCustomObject]@{ RuleNames = $null; EnabledRuleNames = $null } }

    $index = $script:ClusterRuleCache[$clusterId]
    if (-not $index.ContainsKey($vmMoRef)) {
        return [PSCustomObject]@{ RuleNames = $null; EnabledRuleNames = $null }
    }

    $entry = $index[$vmMoRef]
    return [PSCustomObject]@{
        RuleNames = Join-NonEmpty -Values $entry.Names
        EnabledRuleNames = Join-NonEmpty -Values $entry.Enabled
    }
}

function Get-VMContext {
    param($vm)

    if (-not $script:VMContextCache) { $script:VMContextCache = @{} }

    $vmKey = $null
    try { $vmKey = $vm.Id } catch {}
    if ([string]::IsNullOrWhiteSpace($vmKey)) { try { $vmKey = $vm.ExtensionData.MoRef.Value } catch {} }
    if ([string]::IsNullOrWhiteSpace($vmKey)) { $vmKey = [string]$vm.Name }

    if ($script:VMContextCache.ContainsKey($vmKey)) {
        return $script:VMContextCache[$vmKey]
    }

    $clusterName = $null
    $datacenterName = $null
    $resourcePoolName = $null
    $vappName = $null
    $folderName = $null

    try { $folderName = $vm.Folder.Name } catch {}
    try { $resourcePoolName = $vm.ResourcePool.Name } catch {}
    try { $vappName = $vm.VApp.Name } catch {}

    try {
        $parentRef = $vm.ExtensionData.Parent
        $safety = 0
        while ($parentRef -and $safety -lt 20) {
            $parentView = Get-View -Id $parentRef -Property Name,Parent,ResourcePool -ErrorAction SilentlyContinue
            if (-not $parentView) { break }

            switch ($parentView.MoRef.Type) {
                'Folder' {
                    if (-not $folderName) { $folderName = $parentView.Name }
                }
                'VirtualApp' {
                    if (-not $vappName) { $vappName = $parentView.Name }
                    try {
                        if (-not $resourcePoolName -and $parentView.ResourcePool) {
                            $rpView = Get-View -Id $parentView.ResourcePool -Property Name -ErrorAction SilentlyContinue
                            if ($rpView) { $resourcePoolName = $rpView.Name }
                        }
                    } catch {}
                }
                'ResourcePool' {
                    if (-not $resourcePoolName) { $resourcePoolName = $parentView.Name }
                }
                'ClusterComputeResource' {
                    if (-not $clusterName) { $clusterName = $parentView.Name }
                }
                'Datacenter' {
                    if (-not $datacenterName) { $datacenterName = $parentView.Name }
                }
            }

            $parentRef = $parentView.Parent
            $safety++
        }
    }
    catch {}

    if (-not $clusterName -or -not $datacenterName) {
        try {
            $hostRef = $vm.ExtensionData.Runtime.Host
            if ($hostRef) {
                $hostView = Get-View -Id $hostRef -Property Name,Parent -ErrorAction SilentlyContinue
                $parentRef = if ($hostView) { $hostView.Parent } else { $null }
                $safety = 0
                while ($parentRef -and $safety -lt 15) {
                    $parentView = Get-View -Id $parentRef -Property Name,Parent -ErrorAction SilentlyContinue
                    if (-not $parentView) { break }
                    switch ($parentView.MoRef.Type) {
                        'ClusterComputeResource' { if (-not $clusterName) { $clusterName = $parentView.Name } }
                        'Datacenter' { if (-not $datacenterName) { $datacenterName = $parentView.Name } }
                    }
                    $parentRef = $parentView.Parent
                    $safety++
                }
            }
        }
        catch {}
    }

    $ctx = @{
        Cluster      = $clusterName
        Datacenter   = $datacenterName
        ResourcePool = $resourcePoolName
        vApp         = $vappName
        Folder       = $folderName
    }

    $script:VMContextCache[$vmKey] = $ctx
    return $ctx
}

function Test-IsTemplateLikeObject {
    param($vm)
    try {
        if ($vm.ExtensionData -and $vm.ExtensionData.Config -and $vm.ExtensionData.Config.Template) { return $true }
    }
    catch {}
    try {
        if ($vm.GetType().Name -match 'Template') { return $true }
    }
    catch {}
    return $false
}

function Get-VMRuntimeHostName {
    param($vm)

    if (-not $script:VMHostNameCache) { $script:VMHostNameCache = @{} }
    $vmKey = $null
    try { $vmKey = $vm.Id } catch {}
    if ([string]::IsNullOrWhiteSpace($vmKey)) { try { $vmKey = $vm.ExtensionData.MoRef.Value } catch {} }
    if ([string]::IsNullOrWhiteSpace($vmKey)) { $vmKey = [string]$vm.Name }

    if ($script:VMHostNameCache.ContainsKey($vmKey)) { return $script:VMHostNameCache[$vmKey] }

    $name = $null
    try { if ($vm.VMHost -and $vm.VMHost.Name) { $name = $vm.VMHost.Name } } catch {}
    if (-not $name) {
        try {
            $hostRef = $vm.ExtensionData.Runtime.Host
            if ($hostRef) {
                $hostView = Get-View -Id $hostRef -Property Name -ErrorAction SilentlyContinue
                if ($hostView) { $name = $hostView.Name }
            }
        }
        catch {}
    }

    $script:VMHostNameCache[$vmKey] = $name
    return $name
}

function Get-VMEffectivePowerState {
    param($vm)

    if (-not $script:VMPowerStateCache) { $script:VMPowerStateCache = @{} }
    $vmKey = $null
    try { $vmKey = $vm.Id } catch {}
    if ([string]::IsNullOrWhiteSpace($vmKey)) { try { $vmKey = $vm.ExtensionData.MoRef.Value } catch {} }
    if ([string]::IsNullOrWhiteSpace($vmKey)) { $vmKey = [string]$vm.Name }

    if ($script:VMPowerStateCache.ContainsKey($vmKey)) { return $script:VMPowerStateCache[$vmKey] }

    $state = $null
    try {
        if ($null -ne $vm.PowerState) {
            $state = [string]$vm.PowerState
        }
    }
    catch {}

    if ([string]::IsNullOrWhiteSpace($state)) {
        try {
            if ($null -ne $vm.ExtensionData.Runtime.PowerState) {
                $state = [string]$vm.ExtensionData.Runtime.PowerState
            }
        }
        catch {}
    }

    $script:VMPowerStateCache[$vmKey] = $state
    return $state
}

function Get-VMEffectiveToolsOS {
    param($vm)

    if (-not $script:VMToolsOSCache) { $script:VMToolsOSCache = @{} }
    $vmKey = $null
    try { $vmKey = $vm.Id } catch {}
    if ([string]::IsNullOrWhiteSpace($vmKey)) { try { $vmKey = $vm.ExtensionData.MoRef.Value } catch {} }
    if ([string]::IsNullOrWhiteSpace($vmKey)) { $vmKey = [string]$vm.Name }

    if ($script:VMToolsOSCache.ContainsKey($vmKey)) { return $script:VMToolsOSCache[$vmKey] }

    $osName = $null
    try { if ($vm.Guest -and -not [string]::IsNullOrWhiteSpace($vm.Guest.OSFullName)) { $osName = $vm.Guest.OSFullName } } catch {}
    if (-not $osName) { try { if ($vm.ExtensionData.Guest -and -not [string]::IsNullOrWhiteSpace($vm.ExtensionData.Guest.GuestFullName)) { $osName = $vm.ExtensionData.Guest.GuestFullName } } catch {} }
    if (-not $osName) { try { if ($vm.ExtensionData.Config -and -not [string]::IsNullOrWhiteSpace($vm.ExtensionData.Config.GuestFullName)) { $osName = $vm.ExtensionData.Config.GuestFullName } } catch {} }

    $script:VMToolsOSCache[$vmKey] = $osName
    return $osName
}

function Get-vInfo {
    param($vms, $about, $GetVMContextFn)
    $total = $vms.Count
    $i = 0
    foreach ($vm in $vms) {
        $i++
        Write-InlineProgress -Activity "Collecting vInfo $i of $total VMs" -PercentComplete ([int](($i / $total) * 100)) -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null

        $ed = $vm.ExtensionData
        $ctx = & $GetVMContextFn $vm
        $runtimeHostName = Get-VMRuntimeHostName -VM $vm
        $effectivePowerState = Get-VMEffectivePowerState -VM $vm
        $toolsOsFullName = Get-VMEffectiveToolsOS -VM $vm
        $boot = $ed.Config.BootOptions
        $videoCard = $ed.Config.Hardware.Device | Where-Object {
            $typeName = $_.GetType().Name
            $typeName -match 'Video|SVGA' -or
            ($_.PSObject.Properties.Name -contains 'VideoRamSizeInKB') -or
            ($_.DeviceInfo -and $_.DeviceInfo.Label -match '^Video')
        } | Select-Object -First 1
        $nics = @($ed.Config.Hardware.Device | Where-Object { $_ -is [VMware.Vim.VirtualEthernetCard] })
        $disks = @($ed.Config.Hardware.Device | Where-Object { $_ -is [VMware.Vim.VirtualDisk] })
        $networkNames = @($nics | ForEach-Object {
            if ($_.Backing -is [VMware.Vim.VirtualEthernetCardDistributedVirtualPortBackingInfo]) {
                $_.DeviceInfo.Summary
            }
            elseif ($_.Backing -is [VMware.Vim.VirtualEthernetCardNetworkBackingInfo]) {
                $_.Backing.DeviceName
            }
            else {
                $_.DeviceInfo.Summary
            }
        })
        $primaryNic = $nics | Select-Object -First 1
        $primaryGuestNet = if ($primaryNic) { Get-VMGuestNetworkDetails -VM $vm -Nic $primaryNic } else { $null }
        $primaryIP = if (-not [string]::IsNullOrWhiteSpace($ed.Summary.Guest.IpAddress)) { $ed.Summary.Guest.IpAddress } elseif ($primaryGuestNet) { $primaryGuestNet.IPv4 } else { $null }
        $dnsName = if (-not [string]::IsNullOrWhiteSpace($ed.Guest.HostName)) { $ed.Guest.HostName } elseif ($primaryGuestNet) { $primaryGuestNet.DnsName } else { $null }
        $clusterRules = Get-VMRuleSummary -VM $vm
        $dasVmSettings = $ed.Config.DasVmSettings
        $enableUuid = Get-VMAdvancedSettingValue -VM $vm -Name 'disk.EnableUUID'
        $opNotificationTimeout = Get-VMAdvancedSettingValue -VM $vm -Name 'tools.guestlib.enableHostInfo'
        $resourceConfig = $ed.ResourceConfig
        $storage = $ed.Summary.Storage

        [PSCustomObject]@{
            Name                                     = $vm.Name
            Powerstate                               = $effectivePowerState
            Template                                 = $ed.Config.Template
            "SRM Placeholder"                        = $false
            "Config status"                          = $ed.OverallStatus
            "DNS Name"                               = $dnsName
            "Connection state"                       = $ed.Runtime.ConnectionState
            "Guest state"                            = $ed.Guest.GuestState
            Heartbeat                                = $ed.GuestHeartbeatStatus
            "Consolidation Needed"                   = $ed.Runtime.ConsolidationNeeded
            PowerOn                                  = ($effectivePowerState -match 'PoweredOn')
            "Suspended To Memory"                    = (Get-SafeValue -Value $ed.Runtime.SuspendedToMemory)
            "Suspend time"                           = $ed.Runtime.SuspendTime
            "Suspend Interval"                       = (Get-SafeValue -Value $ed.Runtime.SuspendInterval)
            "Creation date"                          = $ed.Config.CreateDate
            ChangeVersion                            = $ed.Config.ChangeVersion
            CPUs                                     = $ed.Config.Hardware.NumCPU
            "Overall Cpu Readiness"                  = (Get-SafeValue -Value $ed.Summary.QuickStats.OverallCpuReadiness)
            Memory                                   = $ed.Config.Hardware.MemoryMB
            "Active Memory"                          = $ed.Summary.QuickStats.GuestMemoryUsage
            NICs                                     = $nics.Count
            Disks                                    = $disks.Count
            "Total disk capacity MiB"                = [int](($disks | Measure-Object -Property CapacityInKB -Sum).Sum / 1024)
            "Fixed Passthru HotPlug"                 = (Get-SafeValue -Value $ed.Config.FixedPassthruHotPlugEnabled)
            "min Required EVC Mode Key"              = (Get-SafeValue -Value $ed.Runtime.MinRequiredEVCModeKey)
            "Latency Sensitivity"                    = $ed.Config.LatencySensitivity.Level
            "Op Notification Timeout"                = $opNotificationTimeout
            EnableUUID                               = $enableUuid
            CBT                                      = $ed.Config.ChangeTrackingEnabled
            "Primary IP Address"                     = $primaryIP
            "Network #1"                             = (Get-SafeValue -Value $networkNames[0] -Default '')
            "Network #2"                             = (Get-SafeValue -Value $networkNames[1] -Default '')
            "Network #3"                             = (Get-SafeValue -Value $networkNames[2] -Default '')
            "Network #4"                             = (Get-SafeValue -Value $networkNames[3] -Default '')
            "Network #5"                             = (Get-SafeValue -Value $networkNames[4] -Default '')
            "Network #6"                             = (Get-SafeValue -Value $networkNames[5] -Default '')
            "Network #7"                             = (Get-SafeValue -Value $networkNames[6] -Default '')
            "Network #8"                             = (Get-SafeValue -Value $networkNames[7] -Default '')
            "Num Monitors"                           = (Get-SafeValue -Value $videoCard.NumDisplays)
            "Video Ram KiB"                          = if ($videoCard) { [int]($videoCard.VideoRamSizeInKB) } else { $null }
            "Resource pool"                          = $ctx.ResourcePool
            "Folder ID"                              = (Get-SafeValue -Value $vm.Folder.Id)
            Folder                                   = $ctx.Folder
            vApp                                     = $ctx.vApp
            "DAS protection"                         = (Get-SafeValue -Value $ed.Runtime.DasVmProtection.DasProtected)
            "FT State"                               = (Get-SafeValue -Value $ed.Runtime.FaultToleranceState)
            "FT Role"                                = (Get-SafeValue -Value $ed.Runtime.RecordReplayState)
            "FT Latency"                             = (Get-SafeValue -Value $ed.Runtime.FtLatencyStatus)
            "FT Bandwidth"                           = (Get-SafeValue -Value $ed.Runtime.FtSecondaryLatency)
            "FT Sec. Latency"                        = (Get-SafeValue -Value $ed.Runtime.FtSecondaryLatency)
            "Vm Failover In Progress"                = (Get-SafeValue -Value $ed.Runtime.DasVmProtection.DasVmProtectionState)
            "Provisioned MiB"                        = if ($storage) { [math]::Round($storage.Committed / 1MB, 0) + [math]::Round($storage.Uncommitted / 1MB, 0) } else { $null }
            "In Use MiB"                             = if ($storage) { [math]::Round($storage.Committed / 1MB, 0) } else { $null }
            "Unshared MiB"                           = if ($storage) { [math]::Round($storage.Unshared / 1MB, 0) } else { $null }
            "HA Restart Priority"                    = (Get-SafeValue -Value $dasVmSettings.RestartPriority)
            "HA Isolation Response"                  = (Get-SafeValue -Value $dasVmSettings.IsolationResponse)
            "HA VM Monitoring"                       = (Get-SafeValue -Value $dasVmSettings.VmMonitoring)
            "Cluster rule(s)"                        = $clusterRules.EnabledRuleNames
            "Cluster rule name(s)"                   = $clusterRules.RuleNames
            "Boot Required"                          = $boot.EnterBIOSSetup
            "Boot delay"                             = $boot.BootDelay
            "Boot retry delay"                       = $boot.BootRetryDelay
            "Boot retry enabled"                     = $boot.BootRetryEnabled
            "Boot BIOS setup"                        = $boot.EnterBIOSSetup
            "Reboot PowerOff"                        = $boot.BootOrder
            "EFI Secure boot"                        = (Get-SafeValue -Value $ed.Config.BootOptions.EfiSecureBootEnabled)
            Firmware                                 = $ed.Config.Firmware
            "HW version"                             = $ed.Config.Version
            "HW upgrade status"                      = (Get-SafeValue -Value $ed.Config.ScheduledHardwareUpgradeInfo.Status)
            "HW upgrade policy"                      = (Get-SafeValue -Value $ed.Config.ScheduledHardwareUpgradeInfo.UpgradePolicy)
            "HW target"                              = (Get-SafeValue -Value $ed.Config.ScheduledHardwareUpgradeInfo.VersionKey)
            Path                                     = $ed.Config.Files.VmPathName
            "Log directory"                          = $ed.Config.Files.LogDirectory
            "Snapshot directory"                     = $ed.Config.Files.SnapshotDirectory
            "Suspend directory"                      = $ed.Config.Files.SuspendDirectory
            Annotation                               = $ed.Config.Annotation
            "com.vrlcm.snapshot"                     = $null
            Datacenter                               = $ctx.Datacenter
            Cluster                                  = $ctx.Cluster
            Host                                     = $runtimeHostName
            "OS according to the configuration file" = $ed.Config.GuestFullName
            "OS according to the VMware Tools"       = $toolsOsFullName
            "Customization Info"                     = (Get-SafeValue -Value $ed.Guest.CustomizationInfo)
            "Guest Detailed Data"                    = $ed.Guest.GuestDetailedData
            "VM ID"                                  = $ed.MoRef.Value
            "SMBIOS UUID"                            = $ed.Config.InstanceUuid
            "VM UUID"                                = $ed.Config.Uuid
            "VI SDK Server type"                     = $about.ApiType
            "VI SDK API Version"                     = $about.ApiVersion
            "VI SDK Server"                          = $about.FullName
            "VI SDK UUID"                            = $about.InstanceUuid
        }
    }
    Write-InlineProgress -Activity 'vInfo Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null
}

function Get-vCPU {
    param($vms, $about, $GetVMContextFn)
    $total = $vms.Count
    $i = 0

    foreach ($vm in $vms) {
        $i++
        Write-InlineProgress -Activity "Collecting vCPU $i of $total VMs" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null
        $ed = $vm.ExtensionData
        $ctx = & $GetVMContextFn $vm
        $runtimeHostName = Get-VMRuntimeHostName -VM $vm
        $effectivePowerState = Get-VMEffectivePowerState -VM $vm
        $toolsOsFullName = Get-VMEffectiveToolsOS -VM $vm
        $toolsStatus2 = $ed.Guest.ToolsVersionStatus2
        $requiredVersion = $PlatformToolsRequiredVersion
        if ($toolsStatus2 -eq 'guestToolsUnmanaged') {
            $requiredVersion = 'Unmanaged'
        }
        [PSCustomObject]@{
            Name                                     = $vm.Name
            Powerstate                               = $effectivePowerState
            Template                                 = $ed.Config.Template
            "SRM Placeholder"                        = $false
            Annotation                               = $ed.Config.Annotation
            Datacenter                               = $ctx.Datacenter
            Cluster                                  = $ctx.Cluster
            Host                                     = $runtimeHostName
            Folder                                   = $ctx.Folder
            "OS according to the configuration file" = $ed.Config.GuestFullName
            "OS according to the VMware Tools"       = $toolsOsFullName
            VM_ID                                    = $ed.MoRef.Value
            UUID                                     = $ed.Config.Uuid
            vCPUs                                    = $ed.Config.Hardware.NumCPU
            Sockets                                  = $ed.Config.Hardware.NumCPU / $ed.Config.Hardware.NumCoresPerSocket
            CoresPerSocket                           = $ed.Config.Hardware.NumCoresPerSocket
            MaxCPU_MHz                               = (Get-SafeValue -Value $ed.Runtime.MaxCpuUsage -Default 0)
            CPU_Usage_MHz                            = $ed.Summary.QuickStats.OverallCpuUsage
            SharesLevel                              = $ed.Config.CpuAllocation.Shares.Level
            Shares                                   = $ed.Config.CpuAllocation.Shares.Shares
            CPU_Reservation                          = $ed.Config.CpuAllocation.Reservation
            CPULimit                                 = if ($ed.Config.CpuAllocation.Limit -eq -1) { 0 } else { $ed.Config.CpuAllocation.Limit }
            EntitlementMHz                           = $ed.Summary.QuickStats.StaticCpuEntitlement
            DRSEntitlementMHz                        = $ed.Summary.QuickStats.DistributedCpuEntitlement
            CPUHotAdd                                = $ed.Config.CpuHotAddEnabled
            CPUHotRemove                             = $ed.Config.CpuHotRemoveEnabled
            NumaHotaddExposed                        = Get-VMAdvancedSettingValue -VM $vm -Name 'numa.autosize.vcpu.maxPerVirtualNode'
            "com.vrlcm.snapshot"                     = Get-VMAdvancedSettingValue -VM $vm -Name 'com.vrlcm.snapshot'
            "VI SDK Server"                          = $about.FullName
            "VI SDK UUID"                            = $about.InstanceUuid
        }
    }
    Write-InlineProgress -Activity 'vCPU Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null

}

function Get-vMemory {
    param($vms, $about, $GetVMContextFn)
    $total = $vms.Count
    $i = 0

    foreach ($vm in $vms) {
        $i++

        Write-InlineProgress -Activity "Collecting vMemory $i of $total VMs" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null
        $ed = $vm.ExtensionData
        $ctx = & $GetVMContextFn $vm
        $runtimeHostName = Get-VMRuntimeHostName -VM $vm
        $effectivePowerState = Get-VMEffectivePowerState -VM $vm
        $toolsOsFullName = Get-VMEffectiveToolsOS -VM $vm
        $toolsStatus2 = $null
        try { $toolsStatus2 = $ed.Guest.ToolsVersionStatus2 } catch {}
        $requiredVersion = $PlatformToolsRequiredVersion
        if ($toolsStatus2 -eq 'guestToolsUnmanaged') {
            $requiredVersion = 'Unmanaged'
        }
        [PSCustomObject]@{
            Name                                     = $vm.Name
            Powerstate                               = $effectivePowerState
            Template                                 = $ed.Config.Template
            "SRM Placeholder"                        = $false
            Annotation                               = $ed.Config.Annotation
            Datacenter                               = $ctx.Datacenter
            Cluster                                  = $ctx.Cluster
            Host                                     = $runtimeHostName
            Folder                                   = $ctx.Folder
            "OS according to the configuration file" = $ed.Config.GuestFullName
            "OS according to the VMware Tools"       = $toolsOsFullName
            VM_ID                                    = $ed.MoRef.Value
            UUID                                     = $ed.Config.Uuid
            MemoryMB                                 = $ed.Config.Hardware.MemoryMB
            MemoryReservationLockedToMax             = $ed.Config.MemoryReservationLockedToMax
            Overhead                                 = (Get-SafeValue -Value $ed.Config.MemoryAllocation.OverheadLimit -Default 0)
            MaxMemoryUsageMB                         = (Get-SafeValue -Value $ed.Runtime.MaxMemoryUsage -Default 0)
            MemLimitMB                               = if ($ed.Config.MemoryAllocation.Limit -eq -1) { 0 } else { $ed.Config.MemoryAllocation.Limit }
            MemReservation                           = $ed.Config.MemoryAllocation.Reservation
            MemSharesLevel                           = $ed.Config.MemoryAllocation.Shares.Level
            MemShares                                = $ed.Config.MemoryAllocation.Shares.Shares
            MemConsumedMB                            = $ed.Summary.QuickStats.HostMemoryUsage
            OverheadMB                               = $ed.Summary.QuickStats.ConsumedOverheadMemory
            PrivateMB                                = $ed.Summary.QuickStats.PrivateMemory
            SharedMB                                 = $ed.Summary.QuickStats.SharedMemory
            SwappedMB                                = $ed.Summary.QuickStats.SwappedMemory
            BalloonedMB                              = $ed.Summary.QuickStats.BalloonedMemory
            CompressedMB                             = [math]::Round($ed.Summary.QuickStats.CompressedMemory / 1024, 0)
            ActiveMB                                 = $ed.Summary.QuickStats.GuestMemoryUsage
            EntitlementMB                            = $ed.Summary.QuickStats.StaticMemoryEntitlement
            DRSEntitlementMB                         = $ed.Summary.QuickStats.DistributedMemoryEntitlement
            MemHotAdd                                = $ed.Config.MemoryHotAddEnabled
            "com.vrlcm.snapshot"                     = Get-VMAdvancedSettingValue -VM $vm -Name 'com.vrlcm.snapshot'
            "VI SDK Server"                          = $about.FullName
            "VI SDK UUID"                            = $about.InstanceUuid
        }
    }
    Write-InlineProgress -Activity 'vMemory Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null
}

function Get-vDisk {
    param($vms, $about, $GetVMContextFn)
    $total = $vms.Count
    $i = 0

    foreach ($vm in $vms) {
        $i++
        Write-InlineProgress -Activity "Collecting vDisk $i of $total VMs" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null


        $ed = $vm.ExtensionData
        $ctx = & $GetVMContextFn $vm
        $runtimeHostName = Get-VMRuntimeHostName -VM $vm
        $effectivePowerState = Get-VMEffectivePowerState -VM $vm
        $toolsOsFullName = Get-VMEffectiveToolsOS -VM $vm
        foreach ($disk in $ed.Config.Hardware.Device | Where-Object { $_ -is [VMware.Vim.VirtualDisk] }) {
            $ctl = $ed.Config.Hardware.Device | Where-Object { $_.Key -eq $disk.ControllerKey }
            [PSCustomObject]@{
                Name                                     = $vm.Name
                Powerstate                               = $effectivePowerState
                Template                                 = $ed.Config.Template
                "SRM Placeholder"                        = $false
                Annotation                               = $ed.Config.Annotation
                Datacenter                               = $ctx.Datacenter
                Cluster                                  = $ctx.Cluster
                Host                                     = $runtimeHostName
                Folder                                   = $ctx.Folder
                "OS according to the configuration file" = $ed.Config.GuestFullName
                "OS according to the VMware Tools"       = $toolsOsFullName
                VM_ID                                    = $ed.MoRef.Value
                UUID                                     = $ed.Config.Uuid
                Disk                                     = $disk.DeviceInfo.Label
                DiskKey                                  = $disk.Key
                DiskUUID                                 = $disk.Backing.Uuid
                CapacityMB                               = [int]($disk.CapacityInKB / 1024)
                Thin                                     = $disk.Backing.ThinProvisioned
                EagerZero                                = $disk.Backing.EagerlyScrub
                Mode                                     = $disk.Backing.DiskMode
                SharingMode                              = $disk.Sharing
                Split                                    = $disk.Backing.Split
                WriteThrough                             = $disk.Backing.WriteThrough
                Level                                    = $disk.StorageIOAllocation.Shares.Level
                Shares                                   = $disk.StorageIOAllocation.Shares.Shares
                Reservation                              = $disk.StorageIOAllocation.Reservation
                Limit                                    = $disk.StorageIOAllocation.Limit
                Controller                               = $ctl.GetType().Name
                Label                                    = $ctl.DeviceInfo.Label
                ControllerBus                            = $ctl.BusNumber
                Unit                                     = $disk.UnitNumber
                SharedBus                                = $ctl.SharedBus
                Path                                     = $disk.Backing.FileName
                Raw                                      = ($disk.Backing -is [VMware.Vim.VirtualDiskRawDiskMappingVer1BackingInfo])
                LunUuid                                  = $disk.Backing.LunUuid
                RDMMode                                  = $disk.Backing.CompatibilityMode
                InternalSortColumn                       = ('{0:D2}:{1:D2}' -f [int]$ctl.BusNumber,[int]$disk.UnitNumber)
                "com.vrlcm.snapshot"                     = Get-VMAdvancedSettingValue -VM $vm -Name 'com.vrlcm.snapshot'
                "VI SDK Server"                          = $about.FullName
                "VI SDK UUID"                            = $about.InstanceUuid
            }
        }
    }
    Write-InlineProgress -Activity 'vDisk Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null
}

function Get-vPartition {
    param($vms, $about, $GetVMContextFn)
    $total = $vms.Count
    $i = 0

    foreach ($vm in $vms) {
        $i++
        Write-InlineProgress -Activity "Collecting vPartition $i of $total VMs" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null

        $ed = $vm.ExtensionData
        $ctx = & $GetVMContextFn $vm
        $runtimeHostName = Get-VMRuntimeHostName -VM $vm
        $effectivePowerState = Get-VMEffectivePowerState -VM $vm
        $toolsOsFullName = Get-VMEffectiveToolsOS -VM $vm        $osFamily = $null
        try { $osFamily = $vm.ExtensionData.Guest.GuestFamily } catch {}
        if (-not $osFamily) {
            try {
                $guestId = [string]$vm.ExtensionData.Config.GuestId
                if ($guestId -match '^win') { $osFamily = 'windowsGuest' }
                elseif ($guestId -match 'linux') { $osFamily = 'linuxGuest' }
                else { $osFamily = 'otherGuest' }
            }
            catch {
                $osFamily = 'otherGuest'
            }
        }

        $diskEnableUuid = $null
        try {
            $diskEnableUuid = ($vm | Get-AdvancedSetting -Name 'disk.EnableUUID' -ErrorAction Stop).Value
        }
        catch {
            $diskEnableUuid = $null
        }

        $uuidDisabledWarning = ($osFamily -eq 'windowsGuest' -and [string]$diskEnableUuid -ne 'TRUE')

        $guestDiskMap = @{}
        try {
            if (-not (Test-IsTemplateLikeObject -vm $vm)) {
                foreach ($guestDisk in (Get-VMGuestDisk -VM $vm -ErrorAction SilentlyContinue)) {
                    $matchedHardDisk = Get-HardDisk -VMGuestDisk $guestDisk -ErrorAction SilentlyContinue
                    if ($guestDisk.DiskPath) {
                        $guestDiskMap[$guestDisk.DiskPath] = [ordered]@{
                            HardDisk = $matchedHardDisk
                            DiskKey  = if ($matchedHardDisk) { $matchedHardDisk.ExtensionData.Key } else { $null }
                            VMDK     = if ($matchedHardDisk) { $matchedHardDisk.Name } else { $null }
                            VMDKPath = if ($matchedHardDisk) { $matchedHardDisk.Filename } else { $null }
                            VMDKUuid = if ($matchedHardDisk) { $matchedHardDisk.ExtensionData.Backing.Uuid } else { $null }
                        }
                    }
                }
            }
        }
        catch { }

        if ($ed.Guest.Disk) {
            foreach ($gdisk in $ed.Guest.Disk) {
                $matchedDisk = $null
                if ($gdisk.DiskPath -and $guestDiskMap.ContainsKey($gdisk.DiskPath)) {
                    $matchedDisk = $guestDiskMap[$gdisk.DiskPath]
                }

                [PSCustomObject]@{
                    Name                                     = $vm.Name
                    Powerstate                               = $effectivePowerState
                    Template                                 = $ed.Config.Template
                    "SRM Placeholder"                        = $false
                    DiskKey                                  = if ($matchedDisk) { $matchedDisk.DiskKey } else { $null }
                    "Partition Path"                         = if ($uuidDisabledWarning -and $gdisk.Path) { "$($gdisk.Path) <disk.enableuuid disabled>" } elseif ($gdisk.Path) { $gdisk.Path } else { $gdisk.DiskPath }
                    Disk                                     = $gdisk.DiskPath
                    VMDK                                     = if ($matchedDisk) { $matchedDisk.VMDK } else { $null }
                    "VMDK Path"                              = if ($matchedDisk) { $matchedDisk.VMDKPath } else { $null }
                    "VMDK UUID"                              = if ($matchedDisk) { $matchedDisk.VMDKUuid } else { $null }
                    "OS Family"                              = $osFamily
                    "Disk.EnableUUID"                        = $diskEnableUuid
                    "Mapping Available"                      = [bool]$matchedDisk
                    CapacityMB                               = [math]::Round($gdisk.Capacity / 1MB, 0)
                    ConsumedMB                               = [math]::Round((($gdisk.Capacity - $gdisk.FreeSpace) / 1MB), 0)
                    FreeMB                                   = [math]::Round($gdisk.FreeSpace / 1MB, 0)
                    FreePct                                  = if ($gdisk.Capacity -gt 0) { [math]::Round(($gdisk.FreeSpace / $gdisk.Capacity * 100), 0) } else { 0 }
                    InternalSortColumn                       = $gdisk.DiskPath
                    Annotation                               = $ed.Config.Annotation
                    "com.vrlcm.snapshot"                     = $null
                    Datacenter                               = $ctx.Datacenter
                    Cluster                                  = $ctx.Cluster
                    Host                                     = $runtimeHostName
                    Folder                                   = $ctx.Folder
                    "OS according to the configuration file" = $ed.Config.GuestFullName
                    "OS according to the VMware Tools"       = $toolsOsFullName
                    VM_ID                                    = $ed.MoRef.Value
                    UUID                                     = $ed.Config.Uuid
                    "VI SDK Server"                          = $about.FullName
                    "VI SDK UUID"                            = $about.InstanceUuid
                }
            }
        }
    }
    Write-InlineProgress -Activity 'vPartition Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null
}

function Get-vSCSI {
    param($vms, $about, $GetVMContextFn)
    $total = $vms.Count
    $i = 0

    foreach ($vm in $vms) {
        $i++
        Write-InlineProgress -Activity "Collecting vSCSI $i of $total VMs" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null

        $ed = $vm.ExtensionData
        $ctx = & $GetVMContextFn $vm
        $runtimeHostName = Get-VMRuntimeHostName -VM $vm
        $effectivePowerState = Get-VMEffectivePowerState -VM $vm
        $toolsOsFullName = Get-VMEffectiveToolsOS -VM $vm
       if ($ed.guest.guestfamily -like "*windowsGuest") {
            if($($VM | Get-AdvancedSetting -name "disk.EnableUUID") -like "*TRUE*"){
                $diskData = $true
            }else{
                $diskData = $false
            }
       }
       Else{$diskData=$true}
       If($diskData -and -not (Test-IsTemplateLikeObject -vm $vm)){
            foreach ($gDisk in (Get-VMGuestDisk -VM $vm -ErrorAction SilentlyContinue)) {

                # Map guest-visible disk/partition â†’ HardDisk â†’ SCSI controller
                $vDisk = Get-HardDisk -VMGuestDisk $gDisk -ErrorAction SilentlyContinue
                $ctlr = Get-ScsiController -VM $vm |
                Where-Object { $_.ExtensionData.Key -eq $vDisk.ExtensionData.ControllerKey }

                # Compose a clean SCSI â€œbus:unitâ€ string
                $SCSIbus = $ctlr.ExtensionData.BusNumber
                $unit = $vDisk.ExtensionData.UnitNumber
                $scsi = "$SCSIbus : $unit"
                [PSCustomObject]@{

                    Name                                     = $vm.Name
                    Annotation                               = $ed.Config.Annotation
                    Datacenter                               = $ctx.Datacenter
                    Cluster                                  = $ctx.Cluster
                    Host                                     = $runtimeHostName
                    Folder                                   = $ctx.Folder
                    "OS according to the configuration file" = $ed.Config.GuestFullName
                    "OS according to the VMware Tools"       = $toolsOsFullName
                    VM_ID                                    = $ed.MoRef.Value
                    UUID                                     = $ed.Config.Uuid
                    GuestDiskPath                            = $gDisk.DiskPath
                    CapacityGB                               = [math]::Round($gDisk.Capacity / 1GB, 2)
                    FreeGB                                   = [math]::Round($gDisk.FreeSpace / 1GB, 2)
                    SCSIname                                 = $ctlr.Name
                    SCSIControler                            = $SCSIbus
                    UnitNumber                               = $unit
                    SCSI_Path                                = $scsi
                    VMDK_Path                                = $vDisk.FileName
                    "VI SDK Server"                          = $about.FullName
                    "VI SDK UUID"                            = $about.InstanceUuid
                }
            }
        }
        else{
             $scsi = "$SCSIbus : $unit"
                [PSCustomObject]@{

                    Name                                     = $vm.Name
                    Annotation                               = "WINDOWS disk data requires Disk.enableUUID advanced setting"
                    Datacenter                               = ""
                    Cluster                                  = ""
                    Host                                     = ""
                    Folder                                   = ""
                    "OS according to the configuration file" = ""
                    "OS according to the VMware Tools"       = ""
                    VM_ID                                    = ""
                    UUID                                     = ""
                    GuestDiskPath                            = ""
                    CapacityGB                               = ""
                    FreeGB                                   = ""
                    SCSIname                                 = ""
                    SCSIControler                            = ""
                    UnitNumber                               = ""
                    SCSI_Path                                = ""
                    VMDK_Path                                = ""
                    "VI SDK Server"                          = ""
                    "VI SDK UUID"                            = ""
                }
        }

    }
    Write-InlineProgress -Activity 'vSCSI Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null
}

function Get-vNetwork {
    param($vms, $about, $GetVMContextFn)
    $total = $vms.Count
    $i = 0
    foreach ($vm in $vms) {
        $i++
        Write-InlineProgress -Activity "Collecting vNetwork $i of $total VMs" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null

        $ed = $vm.ExtensionData
        $ctx = & $GetVMContextFn $vm
        $runtimeHostName = Get-VMRuntimeHostName -VM $vm
        $effectivePowerState = Get-VMEffectivePowerState -VM $vm
        $toolsOsFullName = Get-VMEffectiveToolsOS -VM $vm
        foreach ($nic in $ed.Config.Hardware.Device | Where-Object { $_ -is [VMware.Vim.VirtualEthernetCard] }) {
            $networkName = $null
            $switchName = $null
            if ($nic.Backing -is [VMware.Vim.VirtualEthernetCardDistributedVirtualPortBackingInfo]) {
                $port = $nic.Backing.Port
                try {
                    $pgView = Get-View -Id $port.PortgroupKey -ErrorAction Stop
                    $networkName = $pgView.Name
                    $switchName = (Get-View -Id $pgView.Config.DistributedVirtualSwitch -ErrorAction Stop).Name
                }
                catch {
                    $networkName = $nic.DeviceInfo.Summary
                    $switchName = $nic.DeviceInfo.Summary
                }
            }
            elseif ($nic.Backing -is [VMware.Vim.VirtualEthernetCardNetworkBackingInfo]) {
                $networkName = $nic.Backing.DeviceName
                $switchName = $nic.Backing.DeviceName
            }
            else {
                $networkName = $nic.DeviceInfo.Summary
                $switchName = $nic.DeviceInfo.Summary
            }

            $guestNet = Get-VMGuestNetworkDetails -VM $vm -Nic $nic

            [PSCustomObject]@{
                Name                                     = $vm.Name
                Powerstate                               = $effectivePowerState
                Template                                 = $ed.Config.Template
                "SRM Placeholder"                        = $false
                Annotation                               = $ed.Config.Annotation
                Datacenter                               = $ctx.Datacenter
                Cluster                                  = $ctx.Cluster
                Host                                     = $runtimeHostName
                Folder                                   = $ctx.Folder
                "OS according to the configuration file" = $ed.Config.GuestFullName
                "OS according to the VMware Tools"       = $toolsOsFullName
                VM_ID                                    = $ed.MoRef.Value
                UUID                                     = $ed.Config.Uuid
                Adapter                                  = $nic.DeviceInfo.Label
                Network                                  = $networkName
                Switch                                   = $switchName
                MAC                                      = $nic.MacAddress
                Type                                     = $nic.GetType().Name
                Connected                                = $nic.Connectable.Connected
                StartConnected                           = $nic.Connectable.StartConnected
                "IPv4 Address"                           = $guestNet.IPv4
                "IPv6 Address"                           = $guestNet.IPv6
                "Direct Path IO"                         = (($nic.GetType().Name -match 'Sriov|Passthrough|DirectPath') -or (($null -ne $nic.Backing) -and ($nic.Backing.GetType().Name -match 'Sriov|Passthrough|DirectPath')) -or (($null -ne $nic.Connectable) -and ($nic.Connectable.GetType().Name -match 'Sriov|Passthrough|DirectPath')))
                "Internal Sort Column"                   = $nic.UnitNumber
                "com.vrlcm.snapshot"                     = $null
                "VI SDK Server"                          = $about.FullName
                "VI SDK UUID"                            = $about.InstanceUuid
            }
        }
    }
    Write-InlineProgress -Activity 'vNetwork Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null

}

function Get-vFloppy {
    param($vms, $about, $GetVMContextFn)
    $total = $vms.Count
    $i = 0
    foreach ($vm in $vms) {
        $i++
        Write-InlineProgress -Activity "Collecting vFloppy $i of $total VMs" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null


        $ed = $vm.ExtensionData
        $ctx = & $GetVMContextFn $vm
        $runtimeHostName = Get-VMRuntimeHostName -VM $vm
        $effectivePowerState = Get-VMEffectivePowerState -VM $vm
        $toolsOsFullName = Get-VMEffectiveToolsOS -VM $vm
        foreach ($fl in $ed.Config.Hardware.Device | Where-Object { $_ -is [VMware.Vim.VirtualFloppy] }) {
            [PSCustomObject]@{
                Name                                     = $vm.Name
                Annotation                               = $ed.Config.Annotation
                Datacenter                               = $ctx.Datacenter
                Cluster                                  = $ctx.Cluster
                Host                                     = $runtimeHostName
                Folder                                   = $ctx.Folder
                "OS according to the configuration file" = $ed.Config.GuestFullName
                "OS according to the VMware Tools"       = $toolsOsFullName
                VM_ID                                    = $ed.MoRef.Value
                UUID                                     = $ed.Config.Uuid
                Label                                    = $fl.DeviceInfo.Label
                Connected                                = $fl.Connectable.Connected
                StartConnected                           = $fl.Connectable.StartConnected
                Type                                     = $fl.Backing.GetType().Name
                Backing                                  = $fl.Backing.Filename
                "VI SDK Server"                          = $about.FullName
                "VI SDK UUID"                            = $about.InstanceUuid
            }
        }
    }
    Write-InlineProgress -Activity 'vFloppy Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null
}

function Get-vCD {
    param($vms, $about, $GetVMContextFn)
    $total = $vms.Count
    $i = 0
    foreach ($vm in $vms) {
        $i++
        Write-InlineProgress -Activity "Collecting vCD $i of $total VMs" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null


        $ed = $vm.ExtensionData
        $ctx = & $GetVMContextFn $vm
        $runtimeHostName = Get-VMRuntimeHostName -VM $vm
        $effectivePowerState = Get-VMEffectivePowerState -VM $vm
        $toolsOsFullName = Get-VMEffectiveToolsOS -VM $vm
        foreach ($cd in $ed.Config.Hardware.Device | Where-Object { $_ -is [VMware.Vim.VirtualCdrom] }) {
            [PSCustomObject]@{
                Name                                     = $vm.Name
                Powerstate                               = $effectivePowerState
                Template                                 = $ed.Config.Template
                "SRM Placeholder"                        = $false
                DeviceNode                               = $cd.DeviceInfo.Label
                Connected                                = $cd.Connectable.Connected
                StartConnected                           = $cd.Connectable.StartConnected
                Type                                     = $cd.Backing.GetType().Name
                Annotation                               = $ed.Config.Annotation
                "com.vrlcm.snapshot"                     = $null
                Datacenter                               = $ctx.Datacenter
                Cluster                                  = $ctx.Cluster
                Host                                     = $runtimeHostName
                Folder                                   = $ctx.Folder
                "OS according to the configuration file" = $ed.Config.GuestFullName
                "OS according to the VMware Tools"       = $toolsOsFullName
                VM_ID                                    = $ed.MoRef.Value
                UUID                                     = $ed.Config.Uuid
                VMRef                                    = $ed.MoRef.Value
                Backing                                  = $cd.Backing.Filename
                "VI SDK Server"                          = $about.FullName
                "VI SDK UUID"                            = $about.InstanceUuid
            }
        }
    }
    Write-InlineProgress -Activity 'vCD Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null
}

function Get-vSnapshot {
    param($vms, $about, $GetVMContextFn)
    $total = $vms.Count
    $i = 0
    foreach ($vm in $vms) {
        $i++
        Write-InlineProgress -Activity "Collecting vSnapshot $i of $total VMs" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null

        $ed = $vm.ExtensionData
        $ctx = & $GetVMContextFn $vm
        $runtimeHostName = Get-VMRuntimeHostName -VM $vm
        $effectivePowerState = Get-VMEffectivePowerState -VM $vm
        $toolsOsFullName = Get-VMEffectiveToolsOS -VM $vm
        if ($ed.Snapshot) {
            foreach ($snap in Get-Snapshot -vm $vm ) {

                [PSCustomObject]@{
                    Name                                     = $vm.Name
                    Powerstate                               = $effectivePowerState
                    SnapshotName                             = $snap.Name
                    Description                              = $snap.Description
                    Created                                  = $snap.Created
                    Filename                                 = if ($snap.ExtensionData.Config.FileName) { $snap.ExtensionData.Config.FileName } elseif ($snap.ExtensionData.ReplaySupported -ne $null) { ([string]$snap.ExtensionData) } else { "$($ed.LayoutEx.Snapshot | Select-Object -ExpandProperty Id -First 1)" }
                    SizeMiBVMSN                              = if ($snap.SizeGB -ne $null) { [math]::Round($snap.SizeGB * 1024,0) } else { $null }
                    SizeMiBTotal                             = if ($snap.SizeGB -ne $null) { [math]::Round($snap.SizeGB * 1024,0) } else { $null }
                    Quiesced                                 = $snap.Quiesced
                    State                                    = if ($snap.IsCurrent) { 'current' } else { 'notCurrent' }
                    Annotation                               = $ed.Config.Annotation
                    "com.vrlcm.snapshot"                     = $null
                    Datacenter                               = $ctx.Datacenter
                    Cluster                                  = $ctx.Cluster
                    Host                                     = $runtimeHostName
                    Folder                                   = $ctx.Folder
                    "OS according to the configuration file" = $ed.Config.GuestFullName
                    "OS according to the VMware Tools"       = $toolsOsFullName
                    VM_ID                                    = $ed.MoRef.Value
                    UUID                                     = $ed.Config.Uuid
                    "VI SDK Server"                          = $about.FullName
                    "VI SDK UUID"                            = $about.InstanceUuid
                }
            }
        }
    }
    Write-InlineProgress -Activity 'vSnapshot Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null
}

function Get-vTools {
    param($vms, $about, $GetVMContextFn, $PlatformToolsRequiredVersion)
    $total = $vms.Count
    $i = 0
    foreach ($vm in $vms) {
        $i++
        Write-InlineProgress -Activity "Collecting vTools $i of $total VMs" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null


        $ed = $vm.ExtensionData
        $ctx = & $GetVMContextFn $vm
        $runtimeHostName = Get-VMRuntimeHostName -VM $vm
        $effectivePowerState = Get-VMEffectivePowerState -VM $vm
        $toolsOsFullName = Get-VMEffectiveToolsOS -VM $vm

        $guestExt = $null
        try { $guestExt = $vm.Guest.ExtensionData } catch {}
        if (-not $guestExt) {
            try { $guestExt = $ed.Guest } catch {}
        }

        $toolsStatus2 = $null
        try { $toolsStatus2 = $guestExt.ToolsVersionStatus2 } catch {}

        $toolsVersionNumber = $null
        try { $toolsVersionNumber = $guestExt.ToolsVersion } catch {}

        $toolsInstallType = $null
        try { $toolsInstallType = $guestExt.ToolsInstallType } catch {}

        $requiredVersion = $PlatformToolsRequiredVersion
        if ($toolsStatus2 -eq 'guestToolsUnmanaged') {
            $requiredVersion = 'Unmanaged'
        }

        [PSCustomObject]@{
            Name                                     = $vm.Name
            Powerstate                               = $effectivePowerState
            Template                                 = $ed.Config.Template
            "SRM Placeholder"                        = $false
            Annotation                               = $ed.Config.Annotation
            Datacenter                               = $ctx.Datacenter
            Cluster                                  = $ctx.Cluster
            Host                                     = $runtimeHostName
            Folder                                   = $ctx.Folder
            "OS according to the configuration file" = $ed.Config.GuestFullName
            "OS according to the VMware Tools"       = $toolsOsFullName
            VM_ID                                    = $ed.MoRef.Value
            UUID                                     = $ed.Config.Uuid
            VMVersion                                = $ed.Config.Version -replace "vmx-", ""
            Tools                                    = $ed.Guest.ToolsStatus
            ToolsVersion                             = $toolsVersionNumber
            ToolsStatus2                             = $toolsStatus2
            ToolsInstallType                         = $toolsInstallType
            RequiredVersion                          = $requiredVersion
            SyncTime                                 = $ed.Config.Tools.SyncTimeWithHost
            AppStatus                                = $ed.Guest.AppState
            AppHeartbeat                             = $ed.Guest.AppHeartbeatStatus
            KernelCrash                              = $ed.Guest.GuestKernelCrashed
            OpsReady                                 = $ed.Guest.GuestOperationsReady
            InteractiveReady                         = $ed.Guest.InteractiveGuestOperationsReady
            StateChangeSupported                     = $ed.Guest.GuestStateChangeSupported
            ToolsUpgradePolicy                       = $ed.Config.Tools.ToolsUpgradePolicy
            "com.vrlcm.snapshot"                     = Get-VMAdvancedSettingValue -VM $vm -Name 'com.vrlcm.snapshot'
            "VI SDK Server"                          = $about.FullName
            "VI SDK UUID"                            = $about.InstanceUuid
        }
    }
    Write-InlineProgress -Activity 'vTools Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null
}

function Get-vRP {
    param($rpools, $about)
    $total = $rpools.Count
    $i = 0
    foreach ($rp in $rpools) {
        $i++
        Write-InlineProgress -Activity "Collecting pools $i of $total resource pools" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null

        $ed = $rp.ExtensionData
        $qs = $ed.Runtime.QuickStats
        $vmsInPool = $rp | Get-VM

        [PSCustomObject]@{
            Name                              = $rp.Name
            ResourcePoolPath                  = $rp.ExtensionData.Parent.Value
            Status                            = $ed.OverallStatus
            NumVMsTotal                       = $vmsInPool.Count
            NumVMs                            = $vmsInPool.Count
            vCPUs                             = ($vmsInPool | Measure-Object -Property NumCPU -Sum).Sum
            CPU_Limit                         = $ed.Config.CpuAllocation.Limit
            CPU_OverheadLimit                 = $null
            CPU_Reservation                   = $ed.Config.CpuAllocation.Reservation
            CPU_SharesLevel                   = $ed.Config.CpuAllocation.Shares.Level
            CPU_Shares                        = $ed.Config.CpuAllocation.Shares.Shares
            CPU_Expandable                    = $ed.Config.CpuAllocation.ExpandableReservation
            CPU_maxUsage                      = $ed.Runtime.Cpu.MaxUsage
            CPU_overallUsage                  = $ed.Runtime.Cpu.OverallUsage
            CPU_reservationUsed               = $ed.Runtime.Cpu.ReservationUsed
            CPU_reservationUsedForVm          = $ed.Runtime.Cpu.ReservationUsedForVm
            CPU_unreservedForPool             = $ed.Runtime.Cpu.UnreservedForPool
            CPU_unreservedForVm               = $ed.Runtime.Cpu.UnreservedForVm
            MemConfigured                     = ($vmsInPool | Measure-Object -Property MemoryMB -Sum).Sum
            Mem_Limit                         = $ed.Config.MemoryAllocation.Limit
            Mem_OverheadLimit                 = $null
            Mem_Reservation                   = $ed.Config.MemoryAllocation.Reservation
            Mem_SharesLevel                   = $ed.Config.MemoryAllocation.Shares.Level
            Mem_Shares                        = $ed.Config.MemoryAllocation.Shares.Shares
            Mem_Expandable                    = $ed.Config.MemoryAllocation.ExpandableReservation
            "Mem maxUsage"                    = $ed.Runtime.Memory.MaxUsage
            "Mem overallUsage"                = $ed.Runtime.Memory.OverallUsage
            "Mem reservationUsed"             = $ed.Runtime.Memory.ReservationUsed
            "Mem reservationUsedForVm"        = $ed.Runtime.Memory.ReservationUsedForVm
            "Mem unreservedForPool"           = $ed.Runtime.Memory.UnreservedForPool
            "Mem unreservedForVm"             = $ed.Runtime.Memory.UnreservedForVm
            ObjectID                          = $ed.MoRef.Value
            "QS overallCpuDemand"             = $qs.OverallCpuDemand
            "QS overallCpuUsage"              = $qs.OverallCpuUsage
            "QS staticCpuEntitlement"         = $qs.StaticCpuEntitlement
            "QS distributedCpuEntitlement"    = $qs.DistributedCpuEntitlement
            "QS balloonedMemory"              = $qs.BalloonedMemory
            "QS compressedMemory"             = $qs.CompressedMemory
            "QS consumedOverheadMemory"       = $qs.ConsumedOverheadMemory
            "QS distributedMemoryEntitlement" = $qs.DistributedMemoryEntitlement
            "QS guestMemoryUsage"             = $qs.GuestMemoryUsage
            "QS hostMemoryUsage"              = $qs.HostMemoryUsage
            "QS overheadMemory"               = $qs.OverheadMemory
            "QS privateMemory"                = $qs.PrivateMemory
            "QS sharedMemory"                 = $qs.SharedMemory
            "QS staticMemoryEntitlement"      = $qs.StaticMemoryEntitlement
            "QS swappedMemory"                = $qs.SwappedMemory
            "VI SDK Server"                   = $about.FullName
            "VI SDK UUID"                     = $about.InstanceUuid
        }
    }
    Write-InlineProgress -Activity 'vResourcePools Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null
}

function Get-vCluster {
    param($clusters, $about)
    $total = $clusters.Count
    $i = 0
    foreach ($cl in $clusters) {
        $i++
        Write-InlineProgress -Activity "Collecting vCluster $i of $total clusters" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null


        $ed = $cl.ExtensionData
        $das = $ed.Configuration.DasConfig
        $dasDef = $das.DefaultVmSettings
        $vmMonSettings = if ($dasDef -and $dasDef.PSObject.Properties.Name -contains 'VmToolsMonitoringSettings') { $dasDef.VmToolsMonitoringSettings } elseif ($dasDef -and $dasDef.PSObject.Properties.Name -contains 'VmMonitoringSettings') { $dasDef.VmMonitoringSettings } else { $null }
        $drs = $ed.Configuration.DrsConfig
        $dpm = if ($ed.ConfigurationEx -and $ed.ConfigurationEx.PSObject.Properties.Name -contains 'DpmConfigInfo' -and $ed.ConfigurationEx.DpmConfigInfo) { $ed.ConfigurationEx.DpmConfigInfo } else { $ed.Configuration.DpmConfig }
        [PSCustomObject]@{
            Name                            = $cl.Name
            "Config status"                 = $ed.OverallStatus
            OverallStatus                   = $ed.OverallStatus
            NumHosts                        = $ed.Summary.NumHosts
            numEffectiveHosts               = $ed.Summary.NumEffectiveHosts
            TotalCpu                        = $ed.Summary.TotalCpu
            NumCpuCores                     = $ed.Summary.NumCpuCores
            NumCpuThreads                   = $ed.Summary.NumCpuThreads
            "Effective Cpu"                 = $ed.Summary.EffectiveCpu
            TotalMemory                     = [math]::Round($ed.Summary.TotalMemory / 1MB, 0)
            "Effective Memory"              = $ed.Summary.EffectiveMemory
            "Num VMotions"                  = $ed.Summary.NumVmotions
            "HA enabled"                    = $das.Enabled
            "Failover Level"                = $das.FailoverLevel
            AdmissionControlEnabled         = $das.AdmissionControlEnabled
            "Host monitoring"               = $das.HostMonitoring
            "HB Datastore Candidate Policy" = $das.HBDatastoreCandidatePolicy
            "Isolation Response"            = $dasDef.IsolationResponse
            "Restart Priority"              = $dasDef.RestartPriority
            "Cluster Settings"              = $ed.ConfigurationEx.DasConfig.Enabled
            "Max Failures"                  = if ($vmMonSettings) { $vmMonSettings.MaxFailures } else { $null }
            "Max Failure Window"            = if ($vmMonSettings) { $vmMonSettings.MaxFailureWindow } else { $null }
            "Failure Interval"              = if ($vmMonSettings) { $vmMonSettings.FailureInterval } else { $null }
            "Min Up Time"                   = if ($vmMonSettings) { $vmMonSettings.MinUpTime } else { $null }
            "VM Monitoring"                 = $das.VmMonitoring
            "DRS enabled"                   = $drs.Enabled
            "DRS default VM behavior"       = $drs.DefaultVmBehavior
            "DRS vmotion rate"              = $drs.VmotionRate
            "DPM enabled"                   = if ($dpm.PSObject.Properties.Name -contains 'Enabled') { $dpm.Enabled } else { $null }
            "DPM default behavior"          = if ($dpm.PSObject.Properties.Name -contains 'DefaultDpmBehavior') { $dpm.DefaultDpmBehavior } elseif ($dpm.PSObject.Properties.Name -contains 'DefaultBehavior') { $dpm.DefaultBehavior } else { $null }
            "DPM Host Power Action Rate"    = if ($dpm.PSObject.Properties.Name -contains 'HostPowerActionRate') { $dpm.HostPowerActionRate } else { $null }
            ObjectID                        = $ed.MoRef.Value
            "com.vmware.vcenter.cluster.edrs.upgradeHostAdded" = (Get-AdvancedSetting -Entity $cl -Name 'com.vmware.vcenter.cluster.edrs.upgradeHostAdded' -ErrorAction SilentlyContinue).Value
            "com.vrlcm.snapshot"            = (Get-AdvancedSetting -Entity $cl -Name 'com.vrlcm.snapshot' -ErrorAction SilentlyContinue).Value
            "VI SDK Server"                 = $about.FullName
            "VI SDK UUID"                   = $about.InstanceUuid
        }
    }
    Write-InlineProgress -Activity 'vCluster Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null
}

function Get-PolicyValue {
    param(
        [Parameter(Mandatory=$false)] $PolicyObject,
        [Parameter(Mandatory=$false)] $DefaultValue = $null
    )
    try {
        if ($null -eq $PolicyObject) { return $DefaultValue }
        if ($PolicyObject.PSObject.Properties.Name -contains 'Inherited') {
            if ($PolicyObject.Inherited -eq $true) { return $DefaultValue }
        }
        if ($PolicyObject.PSObject.Properties.Name -contains 'Value') {
            if ($null -ne $PolicyObject.Value) { return $PolicyObject.Value }
        }
        return $PolicyObject
    }
    catch {
        return $DefaultValue
    }
}

function Get-HostContext {
    param([Parameter(Mandatory = $true)] $ESXhost)

    if (-not $script:HostContextCache) { $script:HostContextCache = @{} }

    $hostKey = $null
    try { $hostKey = $ESXhost.Id } catch {}
    if ([string]::IsNullOrWhiteSpace($hostKey)) { try { $hostKey = $ESXhost.ExtensionData.MoRef.Value } catch {} }
    if ([string]::IsNullOrWhiteSpace($hostKey)) { $hostKey = [string]$ESXhost.Name }

    if ($script:HostContextCache.ContainsKey($hostKey)) { return $script:HostContextCache[$hostKey] }

    $datacenter = $null
    $cluster = $null
    try { $datacenter = ($ESXhost | Get-Datacenter -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -First 1) } catch {}
    try { $cluster = ($ESXhost | Get-Cluster -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -First 1) } catch {}

    $ctx = [PSCustomObject]@{ Datacenter = $datacenter; Cluster = $cluster }
    $script:HostContextCache[$hostKey] = $ctx
    return $ctx
}

function Get-vHost {
    param($ESXhosts, $about)
    $total = $ESXhosts.Count
    $i = 0
    foreach ($ESXhost in $ESXhosts) {
        $i++
        Write-InlineProgress -Activity "Collecting vHost $i of $total hosts" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null


        $ed = $ESXhost.ExtensionData
        $prod = $ed.Summary.Config.Product
        $sys = $ed.Hardware.SystemInfo
        $bios = $ed.Hardware.BiosInfo
        $hostVMs = @($ESXhost | Get-VM)
        $hostNameCfg = $ed.Config.Network.DnsConfig.HostName
        $domainCfg = $ed.Config.Network.DnsConfig.DomainName
        $dnsServers = @($ed.Config.Network.DnsConfig.Address)
        $dnsSearchOrder = @($ed.Config.Network.DnsConfig.SearchDomain)
        $ntpServers = @($ed.Config.DateTimeInfo.NtpConfig.Server)
        $timeZoneObj = $ed.Config.DateTimeInfo.TimeZone
        $licenseKey = ($ESXhost | Select-Object -ExpandProperty LicenseKey -ErrorAction SilentlyContinue | Select-Object -First 1)
        $cert = Get-RemoteCertificateInfo -ComputerName $ESXhost.Name
        if (-not $cert) { $cert = $ed.Config.Certificate }
        $ed = $ESXhost.ExtensionData
        $hostNetwork = Get-VMHostNetwork -VMHost $ESXhost -ErrorAction SilentlyContinue
        $mgmtVmk = Get-VMHostNetworkAdapter -VMKernel -VMHost $ESXhost -ErrorAction SilentlyContinue | Where-Object { $_.ManagementTrafficEnabled } | Select-Object -First 1
        $hostCtx = Get-HostContext -ESXhost $ESXhost
        [PSCustomObject]@{
            Name               = $ESXhost.Name
            Datacenter         = $hostCtx.Datacenter
            Cluster            = $hostCtx.Cluster
            Status             = $ed.OverallStatus
            ComplianceCheckState = $ed.Summary.ComplianceCheckState
            InMaintenanceMode  = $ed.Runtime.InMaintenanceMode
            InQuarantineMode   = $ed.Runtime.InQuarantineMode
            CPUModel           = $ed.Summary.Hardware.CpuModel
            SpeedMHz           = $ed.Summary.Hardware.CpuMhz
            HT_Available       = $ed.Config.HyperThread.Available
            HT_Active          = $ed.Config.HyperThread.Active
            CPUPackages        = $ed.Summary.Hardware.NumCpuPkgs
            CoresPerCPU        = $ed.Summary.Hardware.NumCpuCores / $ed.Summary.Hardware.NumCpuPkgs
            TotalCores         = $ed.Summary.Hardware.NumCpuCores
            CPUUsagePct        = [math]::Round(($ed.Summary.QuickStats.OverallCpuUsage / ($ed.Summary.Hardware.CpuMhz * $ed.Summary.Hardware.NumCpuCores) * 100), 1)
            MemoryGB           = [math]::Round($ed.Summary.Hardware.MemorySize / 1MB, 0)
            MemoryTieringType  = $ed.Summary.Hardware.MemoryTieringType
            MemoryUsagePct     = [math]::Round(($ed.Summary.QuickStats.OverallMemoryUsage / ($ed.Summary.Hardware.MemorySize / 1MB) * 100), 1)
            Console            = 0
            NumNICs            = $ed.Config.Network.Pnic.Count
            NumHBAs            = $ed.Config.StorageDevice.HostBusAdapter.Count
            NumVMs             = @($hostVMs | Where-Object { -not $_.ExtensionData.Config.Template }).Count
            NumVMsTotal        = $hostVMs.Count
            VMsPerCore         = [math]::Round((($hostVMs.Count / $ed.Summary.Hardware.NumCpuCores)), 2)
            NumvCPUs           = ($hostVMs | Measure-Object -Property NumCpu -Sum).Sum
            vCPUsPerCore       = if ($ed.Summary.Hardware.NumCpuCores) { [math]::Round((($hostVMs | Measure-Object -Property NumCpu -Sum).Sum / $ed.Summary.Hardware.NumCpuCores),2) } else { $null }
            vRAM               = ($hostVMs | Measure-Object -Property MemoryMB -Sum).Sum
            VMUsedMemory       = $ed.Summary.QuickStats.OverallMemoryUsage
            VMMemorySwapped    = $ed.Summary.QuickStats.OverallMemoryUsage
            VMMemoryBallooned  = 0
            VMotionSupport     = $ed.Capability.VmotionSupported
            StorageVMotionSupport = $ed.Capability.StorageVMotionSupported
            CurrentEVC         = $ed.Summary.CurrentEVCModeKey
            MaxEVC             = $ed.Summary.MaxEVCModeKey
            vSANFaultDomainName = $null
            AssignedLicenses   = $licenseKey
            ATSHeartbeat       = $ed.Config.Option | Where-Object { $_.Key -eq 'VMFS3.UseATSForHBOnVMFS5' } | Select-Object -ExpandProperty Value -First 1
            ATSLocking         = $ed.Config.Option | Where-Object { $_.Key -eq 'VMFS3.HardwareAcceleratedLocking' } | Select-Object -ExpandProperty Value -First 1
            CurrentCPUPowerManPolicy = $ed.Config.PowerSystemInfo.CurrentPolicy.ShortName
            SupportedCPUPowerMan = (@($ed.Config.PowerSystemInfo.AvailablePolicy) | ForEach-Object { $_.ShortName }) -join ', '
            HostPowerPolicy    = $ed.Config.PowerSystemInfo.CurrentPolicy.Key
            ESXiVersion        = $prod.FullName
            BootTime           = $ed.Summary.Runtime.BootTime
            DNSServers         = ($dnsServers -join ', ')
            DHCP               = $mgmtVmk.DhcpEnabled
            Domain             = $domainCfg
            DomainList         = ($dnsSearchOrder -join ', ')
            DNSSearchOrder     = ($dnsSearchOrder -join ', ')
            NTPServers         = ($ntpServers -join ', ')
            NTPDRunning        = ((Get-VMHostService -VMHost $ESXhost -ErrorAction SilentlyContinue | Where-Object { $_.Key -eq 'ntpd' } | Select-Object -ExpandProperty Running -First 1))
            TimeZone           = $timeZoneObj.Key
            TimeZoneName       = $timeZoneObj.Name
            GMTOffset          = $timeZoneObj.GmtOffset
            Vendor             = $sys.Vendor
            Model              = $sys.Model
            Serial             = $sys.SerialNumber
            ServiceTag         = $sys.OtherIdentifyingInfo | Where-Object { $_.IdentifierType.Key -match 'ServiceTag|AssetTag' } | Select-Object -ExpandProperty IdentifierValue -First 1
            OEMSpecificString  = ($sys.OtherIdentifyingInfo | ForEach-Object { $_.IdentifierValue }) -join ', '
            BIOSVendor         = $bios.Vendor
            BIOSVersion        = $bios.BiosVersion
            BIOSDate           = $bios.ReleaseDate
            CertificateIssuer  = $cert.Issuer
            CertificateStartDate = $cert.NotBefore
            CertificateExpiryDate = $cert.NotAfter
            CertificateStatus  = if ($cert.NotAfter -and $cert.NotAfter -lt (Get-Date)) { 'expired' } elseif ($cert.NotAfter) { 'good' } else { $null }
            CertificateSubject = $cert.Subject
            ObjectID           = $ed.MoRef.Value
            "AutoDeploy.MachineIdentity" = (Get-AdvancedSetting -Entity $ESXHost -Name 'AutoDeploy.MachineIdentity' -ErrorAction SilentlyContinue).Value
            UUID               = $ed.Hardware.SystemInfo.Uuid
            "com.vrlcm.snapshot" = (Get-AdvancedSetting -Entity $ESXHost -Name 'com.vrlcm.snapshot' -ErrorAction SilentlyContinue).Value
            "VI SDK Server"    = $about.FullName
            "VI SDK UUID"      = $about.InstanceUuid
        }
    }
    Write-InlineProgress -Activity 'vHost Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null
}

function Get-vHBA {
    param($ESXhosts, $about)
    $total = $ESXhosts.Count
    $i = 0

    foreach ($ESXhost in $ESXhosts) {
        $i++
        Write-InlineProgress -Activity "Collecting vHBA $i of $total hosts" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null


        $ed = $ESXhost.ExtensionData
        $hostCtx = Get-HostContext -ESXhost $ESXhost
        $dcName = $hostCtx.Datacenter
        $clusterName = $hostCtx.Cluster
        foreach ($hba in $ed.Config.StorageDevice.HostBusAdapter) {
            [PSCustomObject]@{
                Host              = $ESXhost.Name
                Datacenter        = $dcName
                Cluster           = $clusterName
                HBADevice         = $hba.Device
                Model             = $hba.Model
                Type              = $hba.Model -replace ' Controller$',''
                Status            = $hba.Status
                Bus               = $hba.Bus
                NodeWorldWideName = $hba.NodeWorldWideName
                PortWorldWideName = $hba.PortWorldWideName
                Driver            = $hba.Driver
                PCI               = $hba.Pci
                "VI SDK Server"   = $about.FullName
                "VI SDK UUID"     = $about.InstanceUuid
            }
        }
    }
    Write-InlineProgress -Activity 'vHBA Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null
}

function Get-vNIC {
    param($ESXhosts, $about)
    $total = $ESXhosts.Count
    $i = 0
    foreach ($ESXhost in $ESXhosts) {
        $i++
        Write-InlineProgress -Activity "Collecting vNIC $i of $total hosts" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null

        $ed = $ESXhost.ExtensionData
        $hostCtx = Get-HostContext -ESXhost $ESXhost
        $dcName = $hostCtx.Datacenter
        $clusterName = $hostCtx.Cluster
        foreach ($pnic in $ed.Config.Network.Pnic) {
            $switchName = ((Get-VirtualSwitch -VMHost $ESXhost -Standard -ErrorAction SilentlyContinue | Where-Object { $_.Nic -contains $pnic.Device } | Select-Object -ExpandProperty Name -First 1))
            [PSCustomObject]@{
                Host            = $ESXhost.Name
                Datacenter      = $dcName
                Cluster         = $clusterName
                PNICDevice      = $pnic.Device
                MAC             = $pnic.Mac
                LinkSpeed       = $pnic.LinkSpeed.SpeedMb
                Duplex          = $pnic.LinkSpeed.Duplex
                Driver          = $pnic.Driver
                Switch          = $switchName
                UplinkPort      = $null
                PCI             = $pnic.Pci
                WakeOnLAN       = $pnic.WakeOnLanSupported
                "VI SDK Server" = $about.FullName
                "VI SDK UUID"   = $about.InstanceUuid
            }
        }
    }
    Write-InlineProgress -Activity 'vNIC Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null
}

function Get-vSwitch {
    param($ESXhosts, $about)
    $total = $ESXhosts.Count
    $i = 0
    foreach ($ESXhost in $ESXhosts) {
        $i++
        Write-InlineProgress -Activity "Collecting vSwitch $i of $total hosts" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null

        $hostCtx = Get-HostContext -ESXhost $ESXhost
        $dcName = $hostCtx.Datacenter
        $clusterName = $hostCtx.Cluster
        $hostEd = $ESXhost.ExtensionData
        foreach ($vs in Get-VirtualSwitch -VMHost $ESXhost -Standard) {
            $vsExt = $vs.ExtensionData
            $policy = $vsExt.Spec.Policy
            [PSCustomObject]@{
                Host              = $ESXhost.Name
                Datacenter        = $dcName
                Cluster           = $clusterName
                vSwitch           = $vs.Name
                NumPorts          = $vsExt.NumPorts
                NumPortsAvailable = $vsExt.NumPortsAvailable
                MTU               = $vs.Mtu
                Nic               = ($vs.Nic -join ',')
                ActiveNic         = $vsExt.Spec.Policy.NicTeaming.NicOrder.ActiveNic -join ','
                StandbyNic        = $vsExt.Spec.Policy.NicTeaming.NicOrder.StandbyNic -join ','
                AllowPromiscuous  = Get-PolicyValue -PolicyObject $policy.Security.AllowPromiscuous
                ForgedTransmits   = Get-PolicyValue -PolicyObject $policy.Security.ForgedTransmits
                MacChanges        = Get-PolicyValue -PolicyObject $policy.Security.MacChanges
                TrafficShaping    = Get-PolicyValue -PolicyObject $policy.ShapingPolicy.Enabled
                Width             = Get-PolicyValue -PolicyObject $policy.ShapingPolicy.AverageBandwidth -DefaultValue 0
                Peak              = Get-PolicyValue -PolicyObject $policy.ShapingPolicy.PeakBandwidth -DefaultValue 0
                Burst             = Get-PolicyValue -PolicyObject $policy.ShapingPolicy.BurstSize -DefaultValue 0
                Policy            = Get-PolicyValue -PolicyObject $policy.NicTeaming.Policy
                ReversePolicy     = Get-PolicyValue -PolicyObject $policy.NicTeaming.ReversePolicy
                NotifySwitch      = Get-PolicyValue -PolicyObject $policy.NicTeaming.NotifySwitches
                RollingOrder      = Get-PolicyValue -PolicyObject $policy.NicTeaming.RollingOrder
                Offload           = $true
                TSO               = if ($null -ne $hostEd.Capability.TsoSupported) { $hostEd.Capability.TsoSupported } else { $true }
                ZeroCopyXmit      = if ($null -ne $hostEd.Capability.ZeroCopyXmitSupported) { $hostEd.Capability.ZeroCopyXmitSupported } else { $true }
                CheckBeacon       = Get-PolicyValue -PolicyObject $policy.NicTeaming.FailureCriteria.CheckBeacon
                "VI SDK Server"   = $about.FullName
                "VI SDK UUID"     = $about.InstanceUuid
            }
        }
    }
    Write-InlineProgress -Activity 'vSwitch Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null
}

function Get-vPort {
    param($ESXhosts, $about)
    $total = $ESXhosts.Count
    $i = 0
    foreach ($ESXhost in $ESXhosts) {
        $i++
        Write-InlineProgress -Activity "Collecting vPort $i of $total hosts" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null

        $hostCtx = Get-HostContext -ESXhost $ESXhost
        $dcName = $hostCtx.Datacenter
        $clusterName = $hostCtx.Cluster
        $hostEd = $ESXhost.ExtensionData
        $vSwitchIndex = @{}
        foreach ($vs in Get-VirtualSwitch -VMHost $ESXhost -Standard -ErrorAction SilentlyContinue) {
            $vSwitchIndex[$vs.Name] = $vs.ExtensionData.Spec.Policy
        }

        foreach ($pg in Get-VirtualPortGroup -VMHost $ESXhost -Standard) {
            $pgExt = $pg.ExtensionData
            $policy = $pgExt.Spec.Policy
            $switchPolicy = $null
            if ($vSwitchIndex.ContainsKey($pg.VirtualSwitchName)) { $switchPolicy = $vSwitchIndex[$pg.VirtualSwitchName] }

            [PSCustomObject]@{
                Host             = $ESXhost.Name
                Datacenter       = $dcName
                Cluster          = $clusterName
                PortGroup        = $pg.Name
                vSwitch          = $pg.VirtualSwitchName
                VLANId           = $pg.VlanId
                NumPorts         = $pgExt.NumPorts
                ActivePorts      = $pgExt.NumPortsActive
                AllowPromiscuous = Get-PolicyValue -PolicyObject $policy.Security.AllowPromiscuous -DefaultValue (Get-PolicyValue -PolicyObject $switchPolicy.Security.AllowPromiscuous)
                ForgedTransmits  = Get-PolicyValue -PolicyObject $policy.Security.ForgedTransmits -DefaultValue (Get-PolicyValue -PolicyObject $switchPolicy.Security.ForgedTransmits)
                MacChanges       = Get-PolicyValue -PolicyObject $policy.Security.MacChanges -DefaultValue (Get-PolicyValue -PolicyObject $switchPolicy.Security.MacChanges)
                TrafficShaping   = Get-PolicyValue -PolicyObject $policy.ShapingPolicy.Enabled -DefaultValue (Get-PolicyValue -PolicyObject $switchPolicy.ShapingPolicy.Enabled)
                Width            = Get-PolicyValue -PolicyObject $policy.ShapingPolicy.AverageBandwidth -DefaultValue (Get-PolicyValue -PolicyObject $switchPolicy.ShapingPolicy.AverageBandwidth -DefaultValue 0)
                Peak             = Get-PolicyValue -PolicyObject $policy.ShapingPolicy.PeakBandwidth -DefaultValue (Get-PolicyValue -PolicyObject $switchPolicy.ShapingPolicy.PeakBandwidth -DefaultValue 0)
                Burst            = Get-PolicyValue -PolicyObject $policy.ShapingPolicy.BurstSize -DefaultValue (Get-PolicyValue -PolicyObject $switchPolicy.ShapingPolicy.BurstSize -DefaultValue 0)
                Policy           = Get-PolicyValue -PolicyObject $policy.NicTeaming.Policy -DefaultValue (Get-PolicyValue -PolicyObject $switchPolicy.NicTeaming.Policy)
                ReversePolicy    = Get-PolicyValue -PolicyObject $policy.NicTeaming.ReversePolicy -DefaultValue (Get-PolicyValue -PolicyObject $switchPolicy.NicTeaming.ReversePolicy)
                NotifySwitch     = Get-PolicyValue -PolicyObject $policy.NicTeaming.NotifySwitches -DefaultValue (Get-PolicyValue -PolicyObject $switchPolicy.NicTeaming.NotifySwitches)
                RollingOrder     = Get-PolicyValue -PolicyObject $policy.NicTeaming.RollingOrder -DefaultValue (Get-PolicyValue -PolicyObject $switchPolicy.NicTeaming.RollingOrder)
                Offload          = $true
                TSO              = if ($null -ne $hostEd.Capability.TsoSupported) { $hostEd.Capability.TsoSupported } else { $true }
                ZeroCopyXmit     = if ($null -ne $hostEd.Capability.ZeroCopyXmitSupported) { $hostEd.Capability.ZeroCopyXmitSupported } else { $true }
                "VI SDK Server"  = $about.FullName
                "VI SDK UUID"    = $about.InstanceUuid
            }
        }
    }
    Write-InlineProgress -Activity 'vPort Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null
}

function Get-vdvSwitch {
    param($about, $Server)
    $allDVS = if ($null -ne $Server) { Get-vdSwitch -Server $Server } else { Get-vdSwitch }
    $total = $allDVS.Count
    $i = 0
    foreach ($dvs in $allDVS) {
        $i++
        Write-InlineProgress -Activity "Collecting dvSwitch $i of $total dvSwitches" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null
        $dvsExt = $dvs.ExtensionData
        [PSCustomObject]@{
            Name             = $dvs.Name
            Version          = $dvs.Version
            NumPorts         = $dvs.NumPorts
            NumUplinks       = $dvs.NumUplinks
            MTU              = $dvs.Mtu
            Description      = $dvs.Description
            Uplinks          = ($dvs.UplinkPortPolicy.UplinkPortName -join ',')
            AllowPromiscuous = $dvsExt.Config.DefaultPortConfig.SecurityPolicy.AllowPromiscuous.Value
            ForgedTransmits  = $dvsExt.Config.DefaultPortConfig.SecurityPolicy.ForgedTransmits.Value
            MacChanges       = $dvsExt.Config.DefaultPortConfig.SecurityPolicy.MacChanges.Value
            Datacenter       = $dvs.VMwareDatacenter.Name
            "VI SDK Server"  = $about.FullName
            "VI SDK UUID"    = $about.InstanceUuid
        }
    }
    Write-InlineProgress -Activity 'dvSwitches Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null
}

function Get-vdvPort {
    param($about, $Server)
    $allDVport = if ($null -ne $Server) { Get-VDPortgroup -Server $Server } else { Get-VDPortgroup }
    $total = $allDVport.Count
    $i = 0
    foreach ($dvpg in $allDVport) {
        $i++
        Write-InlineProgress -Activity "Collecting dvPorts $i of $total dvPorts" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null
        $dvpgExt = $dvpg.ExtensionData
        [PSCustomObject]@{
            Name            = $dvpg.Name
            VDSwitch        = $dvpg.VDSwitch.Name
            VLANId          = $dvpg.VlanConfiguration.VlanId
            NumPorts        = $dvpg.NumPorts
            ActivePorts     = $dvpgExt.RuntimeInfo.PortCount
            Type            = $dvpg.PortBinding
            Description     = $dvpg.Description
            "VI SDK Server" = $about.FullName
            "VI SDK UUID"   = $about.InstanceUuid
        }
    }
    Write-InlineProgress -Activity 'dvPorts Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null

}

function Get-vSC_VMK {
    param($ESXhosts, $about)
    $total = $ESXhosts.Count
    $i = 0
    foreach ($ESXhost in $ESXhosts) {
        $i++
        Write-InlineProgress -Activity "Collecting vSC_VMK $i of $total hosts" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null


        $hostCtx = Get-HostContext -ESXhost $ESXhost
        $dcName = $hostCtx.Datacenter
        $clusterName = $hostCtx.Cluster
        $ed = $ESXhost.ExtensionData
        $hostNetwork = Get-VMHostNetwork -VMHost $ESXhost -ErrorAction SilentlyContinue
        foreach ($vmk in Get-VMHostNetworkAdapter -VMKernel -VMHost $ESXhost) {
            [PSCustomObject]@{
                Host                  = $ESXhost.Name
                Datacenter            = $dcName
                Cluster               = $clusterName
                VMKernelAdapter       = $vmk.Name
                IPAddress             = $vmk.IP
                SubnetMask            = $vmk.SubnetMask
                MAC                   = $vmk.Mac
                MTU                   = $vmk.Mtu
                vSwitch               = $vmk.VirtualSwitch
                PortGroup             = $vmk.PortGroupName
                DHCPEnabled           = $vmk.DhcpEnabled
                Gateway               = if ($ed.Config.Network.IpRouteConfig) { $ed.Config.Network.IpRouteConfig.DefaultGateway } else { $null }
                IPv6                  = $vmk.IPv6[0].address
                IPv6Gateway           = if ($ed.Config.Network.PSObject.Properties.Name -contains 'IpV6RouteConfig') { $ed.Config.Network.IpV6RouteConfig.DefaultGateway } else { $null }
                Management            = $vmk.ManagementTrafficEnabled
                FaultTolerance        = $vmk.FaultToleranceLoggingEnabled
                vMotion               = $vmk.VMotionEnabled
                vSAN                  = $vmk.VsanTrafficEnabled
                Provisioning          = $vmk.ProvisioningTrafficEnabled
                VSphereReplication    = $vmk.VSphereReplicationTrafficEnabled
                VSphereReplicationNFC = $vmk.VSphereReplicationNfcEnabled
                "VI SDK Server"       = $about.FullName
                "VI SDK UUID"         = $about.InstanceUuid
            }
        }
    }
    Write-InlineProgress -Activity 'vSC_VMK Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null
}

function Get-vDatastore {
    param($datastores, $about)
    $total = $datastores.Count; $i = 0
    foreach ($ds in $datastores) {
        $i++
        Write-InlineProgress -Activity "Collecting vDatastore $i of $total datastores" `
            -PercentComplete ([int](($i / $total) * 100)) `
            -ProgressCharacter ([char]9632) `
            -ProgressFillCharacter ([char]9632) `
            -ProgressFill ([char]183) `
            -BarBracketStart $null `
            -BarBracketEnd $null


        $dsExt = $ds.ExtensionData
        $ESXhostsOnDS = ($ds | Get-VMHost) | Select-Object -ExpandProperty Name
        $hostsOnDs = @($ds | Get-VMHost)
        $clusterNames = @($hostsOnDs | Get-Cluster | Select-Object -ExpandProperty Name -Unique)
        $vmCount = ($ds | Get-VM).Count
        $capMiB = [math]::Round(($ds.CapacityGB * 1024), 0)
        $freeMiB = [math]::Round(($ds.FreeSpaceGB * 1024), 0)
        $provisionedMiB = if ($ds.ExtensionData.Summary.Capacity -and $ds.ExtensionData.Summary.FreeSpace) { [math]::Round((($ds.ExtensionData.Summary.Capacity - $ds.ExtensionData.Summary.FreeSpace) / 1MB), 0) } else { $null }
        [PSCustomObject]@{
            Name            = $ds.Name
            ConfigStatus    = $ds.ExtensionData.OverallStatus
            Address         = $ds.ExtensionData.Info.Vmfs.Extent | ForEach-Object { $_.DiskName } | Select-Object -First 1
            Accessible      = $ds.ExtensionData.Summary.Accessible
            Type            = $ds.Type
            NumVMsTotal     = $vmCount
            NumVMs          = $vmCount
            CapacityMiB     = $capMiB
            ProvisionedMiB  = $provisionedMiB
            InUseMiB        = if ($capMiB -and $freeMiB) { $capMiB - $freeMiB } else { $null }
            FreeMiB         = $freeMiB
            FreePct         = if ($capMiB) { [math]::Round(($freeMiB / $capMiB) * 100, 1) } else { $null }
            SIOCEnabled     = $ds.ExtensionData.IormConfiguration.Enabled
            SIOCThreshold   = if ($ds.ExtensionData.IormConfiguration) { $ds.ExtensionData.IormConfiguration.CongestionThreshold } else { $null }
            NumHosts        = $hostsOnDs.Count
            Hosts           = ($ESXhostsOnDS -join ', ')
            Cluster         = ($clusterNames -join ', ')
            ClusterCapacityMiB = $capMiB
            ClusterFreeSpaceMiB = $freeMiB
            BlockSize       = $ds.ExtensionData.Info.Vmfs.BlockSizeMb
            MaxBlocks       = $ds.ExtensionData.Info.Vmfs.MaxBlocks
            NumExtents      = @($ds.ExtensionData.Info.Vmfs.Extent).Count
            MajorVersion    = $ds.ExtensionData.Info.Vmfs.MajorVersion
            Version         = $ds.ExtensionData.Info.Vmfs.Version
            VMFSUpgradeable = $ds.ExtensionData.Info.Vmfs.VmfsUpgradable
            MHA             = $ds.ExtensionData.Summary.MultipleHostAccess
            Datacenter      = ($hostsOnDs | Get-Cluster | Get-Datacenter | Select-Object -ExpandProperty Name -Unique) -join ', '
            URL             = $dsExt.Info.Url
            ObjectID        = $dsExt.MoRef.Value
            UUID            = $dsExt.Info.MembershipUuid
            "com.vrlcm.snapshot" = ''
            "VI SDK Server" = $about.FullName
            "VI SDK UUID"   = $about.InstanceUuid
        }
    }
    Write-InlineProgress -Activity 'vDatastore Processed' -Complete -ProgressCharacter ([char]9632) -ProgressFillCharacter ([char]9632) -ProgressFill ([char]183) -BarBracketStart $null -BarBracketEnd $null
}

function Get-vLicense {
    param($about, $Server)
    foreach ($lic in $(Get-View -Id 'LicenseManager' -Server $Server).Licenses) {
        $expiration = ($lic.Properties | Where-Object { $_.Key -match 'expirationDate|expiration' } | Select-Object -ExpandProperty Value -First 1)
        if (-not $expiration -and $lic.Name -ne 'Product Evaluation') { $expiration = 'Never' }

        $featureValues = foreach ($prop in @($lic.Properties | Where-Object { $_.Key -eq 'feature' })) {
            if ($prop.Value -is [System.Array]) {
                foreach ($entry in $prop.Value) {
                    if ($entry -and $entry.PSObject.Properties.Name -contains 'Value') { $entry.Value }
                    elseif ($entry -and $entry.PSObject.Properties.Name -contains 'Key') { $entry.Key }
                    else { [string]$entry }
                }
            }
            elseif ($prop.Value -and $prop.Value.PSObject.Properties.Name -contains 'Value') {
                $prop.Value.Value
            }
            else {
                $prop.Value
            }
        }

        [PSCustomObject]@{
            Name            = $lic.Name
            LicenseKey      = $lic.LicenseKey
            EditionKey      = $lic.EditionKey
            CostUnit        = $lic.costunit
            Total           = if ($lic.Total -eq 0 -and $lic.Name -ne 'Product Evaluation') { 'Unlimited' } else { $lic.Total }
            Used            = $lic.Used
            ExpirationDate  = $expiration
            Features        = (($featureValues | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ', ')
            "VI SDK Server" = $about.FullName
            "VI SDK UUID"   = $about.InstanceUuid
        }
    }
}
