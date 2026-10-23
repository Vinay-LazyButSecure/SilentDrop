<#
    Msi.ps1 - part of SilentDrop
    by Vinay Kumar Kamtam | https://github.com/Vinay-LazyButSecure

    Two jobs:
      1. Read-MsiDatabase   : open an .msi read-only and pull out everything
                              useful (properties, components, launch
                              conditions, platform...)
      2. Get-InstallSnapshot: after a test install, look at what the MSI
                              ACTUALLY put on the machine (ARP registry entry,
                              files, registry key paths, main exe, icon)

    Everything goes through the WindowsInstaller.Installer COM object that
    ships with Windows. The COM calls look ugly because PowerShell needs
    InvokeMember for this object, so there are two small wrappers below.
#>

# --- COM plumbing ----------------------------------------------------------

function Invoke-ComMethod {
    param($Object, [string]$Name, [object[]]$Arguments)
    return $Object.GetType().InvokeMember($Name, 'InvokeMethod', $null, $Object, $Arguments)
}

function Get-ComProperty {
    param($Object, [string]$Name, [object[]]$Arguments)
    return $Object.GetType().InvokeMember($Name, 'GetProperty', $null, $Object, $Arguments)
}

function Clear-ComObject {
    param($Object)
    if ($null -ne $Object) {
        try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Object) } catch { }
    }
}

function Get-MsiRows {
    <#
        Runs SELECT <columns> FROM <table> and returns one object per row.
        Optional tables (LaunchCondition, Upgrade, Shortcut...) don't exist in
        every MSI. That throws, and we just return an empty list.
    #>
    param($Database, [string]$Table, [string[]]$Columns)

    $rows = New-Object System.Collections.Generic.List[object]
    $cols = ($Columns | ForEach-Object { "``$_``" }) -join ', '
    $sql  = "SELECT $cols FROM ``$Table``"
    $view = $null

    try {
        $view = Invoke-ComMethod $Database 'OpenView' @($sql)
        [void](Invoke-ComMethod $view 'Execute' $null)

        while ($true) {
            $record = Invoke-ComMethod $view 'Fetch' $null
            if ($null -eq $record) { break }

            $row = [ordered]@{}
            for ($i = 0; $i -lt $Columns.Count; $i++) {
                $row[$Columns[$i]] = Get-ComProperty $record 'StringData' @($i + 1)
            }
            $rows.Add([pscustomobject]$row)
            Clear-ComObject $record
        }
    }
    catch {
        # table not in this MSI, that's fine
    }
    finally {
        if ($view) {
            try { [void](Invoke-ComMethod $view 'Close' $null) } catch { }
            Clear-ComObject $view
        }
    }

    return , $rows
}


# --- 1. Reading the MSI ----------------------------------------------------

function Read-MsiDatabase {
    param([string]$Path)

    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $null
    $si = $null

    try {
        # 0 = read only
        $db = Invoke-ComMethod $installer 'OpenDatabase' @($Path, 0)

        $props = @{}
        foreach ($row in (Get-MsiRows $db 'Property' @('Property', 'Value'))) {
            $props[$row.Property] = $row.Value
        }

        $components = Get-MsiRows $db 'Component'       @('ComponentId', 'KeyPath')
        $launch     = Get-MsiRows $db 'LaunchCondition' @('Condition', 'Description')
        $upgrades   = Get-MsiRows $db 'Upgrade'         @('UpgradeCode', 'Attributes')
        $shortcuts  = Get-MsiRows $db 'Shortcut'        @('Name')

        # Summary info property 7 = "Template", e.g. "x64;1033" or "Intel;1033".
        # This is how you tell a 32-bit MSI from a 64-bit one.
        $template = ''
        try {
            $si = Get-ComProperty $db 'SummaryInformation' @(0)
            $template = [string](Get-ComProperty $si 'Property' @(7))
        }
        catch { }
    }
    finally {
        # Without this the MSI stays locked until the app closes
        Clear-ComObject $si
        Clear-ComObject $db
        Clear-ComObject $installer
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }

    $platform = ($template -split ';')[0]
    $arch = switch -Regex ($platform) {
        '^(x64|Intel64|AMD64)$' { 'x64'; break }
        '^Arm64$'               { 'ARM64'; break }
        '^Intel$'               { 'x86'; break }
        default                 { 'Unknown' }
    }

    # Shortcut names in MSI are "SHORT~1|Long Name", keep the readable part
    $shortcutNames = @($shortcuts | ForEach-Object { ($_.Name -split '\|')[-1] } | Select-Object -Unique)

    return [pscustomobject]@{
        Path             = $Path
        FileName         = [IO.Path]::GetFileName($Path)
        FileSizeBytes    = (Get-Item -LiteralPath $Path).Length
        ProductName      = $props['ProductName']
        ProductVersion   = $props['ProductVersion']
        ProductCode      = $props['ProductCode']
        Manufacturer     = $props['Manufacturer']
        UpgradeCode      = $props['UpgradeCode']
        AllUsers         = $props['ALLUSERS']
        InfoUrl          = $props['ARPURLINFOABOUT']
        HelpUrl          = $props['ARPHELPLINK']
        Comments         = $props['ARPCOMMENTS']
        NoRemove         = $props['ARPNOREMOVE']
        RebootProperty   = $props['REBOOT']
        Architecture     = $arch
        Template         = $template
        Properties       = $props
        Components       = $components
        LaunchConditions = $launch
        HasUpgradeTable  = ($upgrades.Count -gt 0)
        Shortcuts        = $shortcutNames
    }
}


