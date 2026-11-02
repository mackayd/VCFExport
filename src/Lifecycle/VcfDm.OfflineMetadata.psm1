Set-StrictMode -Version Latest

$script:CriticalSuffixes = [ordered]@{
    ProductCatalog = 'metadata/productversioncatalog/v1/productversioncatalog.json'
    Manifest       = 'metadata/manifest/v1/vcfmanifest.json'
}

$script:OptionalSuffixes = [ordered]@{
    Signature      = 'metadata/productversioncatalog/v1/productversioncatalog.sig'
    Compatibility  = 'comp/sddc_manager_vcf/compatibility/vmwarecompatibilitydata.json'
    VsanHcl        = 'vsan/hcl/all.json'
    VsanHclTime    = 'vsan/hcl/lastupdatedtime.json'
}

function Test-VcfDmArchiveEntryName {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Name)

    $normalized = $Name.Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $false }
    if ($normalized.StartsWith('/') -or $normalized.StartsWith('//')) { return $false }
    if ($normalized -match '^[a-zA-Z]:/' -or $normalized -match '(^|/)[a-zA-Z]:($|/)') { return $false }
    if (@($normalized.Split('/') | Where-Object { $_ -eq '..' }).Count -gt 0) { return $false }
    return $true
}

function Get-VcfDmMetadataKindForPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RelativePath)

    $normalized = $RelativePath.Replace('\', '/').TrimStart('/').ToLowerInvariant()
    foreach ($key in $script:CriticalSuffixes.Keys) {
        if ($normalized.EndsWith($script:CriticalSuffixes[$key])) { return $key }
    }
    foreach ($key in $script:OptionalSuffixes.Keys) {
        if ($normalized.EndsWith($script:OptionalSuffixes[$key])) { return $key }
    }
    return $null
}

function ConvertFrom-VcfDmMetadataJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Json,
        [Parameter(Mandatory)] [string] $LogicalName
    )

    try {
        return $Json | ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop
    }
    catch {
        throw [System.IO.InvalidDataException]::new("Malformed JSON in $LogicalName metadata.")
    }
}

function Get-VcfDmNestedValue {
    [CmdletBinding()]
    param(
        [System.Collections.IDictionary] $Object,
        [Parameter(Mandatory)] [string[]] $Paths
    )

    foreach ($path in $Paths) {
        $current = $Object
        $found = $true
        foreach ($segment in ($path -split '\.')) {
            if ($current -isnot [System.Collections.IDictionary] -or -not $current.Contains($segment)) {
                $found = $false
                break
            }
            $current = $current[$segment]
        }
        if ($found -and $null -ne $current) { return $current }
    }
    return $null
}

function Get-VcfDmReleaseCandidates {
    [CmdletBinding()]
    param(
        [System.Collections.IDictionary] $ProductCatalog,
        [System.Collections.IDictionary] $Manifest
    )

    $versions = [System.Collections.Generic.List[string]]::new()
    if ($Manifest) {
        $releases = Get-VcfDmNestedValue -Object $Manifest -Paths @('releases', 'vcfReleases', 'versions')
        foreach ($release in @($releases)) {
            if ($release -is [string] -and $release -match '^\d+(\.\d+){2,4}([+\-].*)?$') {
                $versions.Add($release)
            }
            elseif ($release -is [System.Collections.IDictionary]) {
                foreach ($field in @('vcfVersion', 'releaseVersion', 'productVersion', 'version')) {
                    if ($release.Contains($field) -and [string]$release[$field] -match '^\d+(\.\d+){2,4}([+\-].*)?$') {
                        $versions.Add([string]$release[$field])
                        break
                    }
                }
            }
        }
    }
    # A VCF manifest release is authoritative for the VCF release. Product
    # catalog versions normally describe individual components, so use the
    # catalog only as a constrained SDDC Manager fallback when a manifest has
    # no release list.
    if ($versions.Count -eq 0 -and $ProductCatalog) {
        $patches = Get-VcfDmNestedValue -Object $ProductCatalog -Paths @('patches.patches', 'patches', 'productVersions')
        $candidateSets = if ($patches -is [System.Collections.IDictionary]) {
            @($patches.GetEnumerator() | Where-Object { $_.Key -match '(?i)^SDDC_MANAGER(_VCF)?$' } | ForEach-Object { $_.Value })
        }
        else { @($patches) }
        foreach ($set in $candidateSets) {
            foreach ($patch in @($set)) {
                if ($patch -is [System.Collections.IDictionary]) {
                    foreach ($field in @('vcfVersion', 'releaseVersion', 'productVersion', 'version')) {
                        if ($patch.Contains($field) -and [string]$patch[$field] -match '^\d+(\.\d+){2,4}([+\-].*)?$') {
                            $versions.Add([string]$patch[$field])
                            break
                        }
                    }
                }
            }
        }
    }
    return @($versions | Select-Object -Unique)
}

function ConvertTo-VcfDmCatalogRows {
    [CmdletBinding()]
    param(
        [System.Collections.IDictionary] $ProductCatalog,
        [Parameter(Mandatory)] [string] $CatalogSource,
        [Parameter(Mandatory)] [string] $CollectionStatus
    )

    if (-not $ProductCatalog) { return @() }
    $catalogVersion = Get-VcfDmNestedValue -Object $ProductCatalog -Paths @('version', 'catalogVersion')
    $sequence = Get-VcfDmNestedValue -Object $ProductCatalog -Paths @('sequenceNumber', 'sequence')
    $creation = Get-VcfDmNestedValue -Object $ProductCatalog -Paths @('creationTime', 'creationUtc')
    $published = Get-VcfDmNestedValue -Object $ProductCatalog -Paths @('publishedTime', 'publishedUtc', 'publicationTime')
    $patches = Get-VcfDmNestedValue -Object $ProductCatalog -Paths @('patches.patches', 'patches', 'productVersions', 'releases')
    $rows = [System.Collections.Generic.List[object]]::new()
    $catalogGroups = if ($patches -is [System.Collections.IDictionary]) {
        @($patches.GetEnumerator() | ForEach-Object { [pscustomobject]@{ ComponentType = [string]$_.Key; Items = $_.Value } })
    }
    else {
        @([pscustomobject]@{ ComponentType = $null; Items = $patches })
    }
    foreach ($group in $catalogGroups) {
      foreach ($patch in @($group.Items)) {
        if ($patch -isnot [System.Collections.IDictionary]) { continue }
        $productVersion = Get-VcfDmNestedValue -Object $patch -Paths @('productVersion', 'vcfVersion', 'releaseVersion', 'version')
        $artifacts = Get-VcfDmNestedValue -Object $patch -Paths @('artifacts.bundles', 'bundles')
        if (@($artifacts).Count -eq 0) {
            $rows.Add([pscustomobject][ordered]@{
                CatalogSource = $CatalogSource; CatalogVersion = $catalogVersion; SequenceNumber = $sequence
                CreationUTC = $creation; PublishedUTC = $published; ProductVersion = $productVersion
                ReleaseDate = $patch.releaseDate; Description = $patch.description; BundleId = $null
                BundleType = $null; BundleName = $null; BinaryFileName = $null; BinarySize = $null
                BinaryChecksum = $null; MetadataTags = $group.ComponentType; CatalogAgeDays = $null
                CollectionStatus = $CollectionStatus
            })
            continue
        }
        foreach ($bundle in @($artifacts)) {
            if ($bundle -isnot [System.Collections.IDictionary]) { continue }
            $binaries = @($bundle.binaries)
            if (@($binaries).Count -eq 0) { $binaries = ,$null }
            foreach ($binary in $binaries) {
                $rows.Add([pscustomobject][ordered]@{
                    CatalogSource = $CatalogSource; CatalogVersion = $catalogVersion; SequenceNumber = $sequence
                    CreationUTC = $creation; PublishedUTC = $published; ProductVersion = $productVersion
                    ReleaseDate = $patch.releaseDate; Description = $patch.description; BundleId = $bundle.id
                    BundleType = $bundle.type; BundleName = $bundle.name
                    BinaryFileName = if ($binary) { $binary.fileName } else { $null }
                    BinarySize = if ($binary) { $binary.size } else { $null }
                    BinaryChecksum = if ($binary) { $binary.checksum } else { $null }
                    MetadataTags = $group.ComponentType; CatalogAgeDays = $null; CollectionStatus = $CollectionStatus
                })
            }
        }
      }
    }
    return @($rows)
}