# --- 2. What did the install actually do? ----------------------------------

function ConvertFrom-MsiRegistryKeyPath {
    <#
        MsiGetComponentPath returns registry key paths like
            02:\SOFTWARE\Vendor\App\ValueName
        The number is the root: 00 HKCR, 01 HKCU, 02 HKLM, 03 HKU.
        Add 20 to it and it means the 64-bit view (so 22 = HKLM 64-bit).
    #>
    param([string]$KeyPath)

    if ($KeyPath -notmatch '^(\d\d):\\?(.+)$') { return $null }

    $rootNum = [int]$Matches[1]
    $rest    = $Matches[2]
    $is64    = $rootNum -ge 20
    $hive    = @{ 0 = 'HKEY_CLASSES_ROOT'; 1 = 'HKEY_CURRENT_USER'; 2 = 'HKEY_LOCAL_MACHINE'; 3 = 'HKEY_USERS' }[$rootNum % 20]
    if (-not $hive) { return $null }

    # Trailing \ means the key itself (default value)
    if ($rest.EndsWith('\')) {
        $key   = $rest.TrimEnd('\')
        $value = '(Default)'
    }
    else {
        $idx   = $rest.LastIndexOf('\')
        $key   = if ($idx -gt 0) { $rest.Substring(0, $idx) } else { $rest }
        $value = if ($idx -gt 0) { $rest.Substring($idx + 1) } else { '(Default)' }
    }

    return [pscustomobject]@{
        Key          = "$hive\$key"
        ValueName    = $value
        Is64BitView  = $is64
        # For Intune: a 32-bit registry entry on 64-bit Windows means you tick
        # "Associated with a 32-bit app on 64-bit clients"
        Is32BitOn64  = (-not $is64) -and [Environment]::Is64BitOperatingSystem -and $hive -eq 'HKEY_LOCAL_MACHINE'
    }
}

function Get-CleanFileVersion {
    # VersionInfo.FileVersion is sometimes "1, 2, 3, 4" or "24.08 beta".
    # The numeric parts are always clean.
    param($VersionInfo)
    if (-not $VersionInfo) { return '' }
    $parts = $VersionInfo.FileMajorPart, $VersionInfo.FileMinorPart, $VersionInfo.FileBuildPart, $VersionInfo.FilePrivatePart
    if (($parts | Measure-Object -Sum).Sum -eq 0) { return '' }
    return ($parts -join '.')
}

function Get-InstallSnapshot {
    <#
        Call this right after a successful test install, while the app is
        still on the machine. Returns an object you can save as JSON.
        -SaveDir is where the extracted logo.png goes.
    #>
    param(
        $Msi,
        [string]$SaveDir
    )

    $code = $Msi.ProductCode
    $snap = [ordered]@{
        TakenOn         = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Computer        = $env:COMPUTERNAME
        OsVersion       = [Environment]::OSVersion.Version.ToString()
        Uninstall       = $null
        InstallLocation = ''
        MainExe         = $null
        Files           = @()
        FileCount       = 0
        Folders         = @()
        RegistryKeys    = @()
        LogoPath        = ''
    }

    # --- Add/Remove Programs entry ---
    $arpLocations = @(
        @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$code";             Hive = 'HKEY_LOCAL_MACHINE'; Is32 = $false; Scope = 'System' }
        @{ Path = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$code"; Hive = 'HKEY_LOCAL_MACHINE'; Is32 = $true;  Scope = 'System' }
        @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$code";             Hive = 'HKEY_CURRENT_USER';  Is32 = $false; Scope = 'User' }
    )

    foreach ($loc in $arpLocations) {
        if (-not (Test-Path $loc.Path)) { continue }
        $p = Get-ItemProperty -Path $loc.Path -ErrorAction SilentlyContinue
        $snap.Uninstall = [pscustomobject]@{
            ActualPath      = ($loc.Path -replace '^HKLM:', 'HKEY_LOCAL_MACHINE' -replace '^HKCU:', 'HKEY_CURRENT_USER')
            # Intune wants the native path + the 32-bit tick box, not WOW6432Node
            IntunePath      = "$($loc.Hive)\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$code"
            Is32BitOn64     = $loc.Is32
            Scope           = $loc.Scope
            DisplayName     = $p.DisplayName
            DisplayVersion  = $p.DisplayVersion
            Publisher       = $p.Publisher
            InstallLocation = $p.InstallLocation
            InstallDate     = $p.InstallDate
            EstimatedSizeKB = $p.EstimatedSize
            UninstallString = $p.UninstallString
            URLInfoAbout    = $p.URLInfoAbout
            HelpLink        = $p.HelpLink
        }
        break
    }

    # --- Ask Windows Installer where each component ended up ---
    $files   = New-Object System.Collections.Generic.List[object]
    $regKeys = New-Object System.Collections.Generic.List[object]
    $folders = New-Object System.Collections.Generic.List[string]
    $fileCount = 0

    $installer = New-Object -ComObject WindowsInstaller.Installer
    try {
        $checked = 0
        foreach ($comp in $Msi.Components) {
            if (-not $comp.ComponentId) { continue }   # no GUID = not registered
            if ($checked++ -ge 5000) { break }          # some MSIs are huge

            try { $keyPath = [string](Get-ComProperty $installer 'ComponentPath' @($code, $comp.ComponentId)) }
            catch { continue }
            if (-not $keyPath) { continue }

            if ($keyPath -match '^\d\d:') {
                $reg = ConvertFrom-MsiRegistryKeyPath $keyPath
                # Classes keys are COM/file associations, mostly noise for detection
                if ($reg -and $reg.Key -notmatch '\\Classes\\' -and $reg.Key -notmatch '^HKEY_CLASSES_ROOT') {
                    $regKeys.Add($reg)
                }
                continue
            }

            if (Test-Path -LiteralPath $keyPath -PathType Container) {
                $folders.Add($keyPath.TrimEnd('\'))
                continue
            }

            if (Test-Path -LiteralPath $keyPath -PathType Leaf) {
                $fileCount++
                $item = Get-Item -LiteralPath $keyPath
                $folders.Add($item.DirectoryName)
                if ($item.Extension -eq '.exe') {
                    $vi = $item.VersionInfo
                    $files.Add([pscustomobject]@{
                        Path           = $item.FullName
                        Folder         = $item.DirectoryName
                        Name           = $item.Name
                        FileVersion    = Get-CleanFileVersion $vi
                        ProductVersion = $vi.ProductVersion
                        Description    = $vi.FileDescription
                        SizeKB         = [math]::Round($item.Length / 1KB)
                    })
                }
            }
        }
    }
    finally {
        Clear-ComObject $installer
    }

    $snap.FileCount    = $fileCount
    $snap.Files        = @($files | Sort-Object Path -Unique | Select-Object -First 25)
    $snap.RegistryKeys = @($regKeys | Sort-Object Key, ValueName -Unique | Select-Object -First 15)

    # Most common folders first
    $snap.Folders = @($folders | Group-Object | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object { $_.Name })

    # --- Guess the main exe ---
    # Skip uninstallers/updaters, prefer an exe named like the product, then the biggest one.
    $candidates = @($snap.Files | Where-Object { $_.Name -notmatch '^(unins|uninst|setup|update|updater|crash|report|helper|install|vc_redist)' })
    $word = $Msi.ProductName -split '[\s\-_\.\(\)]+' | Where-Object { $_.Length -ge 3 } | Select-Object -First 1
    $main = $null
    if ($word) { $main = $candidates | Where-Object { $_.Name -like "*$word*" } | Sort-Object SizeKB -Descending | Select-Object -First 1 }
    if (-not $main) { $main = $candidates | Sort-Object SizeKB -Descending | Select-Object -First 1 }
    $snap.MainExe = $main

    # --- Install folder ---
    if ($snap.Uninstall -and $snap.Uninstall.InstallLocation) {
        $snap.InstallLocation = $snap.Uninstall.InstallLocation.TrimEnd('\')
    }
    elseif ($main) {
        $snap.InstallLocation = $main.Folder
    }
    elseif ($snap.Folders.Count) {
        $snap.InstallLocation = $snap.Folders[0]
    }

    # --- Logo for the Company Portal, pulled from the main exe's icon ---
    if ($main -and $SaveDir) {
        try {
            New-Item -Path $SaveDir -ItemType Directory -Force | Out-Null
            $png  = Join-Path $SaveDir 'logo.png'
            $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($main.Path)
            $bmp  = $icon.ToBitmap()
            $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            $icon.Dispose()
            $snap.LogoPath = $png
        }
        catch { }
    }

    return [pscustomobject]$snap
}