function Get-VcfDmLatestVersion {
    [CmdletBinding()]
    param([string[]] $Versions)

    $valid = @($Versions | Where-Object { $_ -match '^\d+(\.\d+){2,4}' })
    if ($valid.Count -eq 0) { return $null }
    return $valid | Sort-Object -Descending -Property {
        $numbers = @(([regex]::Matches($_, '\d+')) | ForEach-Object { [int64]$_.Value })
        ('{0:D10}.{1:D10}.{2:D10}.{3:D10}.{4:D10}' -f $numbers[0], $numbers[1], $numbers[2], $(if ($numbers.Count -gt 3) { $numbers[3] } else { 0 }), $(if ($numbers.Count -gt 4) { $numbers[4] } else { 0 }))
    } | Select-Object -First 1
}

function New-VcfDmMetadataResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SourceType,
        [Parameter(Mandatory)] [string] $FileName,
        [string] $ArchiveSha256,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Documents,
        [Parameter(Mandatory)] [hashtable] $Presence
    )

    $catalog = $Documents.ProductCatalog
    $manifest = $Documents.Manifest
    $creation = if ($catalog) { Get-VcfDmNestedValue -Object $catalog -Paths @('creationTime', 'creationUtc') } else { $null }
    $published = if ($catalog) { Get-VcfDmNestedValue -Object $catalog -Paths @('publishedTime', 'publishedUtc', 'publicationTime') } else { $null }
    $versions = Get-VcfDmReleaseCandidates -ProductCatalog $catalog -Manifest $manifest
    $latest = Get-VcfDmLatestVersion -Versions $versions
    $age = $null
    if ($published) {
        $parsed = if ($published -is [datetime]) { [datetime]$published } else { [datetime]::MinValue }
        $parsedSuccessfully = $published -is [datetime]
        if (-not $parsedSuccessfully) { $parsedSuccessfully = [datetime]::TryParse([string]$published, [ref]$parsed) }
        if ($parsedSuccessfully) {
            $age = [math]::Max(0, [math]::Floor(([datetime]::UtcNow - $parsed.ToUniversalTime()).TotalDays))
        }
    }
    return [pscustomobject][ordered]@{
        ReferenceMetadataSourceType          = $SourceType
        ReferenceMetadataFileName            = $FileName
        ReferenceMetadataArchiveSha256       = $ArchiveSha256
        ReferenceMetadataCreationUTC         = $creation
        ReferenceMetadataPublishedUTC        = $published
        ReferenceMetadataAgeDays             = $age
        ReferenceProductCatalogVersion       = if ($catalog) { Get-VcfDmNestedValue -Object $catalog -Paths @('version', 'catalogVersion') } else { $null }
        ReferenceProductCatalogSequence      = if ($catalog) { Get-VcfDmNestedValue -Object $catalog -Paths @('sequenceNumber', 'sequence') } else { $null }
        ReferenceMetadataLatestKnownVersion  = $latest
        ReferenceSignaturePresent            = [bool]$Presence.Signature
        ReferenceSignatureValidationStatus   = if ($Presence.Signature) { 'NOT_VERIFIED' } else { 'NOT_PRESENT' }
        ProductCatalogPresent                = [bool]$Presence.ProductCatalog
        VcfManifestPresent                   = [bool]$Presence.Manifest
        CompatibilityMetadataPresent         = [bool]$Presence.Compatibility
        VsanHclMetadataPresent               = [bool]$Presence.VsanHcl
        VsanHclTimestampPresent              = [bool]$Presence.VsanHclTime
        Releases                             = @($versions)
        ProductCatalogRows                   = @(ConvertTo-VcfDmCatalogRows -ProductCatalog $catalog -CatalogSource $SourceType -CollectionStatus 'SUCCESS')
        BroadcomCurrentLatestStatus           = 'UNKNOWN'
    }
}

function Read-VcfDmMetadataZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [int] $MaxEntries = 10000,
        [long] $MaxEntryBytes = 52428800,
        [long] $MaxTotalBytes = 268435456,
        [double] $MaxCompressionRatio = 200
    )

    $archiveHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Read, $false)
        try {
            if ($archive.Entries.Count -gt $MaxEntries) { throw [System.IO.InvalidDataException]::new('Archive entry count exceeds the configured safety limit.') }
            $totalBytes = 0L
            $entryMatches = @{}
            foreach ($entry in $archive.Entries) {
                if (-not (Test-VcfDmArchiveEntryName -Name $entry.FullName)) {
                    throw [System.IO.InvalidDataException]::new('Archive contains an unsafe absolute or traversal entry path.')
                }
                $totalBytes += $entry.Length
                if ($entry.Length -gt $MaxEntryBytes -or $totalBytes -gt $MaxTotalBytes) {
                    throw [System.IO.InvalidDataException]::new('Archive expanded size exceeds the configured safety limit.')
                }
                if ($entry.CompressedLength -eq 0 -and $entry.Length -gt 0) {
                    throw [System.IO.InvalidDataException]::new('Archive entry has an invalid compression size.')
                }
                if ($entry.CompressedLength -gt 0 -and ($entry.Length / $entry.CompressedLength) -gt $MaxCompressionRatio) {
                    throw [System.IO.InvalidDataException]::new('Archive compression ratio exceeds the configured safety limit.')
                }
                $kind = Get-VcfDmMetadataKindForPath -RelativePath $entry.FullName
                if ($kind) {
                    if ($entryMatches.ContainsKey($kind)) {
                        throw [System.IO.InvalidDataException]::new("Archive contains duplicate critical metadata for $kind.")
                    }
                    $entryMatches[$kind] = $entry
                }
            }
            foreach ($required in $script:CriticalSuffixes.Keys) {
                if (-not $entryMatches.ContainsKey($required)) {
                    throw [System.IO.InvalidDataException]::new("Required $required metadata was not found in the archive.")
                }
            }
            $documents = [ordered]@{}
            $presence = @{}
            foreach ($kind in @($script:CriticalSuffixes.Keys) + @($script:OptionalSuffixes.Keys)) {
                $presence[$kind] = $entryMatches.ContainsKey($kind)
                if (-not $entryMatches.ContainsKey($kind) -or $kind -eq 'Signature') { continue }
                $reader = [System.IO.StreamReader]::new($entryMatches[$kind].Open(), [System.Text.UTF8Encoding]::new($false, $true), $true)
                try { $json = $reader.ReadToEnd() } finally { $reader.Dispose() }
                $documents[$kind] = ConvertFrom-VcfDmMetadataJson -Json $json -LogicalName $kind
            }
            return New-VcfDmMetadataResult -SourceType 'BROADCOM_OFFLINE_METADATA_ZIP' -FileName ([System.IO.Path]::GetFileName($Path)) -ArchiveSha256 $archiveHash -Documents $documents -Presence $presence
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Read-VcfDmMetadataDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [long] $MaxEntryBytes = 52428800,
        [long] $MaxTotalBytes = 268435456
    )

    $root = (Resolve-Path -LiteralPath $Path).Path
    $files = @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction Stop)
    $metadataTotal = 0L
    $entryMatches = @{}
    foreach ($file in $files) {
        $relative = [System.IO.Path]::GetRelativePath($root, $file.FullName)
        if (-not (Test-VcfDmArchiveEntryName -Name $relative)) { throw [System.IO.InvalidDataException]::new('Metadata directory contains an unsafe path.') }
        $kind = Get-VcfDmMetadataKindForPath -RelativePath $relative
        if ($kind) {
            if ($file.Length -gt $MaxEntryBytes) { throw [System.IO.InvalidDataException]::new('Metadata file size exceeds the configured safety limit.') }
            if ($entryMatches.ContainsKey($kind)) {
                if ($script:CriticalSuffixes.Contains($kind)) { throw [System.IO.InvalidDataException]::new("Metadata directory contains duplicate critical metadata for $kind.") }
                $existing = $entryMatches[$kind]
                $existingHash = (Get-FileHash -LiteralPath $existing.FullName -Algorithm SHA256).Hash
                $candidateHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
                if ($existingHash -ne $candidateHash) { throw [System.IO.InvalidDataException]::new("Metadata directory contains conflicting optional metadata for $kind.") }
                continue
            }
            $metadataTotal += $file.Length
            if ($metadataTotal -gt $MaxTotalBytes) { throw [System.IO.InvalidDataException]::new('Metadata directory size exceeds the configured safety limit.') }
            $entryMatches[$kind] = $file
        }
    }
    foreach ($required in $script:CriticalSuffixes.Keys) {
        if (-not $entryMatches.ContainsKey($required)) { throw [System.IO.InvalidDataException]::new("Required $required metadata was not found in the directory.") }
    }
    $documents = [ordered]@{}
    $presence = @{}
    foreach ($kind in @($script:CriticalSuffixes.Keys) + @($script:OptionalSuffixes.Keys)) {
        $presence[$kind] = $entryMatches.ContainsKey($kind)
        if (-not $entryMatches.ContainsKey($kind) -or $kind -eq 'Signature') { continue }
        $json = [System.IO.File]::ReadAllText($entryMatches[$kind].FullName, [System.Text.UTF8Encoding]::new($false, $true))
        $documents[$kind] = ConvertFrom-VcfDmMetadataJson -Json $json -LogicalName $kind
    }
    $normalizedRoot = $root.Replace('\', '/').ToLowerInvariant()
    $sourceType = if ($normalizedRoot -match '(vcfdownload|vcf-download|obtu|umds)') { 'VCFDT_METADATA' } else { 'EXTRACTED_OFFLINE_DEPOT' }
    return New-VcfDmMetadataResult -SourceType $sourceType -FileName (Split-Path -Leaf $root) -Documents $documents -Presence $presence
}

function Read-VcfDmOfflineMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Path,
        [int] $MaxEntries = 10000,
        [long] $MaxEntryBytes = 52428800,
        [long] $MaxTotalBytes = 268435456,
        [double] $MaxCompressionRatio = 200
    )

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer) {
        return Read-VcfDmMetadataDirectory -Path $item.FullName -MaxEntryBytes $MaxEntryBytes -MaxTotalBytes $MaxTotalBytes
    }
    if ($item.Extension -ine '.zip') { throw [System.IO.InvalidDataException]::new('LifecycleMetadataPath must be a ZIP archive or supported metadata directory.') }
    return Read-VcfDmMetadataZip -Path $item.FullName -MaxEntries $MaxEntries -MaxEntryBytes $MaxEntryBytes -MaxTotalBytes $MaxTotalBytes -MaxCompressionRatio $MaxCompressionRatio
}

Export-ModuleMember -Function @(
    'Test-VcfDmArchiveEntryName',
    'Read-VcfDmOfflineMetadata',
    'ConvertTo-VcfDmCatalogRows',
    'Get-VcfDmLatestVersion'
)
