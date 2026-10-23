#Requires -Version 5.1
<#
.SYNOPSIS
    SilentDrop - drop an MSI in, get a silent install out.

.DESCRIPTION
    Small GUI tool I made for packaging work. Drag an .msi onto the window and it:
      - reads ProductName / Version / ProductCode straight from the MSI database
      - builds the silent install and uninstall commands for you
      - runs them with a verbose log in C:\Temp named <App>_<Version>_<Action>_<date>.log
      - shows the msiexec log live while it runs
      - can export Install.cmd / Uninstall.cmd (handy for Intune Win32 apps)
      - can wrap the whole thing into a .intunewin file using Microsoft's
        IntuneWinAppUtil.exe

.PARAMETER MsiPath
    Optional. Opens the app with this MSI already loaded
    (this is what happens when you drop an MSI onto SilentDrop.cmd).

.NOTES
    Author  : Vinay Kumar Kamtam
    GitHub  : https://github.com/Vinay-LazyButSecure
    LinkedIn: https://www.linkedin.com/in/kamtamvinaykumar/
    Version: 1.3.0
    Tested : Windows PowerShell 5.1 on Windows 10 / 11
#>
param(
    [string]$MsiPath
)

$AppVersion = '1.3.0'

# Who made this. Used in the window, About box, reports and generated scripts.
$script:Author      = 'Vinay Kumar Kamtam'
$script:GitHubUrl   = 'https://github.com/Vinay-LazyButSecure'
$script:RepoUrl     = 'https://github.com/Vinay-LazyButSecure/SilentDrop'
$script:LinkedInUrl = 'https://www.linkedin.com/in/kamtamvinaykumar/'
$script:CreditLine  = "SilentDrop by $script:Author | $script:GitHubUrl | $script:LinkedInUrl"

# ---------------------------------------------------------------------------
# Drag and drop in WinForms only works on an STA thread.
# Windows PowerShell 5.1 is STA by default, but just in case someone runs it
# from somewhere weird, relaunch it properly.
# ---------------------------------------------------------------------------
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $relaunchArgs = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
    if ($MsiPath) { $relaunchArgs += " -MsiPath `"$MsiPath`"" }
    Start-Process powershell.exe -ArgumentList $relaunchArgs
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# The heavier bits live in lib\ so this file stays readable
foreach ($lib in 'Msi.ps1', 'IntuneDetails.ps1') {
    $libPath = Join-Path $PSScriptRoot "lib\$lib"
    if (-not (Test-Path $libPath)) {
        [System.Windows.Forms.MessageBox]::Show("Missing lib\$lib next to SilentDrop.ps1. Re-download the whole folder.", 'SilentDrop', 'OK', 'Error') | Out-Null
        return
    }
    . $libPath
}

# Where everything gets written
$script:LogRoot     = 'C:\Temp'
$script:HistoryFile = Join-Path $script:LogRoot 'SilentDrop_History.log'

# State for the currently loaded MSI / running msiexec
$script:Msi           = $null
$script:Proc          = $null
$script:CurrentAction = $null
$script:CurrentLog    = $null

# Live log tailing
$script:LogReader   = $null
$script:LogLines    = 0
$script:LogPartial  = ''
$script:SawReturn3  = $false

# Test results + install snapshot for the loaded MSI. Saved to disk per
# product/version, so they're still there when you reopen SilentDrop later.
$script:Tests       = $null
$script:Snapshot    = $null
$script:ActionStart = $null

# IntuneWinAppUtil
$script:IntuneTool = Join-Path $PSScriptRoot 'tools\IntuneWinAppUtil.exe'
$script:IntuneUrl  = 'https://raw.githubusercontent.com/microsoft/Microsoft-Win32-Content-Prep-Tool/master/IntuneWinAppUtil.exe'
$script:PackProc   = $null
$script:PackOutDir = $null
$script:PackSrcDir = $null

# Lines worth showing when "Only important lines" is ticked. A verbose MSI log
# is thousands of lines, most of it noise.
$script:ImportantPattern = 'Action start|Return value 3|Error \d+|error|Product:|Installation success|Removal success|completed successfully|reconfiguration success|MainEngineThread is returning|Windows Installer (re)?installed|Windows Installer removed'

# Common msiexec exit codes so I don't have to google them every time
$script:ExitCodes = @{
    0    = 'Success'
    1602 = 'Cancelled by user'
    1603 = 'Fatal error during install (check the log)'
    1605 = 'Product is not installed'
    1618 = 'Another install is already running, try again in a bit'
    1619 = 'Could not open the MSI package'
    1625 = 'Blocked by system policy'
    1638 = 'Another version of this product is already installed'
    1641 = 'Success - a restart was started'
    3010 = 'Success - restart required'
}


# ===========================================================================
#  Helper functions
# ===========================================================================

function Write-Activity {
    param([string]$Message)
    $time = Get-Date -Format 'HH:mm:ss'
    $txtActivity.AppendText("[$time] $Message`r`n")
}

function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-StateDir {
    # One folder per product + version for test results, snapshot and logo
    $name = Get-SafeName $script:Msi.ProductName
    $ver  = Get-SafeName $script:Msi.ProductVersion
    return Join-Path $script:LogRoot "SilentDrop\State\${name}_${ver}"
}

function Save-State {
    if (-not $script:Msi) { return }
    try {
        $dir = Get-StateDir
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        [pscustomobject]@{
            ProductCode = $script:Msi.ProductCode
            Version     = $script:Msi.ProductVersion
            Tests       = $script:Tests
            Snapshot    = $script:Snapshot
        } | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $dir 'state.json') -Encoding UTF8
    }
    catch {
        Write-Activity "Couldn't save test results: $($_.Exception.Message)"
    }
}

function Import-State {
    $script:Tests    = [pscustomobject]@{ Install = $null; Uninstall = $null }
    $script:Snapshot = $null

    $file = Join-Path (Get-StateDir) 'state.json'
    if (-not (Test-Path $file)) { return }

    try {
        $saved = Get-Content -Path $file -Raw | ConvertFrom-Json
        if ($saved.ProductCode -ne $script:Msi.ProductCode) { return }
        if ($saved.Tests)    { $script:Tests    = $saved.Tests }
        if ($saved.Snapshot) { $script:Snapshot = $saved.Snapshot }
        Write-Activity 'Found earlier test results for this MSI and loaded them.'
    }
    catch {
        Write-Activity "Couldn't read saved test results, starting fresh."
    }
}

function Test-ActionPassed {
    param([string]$Action)
    $r = $script:Tests.$Action
    return [bool]($r -and ($r.ExitCode -in 0, 1641, 3010))
}

function Show-About {
    $about = New-Object System.Windows.Forms.Form
    $about.Text            = 'About SilentDrop'
    $about.ClientSize      = New-Object System.Drawing.Size(420, 250)
    $about.StartPosition   = 'CenterParent'
    $about.FormBorderStyle = 'FixedDialog'
    $about.MaximizeBox     = $false
    $about.MinimizeBox     = $false
    $about.Font            = $form.Font

    $title = New-Object System.Windows.Forms.Label
    $title.Text     = "SilentDrop  v$AppVersion"
    $title.Font     = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(20, 18)
    $about.Controls.Add($title)

    $desc = New-Object System.Windows.Forms.Label
    $desc.Text     = "Drop an MSI in, get a silent install, a tested package`nand everything you need for Intune.`n`nBuilt by $script:Author`nEndpoint management | App development | Cybersecurity"
    $desc.AutoSize = $true
    $desc.Location = New-Object System.Drawing.Point(22, 58)
    $about.Controls.Add($desc)

    $y = 150
    foreach ($entry in @(
        @{ Label = 'LinkedIn'; Url = $script:LinkedInUrl }
        @{ Label = 'GitHub';   Url = $script:GitHubUrl }
        @{ Label = 'Project';  Url = $script:RepoUrl }
    )) {
        $l = New-Object System.Windows.Forms.LinkLabel
        $l.Text     = "$($entry.Label):  $($entry.Url)"
        $l.AutoSize = $true
        $l.Location = New-Object System.Drawing.Point(22, $y)
        $l.Tag      = $entry.Url
        $l.Add_LinkClicked({ param($s, $e) Start-Process $s.Tag })
        $about.Controls.Add($l)
        $y += 22
    }

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text         = 'OK'
    $ok.Location     = New-Object System.Drawing.Point(320, 212)
    $ok.Size         = New-Object System.Drawing.Size(80, 28)
    $ok.DialogResult = 'OK'
    $about.Controls.Add($ok)
    $about.AcceptButton = $ok

    [void]$about.ShowDialog($form)
    $about.Dispose()
}

function Get-SafeName {
    # Strip anything that can't go in a file name and swap spaces for _
    param([string]$Text)
    if (-not $Text) { return 'Unknown' }
    $clean = ($Text -replace '[\\/:*?"<>|\x00-\x1F]', '').Trim() -replace '\s+', '_'
    if (-not $clean) { return 'Unknown' }
    return $clean
}

function New-LogPath {
    param([string]$Action)

    if (-not (Test-Path $script:LogRoot)) {
        New-Item -Path $script:LogRoot -ItemType Directory -Force | Out-Null
    }

    $name  = Get-SafeName $script:Msi.ProductName
    $ver   = Get-SafeName $script:Msi.ProductVersion
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    return Join-Path $script:LogRoot "${name}_${ver}_${Action}_${stamp}.log"
}

function Get-MsiArguments {
    param(
        [string]$Action,
        [string]$LogPath
    )
    if ($Action -eq 'Install') {
        return "/i `"$($script:Msi.Path)`" /qn /norestart /l*v `"$LogPath`""
    }
    return "/x $($script:Msi.ProductCode) /qn /norestart /l*v `"$LogPath`""
}

function Test-ProductInstalled {
    param([string]$ProductCode)
    if (-not $ProductCode) { return $false }

    $keys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode"
    )
    foreach ($key in $keys) {
        if (Test-Path $key) { return $true }
    }
    return $false
}

function Write-History {
    param(
        [string]$Action,
        [int]$ExitCode,
        [string]$LogPath
    )
    try {
        $line = '{0} | {1,-9} | {2} | {3} | Exit {4} | {5}' -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Action,
            $script:Msi.ProductName, $script:Msi.ProductVersion, $ExitCode, $LogPath
        Add-Content -Path $script:HistoryFile -Value $line
    }
    catch {
        Write-Activity "Couldn't write to history file: $($_.Exception.Message)"
    }
}

function Read-LiveLog {
    <#
        Tails the msiexec log while it's being written. msiexec keeps the file
        open, so it has to be opened with FileShare ReadWrite or you get
        "file in use". StreamReader picks up the encoding from the BOM.
    #>
    if (-not $script:CurrentLog) { return }

    if (-not $script:LogReader) {
        if (-not (Test-Path $script:CurrentLog)) { return }   # msiexec hasn't created it yet
        try {
            $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $fs = New-Object IO.FileStream($script:CurrentLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
            $script:LogReader = New-Object IO.StreamReader($fs, [Text.Encoding]::Default, $true)
        }
        catch { return }
    }

    $chunk = $script:LogReader.ReadToEnd()
    if (-not $chunk) { return }

    # A chunk can stop halfway through a line, so hold the last bit back
    # until the rest of it shows up.
    $text  = $script:LogPartial + $chunk
    $lines = $text -split "`r?`n"
    $script:LogPartial = $lines[-1]
    # Careful: with one element, 0..-1 in PowerShell means "first AND last",
    # not "nothing". So bail out early when there's no complete line yet.
    if ($lines.Count -lt 2) { return }
    $lines = $lines[0..($lines.Count - 2)] | Where-Object { $_ }
    if (-not $lines) { return }

    if (-not $script:SawReturn3 -and ($lines -match 'Return value 3')) {
        $script:SawReturn3 = $true
        Write-Activity 'Spotted "Return value 3" in the log. Something failed, check the Live log tab.'
    }

    if ($chkImportant.Checked) {
        $lines = $lines | Where-Object { $_ -match $script:ImportantPattern }
    }
    if (-not $lines) { return }

    $txtLive.AppendText((@($lines) -join "`r`n") + "`r`n")
    $script:LogLines += @($lines).Count
    $lblLiveCount.Text = "$($script:LogLines) lines"

    # Verbose logs get big. Don't let the textbox eat all the RAM.
    if ($txtLive.TextLength -gt 400000) {
        $txtLive.Text = $txtLive.Text.Substring($txtLive.TextLength - 200000)
        $txtLive.SelectionStart = $txtLive.TextLength
        $txtLive.ScrollToCaret()
    }
}

function Reset-LiveLog {
    if ($script:LogReader) {
        $script:LogReader.Dispose()
        $script:LogReader = $null
    }
    $script:LogPartial = ''
    $script:SawReturn3 = $false
}

function Get-IntuneTool {
    # Already got it?
    if (Test-Path $script:IntuneTool) { return $script:IntuneTool }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "IntuneWinAppUtil.exe (Microsoft Win32 Content Prep Tool) wasn't found in the tools folder.`n`n" +
        "Yes = download it now from Microsoft's GitHub.`n" +
        "        By downloading it you accept Microsoft's license terms for that tool.`n" +
        "No  = I already have it, let me browse to it.",
        'SilentDrop', 'YesNoCancel', 'Question')

    if ($answer -eq 'Yes') {
        try {
            $form.Cursor = 'WaitCursor'
            New-Item -Path (Split-Path $script:IntuneTool) -ItemType Directory -Force | Out-Null
            # PowerShell 5.1 still defaults to old TLS on some machines
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $script:IntuneUrl -OutFile $script:IntuneTool -UseBasicParsing
            Unblock-File -Path $script:IntuneTool
            Write-Activity "Downloaded IntuneWinAppUtil.exe to $script:IntuneTool"
            return $script:IntuneTool
        }
        catch {
            Write-Activity "Download failed: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show(
                "Couldn't download IntuneWinAppUtil.exe.`n`n$($_.Exception.Message)`n`nYou can grab it yourself from github.com/microsoft/Microsoft-Win32-Content-Prep-Tool and put it in the tools folder.",
                'SilentDrop', 'OK', 'Warning') | Out-Null
            return $null
        }
        finally {
            $form.Cursor = 'Default'
        }
    }

    if ($answer -eq 'No') {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = 'IntuneWinAppUtil.exe|IntuneWinAppUtil.exe'
        $dialog.Title  = 'Where is IntuneWinAppUtil.exe?'
        if ($dialog.ShowDialog() -eq 'OK') {
            $script:IntuneTool = $dialog.FileName
            return $script:IntuneTool
        }
    }

    return $null
}

function New-IntuneWin {
    if (-not $script:Msi) { return }

    # Nudge: package what you've actually tested
    $missing = @()
    if (-not (Test-ActionPassed 'Install'))   { $missing += 'install' }
    if (-not (Test-ActionPassed 'Uninstall')) { $missing += 'uninstall' }
    if ($missing) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "You haven't had a successful $($missing -join ' and ') of this MSI yet.`n`nBest to test both on a VM first (the test install is also what fills in the detection details). Package it anyway?",
            'SilentDrop', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
    }

    $tool = Get-IntuneTool
    if (-not $tool) { return }

    # The .intunewin is built from the exported folder (MSI + Install.cmd + Uninstall.cmd)
    $src = Export-Package -Quiet
    if (-not $src) { return }

    $name = Get-SafeName $script:Msi.ProductName
    $ver  = Get-SafeName $script:Msi.ProductVersion
    $out  = Join-Path $script:LogRoot "SilentDrop\IntuneWin\${name}_${ver}"
    New-Item -Path $out -ItemType Directory -Force | Out-Null

    # Clear out an old build so we don't mistake it for a new one
    $expected = Join-Path $out ([IO.Path]::GetFileNameWithoutExtension($script:Msi.FileName) + '.intunewin')
    if (Test-Path $expected) { Remove-Item $expected -Force }

    $setupFile = Join-Path $src $script:Msi.FileName
    $toolArgs  = "-c `"$src`" -s `"$setupFile`" -o `"$out`" -q"

    Write-Activity "Packaging: IntuneWinAppUtil.exe $toolArgs"
    try {
        $script:PackProc = Start-Process -FilePath $tool -ArgumentList $toolArgs -WindowStyle Hidden -PassThru -ErrorAction Stop
        $null = $script:PackProc.Handle
    }
    catch {
        Write-Activity "Couldn't start IntuneWinAppUtil: $($_.Exception.Message)"
        $script:PackProc = $null
        return
    }

    $script:PackOutDir = $out
    $script:PackSrcDir = $src
    $lblStatus.Text = 'Building .intunewin... big MSIs take a minute.'
    Update-Ui
    $packTimer.Start()
}

function Complete-IntuneWin {
    $packTimer.Stop()

    $code     = $script:PackProc.ExitCode
    $script:PackProc = $null
    $expected = Join-Path $script:PackOutDir ([IO.Path]::GetFileNameWithoutExtension($script:Msi.FileName) + '.intunewin')

    if (-not (Test-Path $expected)) {
        Write-Activity "IntuneWinAppUtil finished (exit $code) but no .intunewin showed up. Try running it by hand to see the error."
        $lblStatus.Text = 'Packaging failed.'
        Update-Ui
        return
    }

    Write-Activity "Created $expected"
    $lblStatus.Text = 'Packaging done.'
    Update-Ui

    Show-IntuneDetails -PackageFile $expected
}

function Show-IntuneDetails {
    <#
        Builds every Intune field from the MSI + saved test results, writes
        IntuneDetails.html / .txt, Detect.ps1 and logo.png to the output
        folder, then opens the details window.
    #>
    param([string]$PackageFile)

    if (-not $script:Msi) { return }

    $name = Get-SafeName $script:Msi.ProductName
    $ver  = Get-SafeName $script:Msi.ProductVersion
    $out  = Join-Path $script:LogRoot "SilentDrop\IntuneWin\${name}_${ver}"

    # If there's already a package from earlier, point at it
    if (-not $PackageFile) {
        $existing = Join-Path $out ([IO.Path]::GetFileNameWithoutExtension($script:Msi.FileName) + '.intunewin')
        if (Test-Path $existing) { $PackageFile = $existing }
    }

    $title = "$($script:Msi.ProductName) $($script:Msi.ProductVersion)"

    try {
        $form.Cursor = 'WaitCursor'
        New-Item -Path $out -ItemType Directory -Force | Out-Null

        $rows = Get-IntuneDetails -Msi $script:Msi -Snapshot $script:Snapshot -Tests $script:Tests `
                                  -PackageFile $PackageFile -ToolVersion $AppVersion

        $txtPath  = Join-Path $out 'IntuneDetails.txt'
        $htmlPath = Join-Path $out 'IntuneDetails.html'
        $logoOut  = ''

        if ($script:Snapshot -and $script:Snapshot.LogoPath -and (Test-Path $script:Snapshot.LogoPath)) {
            $logoOut = Join-Path $out 'logo.png'
            Copy-Item -Path $script:Snapshot.LogoPath -Destination $logoOut -Force
        }

        [void](Export-IntuneDetailsTxt -Rows $rows -Path $txtPath -Title $title)
        Export-IntuneDetailsHtml -Rows $rows -Path $htmlPath -Title $title -LogoPath $logoOut
        Set-Content -Path (Join-Path $out 'Detect.ps1') -Value (New-DetectionScript -Msi $script:Msi -Snapshot $script:Snapshot) -Encoding UTF8

        Write-Activity "Intune details saved to $out (IntuneDetails.html, IntuneDetails.txt, Detect.ps1$(if ($logoOut) { ', logo.png' }))"
    }
    catch {
        Write-Activity "Couldn't build Intune details: $($_.Exception.Message)"
        return
    }
    finally {
        $form.Cursor = 'Default'
    }

    Show-IntuneDetailsWindow -Rows $rows -Title $title -LogoPath $logoOut -Folder $out -HtmlPath $htmlPath -TxtPath $txtPath
}

function Update-Ui {
    $loaded = [bool]$script:Msi
    $busy   = [bool](($script:Proc -and -not $script:Proc.HasExited) -or
                     ($script:PackProc -and -not $script:PackProc.HasExited))

    $btnInstall.Enabled   = $loaded -and -not $busy
    $btnUninstall.Enabled = $loaded -and -not $busy -and [bool]$script:Msi.ProductCode
    $btnExport.Enabled    = $loaded -and -not $busy
    $btnIntune.Enabled    = $loaded -and -not $busy
    $btnDetails.Enabled   = $loaded -and -not $busy
    $btnCopyInstall.Enabled   = $loaded
    $btnCopyUninstall.Enabled = $loaded
    $btnBrowse.Enabled    = -not $busy
    $progress.Visible     = $busy

    if (-not $loaded) {
        $txtInfo.Text      = 'Nothing loaded yet.'
        $txtInstall.Text   = ''
        $txtUninstall.Text = ''
        return
    }

    $installed = if (Test-ProductInstalled $script:Msi.ProductCode) { 'Yes' } else { 'No' }

    $testLine = @(
        foreach ($a in 'Install', 'Uninstall') {
            $r = $script:Tests.$a
            if (-not $r) { "$a not tested" }
            elseif (Test-ActionPassed $a) { "$a OK" }
            else { "$a FAILED ($($r.ExitCode))" }
        }
    ) -join ', '

    $txtInfo.Text = @(
        "Product       : $($script:Msi.ProductName)   [$($script:Msi.Architecture)]"
        "Version       : $($script:Msi.ProductVersion)"
        "Manufacturer  : $($script:Msi.Manufacturer)"
        "ProductCode   : $($script:Msi.ProductCode)"
        "UpgradeCode   : $($script:Msi.UpgradeCode)"
        "Installed now : $installed"
        "Tested        : $testLine"
    ) -join "`r`n"

    # Preview commands. The timestamp in the log name is refreshed when you
    # actually click Install/Uninstall, so every run gets its own log.
    $txtInstall.Text   = 'msiexec.exe ' + (Get-MsiArguments -Action 'Install'   -LogPath (New-LogPath 'Install'))
    $txtUninstall.Text = 'msiexec.exe ' + (Get-MsiArguments -Action 'Uninstall' -LogPath (New-LogPath 'Uninstall'))
}

function Import-Msi {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Activity "File not found: $Path"
        return
    }
    if ([IO.Path]::GetExtension($Path) -ne '.msi') {
        Write-Activity "That's not an MSI: $([IO.Path]::GetFileName($Path))"
        return
    }

    try {
        $form.Cursor = 'WaitCursor'
        $script:Msi = Read-MsiDatabase -Path $Path
    }
    catch {
        Write-Activity "Couldn't read $([IO.Path]::GetFileName($Path)): $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "I couldn't read that MSI.`n`n$($_.Exception.Message)",
            'SilentDrop', 'OK', 'Warning') | Out-Null
        return
    }
    finally {
        $form.Cursor = 'Default'
    }

    # Pick up test results from an earlier session, if there are any
    Import-State

    $lblDrop.Text = "Loaded: $($script:Msi.FileName)`r`n(drop another MSI to swap)"
    Write-Activity "Loaded $($script:Msi.ProductName) $($script:Msi.ProductVersion)"
    Update-Ui
}

function Start-MsiAction {
    param([ValidateSet('Install', 'Uninstall')][string]$Action)

    if (-not $script:Msi) { return }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "$Action $($script:Msi.ProductName) $($script:Msi.ProductVersion) silently?",
        'SilentDrop', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }

    $log     = New-LogPath $Action
    $msiArgs = Get-MsiArguments -Action $Action -LogPath $log

    Write-Activity "$Action started: msiexec.exe $msiArgs"

    try {
        # RunAs pops the UAC prompt just for msiexec. The GUI itself stays
        # non-elevated on purpose (see README - drag and drop breaks otherwise).
        $script:Proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Verb RunAs -PassThru -ErrorAction Stop

        # Known PowerShell quirk: if you don't touch .Handle now, ExitCode
        # can come back empty later when you use -PassThru without -Wait.
        $null = $script:Proc.Handle
    }
    catch {
        Write-Activity "$Action didn't start (UAC prompt was cancelled?)"
        $script:Proc = $null
        Update-Ui
        return
    }

    $script:CurrentAction = $Action
    $script:CurrentLog    = $log
    $script:ActionStart   = Get-Date
    $lblStatus.Text       = "$Action running... watch the Live log tab."

    # Fresh live log for this run
    Reset-LiveLog
    $script:LogLines   = 0
    $txtLive.Clear()
    $txtLive.AppendText("=== $Action $($script:Msi.ProductName) $($script:Msi.ProductVersion) ===`r`n")
    $txtLive.AppendText("=== $log ===`r`n")
    $tabs.SelectedTab = $tabLive

    Update-Ui
    $timer.Start()
}

function Complete-MsiAction {
    $timer.Stop()

    # Grab whatever got written in the last second, then let go of the file
    Read-LiveLog
    if ($script:LogPartial -and (-not $chkImportant.Checked -or $script:LogPartial -match $script:ImportantPattern)) {
        $txtLive.AppendText($script:LogPartial + "`r`n")
    }
    Reset-LiveLog

    $code = $script:Proc.ExitCode
    if ($null -eq $code) { $code = -1 }

    $passed   = $code -in 0, 1641, 3010
    $duration = [int]((Get-Date) - $script:ActionStart).TotalSeconds

    $result = [pscustomobject]@{
        ExitCode    = $code
        DurationSec = $duration
        When        = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Computer    = $env:COMPUTERNAME
        Log         = $script:CurrentLog
        Leftovers   = ''
    }

    if ($passed -and $script:CurrentAction -eq 'Install') {
        # The app is on the machine right now, so this is the moment to see
        # what it actually installed (for detection rules etc.)
        Write-Activity 'Taking a snapshot of what got installed (files, registry, exe versions)...'
        $form.Cursor = 'WaitCursor'
        try {
            $script:Snapshot = Get-InstallSnapshot -Msi $script:Msi -SaveDir (Get-StateDir)
            $s = $script:Snapshot
            Write-Activity "  Install location: $($s.InstallLocation)"
            if ($s.MainExe) { Write-Activity "  Main exe: $($s.MainExe.Path) (v$($s.MainExe.FileVersion))" }
            if ($s.Uninstall) { Write-Activity "  ARP key: $($s.Uninstall.ActualPath)" }
            Write-Activity "  $($s.FileCount) key files, $(@($s.RegistryKeys).Count) registry key paths"
        }
        catch {
            Write-Activity "Snapshot failed: $($_.Exception.Message)"
        }
        finally {
            $form.Cursor = 'Default'
        }
    }

    if ($passed -and $script:CurrentAction -eq 'Uninstall') {
        # Did it actually clean up?
        $left = @()
        if (Test-ProductInstalled $script:Msi.ProductCode) { $left += 'ARP entry still there' }
        if ($script:Snapshot -and $script:Snapshot.InstallLocation -and (Test-Path $script:Snapshot.InstallLocation)) {
            $left += "folder still exists: $($script:Snapshot.InstallLocation)"
        }
        $result.Leftovers = $left -join '; '
        if ($left) { Write-Activity "Leftovers after uninstall: $($result.Leftovers)" }
        else       { Write-Activity 'Uninstall looks clean: no ARP entry, no install folder.' }
    }

    $script:Tests.($script:CurrentAction) = $result
    Save-State

    $meaning = $script:ExitCodes[[int]$code]
    if (-not $meaning) { $meaning = 'Unknown exit code - open the log and search for "return value 3"' }

    Write-Activity "$($script:CurrentAction) finished with exit code $code ($meaning)"
    Write-Activity "Log: $($script:CurrentLog)"
    Write-History -Action $script:CurrentAction -ExitCode $code -LogPath $script:CurrentLog

    $lblStatus.Text = "Last run: $($script:CurrentAction) -> $code ($meaning)"

    $icon = if ($code -in 0, 1641, 3010) { 'Information' } else { 'Warning' }
    [System.Windows.Forms.MessageBox]::Show(
        "$($script:CurrentAction) finished.`n`nExit code: $code`n$meaning`n`nLog:`n$($script:CurrentLog)",
        'SilentDrop', 'OK', $icon) | Out-Null

    $script:Proc = $null
    Update-Ui
}

function Export-Package {
    <#
        Creates a ready-to-use folder:
          C:\Temp\SilentDrop\Packages\<App>_<Version>\
              <the msi>
              Install.cmd
              Uninstall.cmd
        Point an Intune Win32 app (IntuneWinAppUtil) at that folder and you're
        most of the way there. -Quiet skips opening Explorer and just returns
        the folder path (used by the .intunewin button).
    #>
    param([switch]$Quiet)

    if (-not $script:Msi) { return $null }

    $name   = Get-SafeName $script:Msi.ProductName
    $ver    = Get-SafeName $script:Msi.ProductVersion
    $folder = Join-Path $script:LogRoot "SilentDrop\Packages\${name}_${ver}"

    try {
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
        Copy-Item -Path $script:Msi.Path -Destination $folder -Force

        $today = Get-Date -Format 'yyyy-MM-dd'
        $file  = $script:Msi.FileName
        $code  = $script:Msi.ProductCode

        # cmd's %DATE% depends on regional settings, so grab a clean
        # timestamp from PowerShell instead.
        $stampLine = 'for /f %%i in (''powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"'') do set STAMP=%%i'

        $installCmd = @"
@echo off
:: $($script:Msi.ProductName) $($script:Msi.ProductVersion)
:: Silent install - generated by SilentDrop on $today
:: $($script:CreditLine)

if not exist "C:\Temp" mkdir "C:\Temp"
$stampLine

msiexec.exe /i "%~dp0$file" /qn /norestart /l*v "C:\Temp\${name}_${ver}_Install_%STAMP%.log"
exit /b %ERRORLEVEL%
"@

        $uninstallCmd = @"
@echo off
:: $($script:Msi.ProductName) $($script:Msi.ProductVersion)
:: Silent uninstall - generated by SilentDrop on $today
:: $($script:CreditLine)

if not exist "C:\Temp" mkdir "C:\Temp"
$stampLine

msiexec.exe /x $code /qn /norestart /l*v "C:\Temp\${name}_${ver}_Uninstall_%STAMP%.log"
exit /b %ERRORLEVEL%
"@

        # Default = ANSI. UTF-8 with BOM breaks the first line of a .cmd file.
        Set-Content -Path (Join-Path $folder 'Install.cmd')   -Value $installCmd   -Encoding Default
        Set-Content -Path (Join-Path $folder 'Uninstall.cmd') -Value $uninstallCmd -Encoding Default

        Write-Activity "Exported package to $folder"
        if (-not $Quiet) { Start-Process explorer.exe -ArgumentList "`"$folder`"" }
        return $folder
    }
    catch {
        Write-Activity "Export failed: $($_.Exception.Message)"
        return $null
    }
}


# ===========================================================================
#  The window
# ===========================================================================

$form = New-Object System.Windows.Forms.Form
$form.Text            = "SilentDrop  v$AppVersion  -  by $script:Author"
$form.ClientSize      = New-Object System.Drawing.Size(700, 790)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
$form.AllowDrop       = $true

$mono = New-Object System.Drawing.Font('Consolas', 9)

# --- Drop zone -------------------------------------------------------------
$lblDrop = New-Object System.Windows.Forms.Label
$lblDrop.Text        = "Drop an .msi file here`r`n(or use Browse)"
$lblDrop.TextAlign   = 'MiddleCenter'
$lblDrop.BorderStyle = 'FixedSingle'
$lblDrop.BackColor   = [System.Drawing.Color]::FromArgb(240, 246, 252)
$lblDrop.Font        = New-Object System.Drawing.Font('Segoe UI', 11)
$lblDrop.Location    = New-Object System.Drawing.Point(20, 15)
$lblDrop.Size        = New-Object System.Drawing.Size(560, 75)
$lblDrop.AllowDrop   = $true
$form.Controls.Add($lblDrop)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text     = 'Browse...'
$btnBrowse.Location = New-Object System.Drawing.Point(590, 15)
$btnBrowse.Size     = New-Object System.Drawing.Size(90, 75)
$form.Controls.Add($btnBrowse)

# --- Package details -------------------------------------------------------
$grpInfo = New-Object System.Windows.Forms.GroupBox
$grpInfo.Text     = 'Package details'
$grpInfo.Location = New-Object System.Drawing.Point(20, 100)
$grpInfo.Size     = New-Object System.Drawing.Size(660, 140)
$form.Controls.Add($grpInfo)

$txtInfo = New-Object System.Windows.Forms.TextBox
$txtInfo.Multiline   = $true
$txtInfo.ReadOnly    = $true
$txtInfo.BorderStyle = 'None'
$txtInfo.BackColor   = $form.BackColor
$txtInfo.Font        = $mono
$txtInfo.Location    = New-Object System.Drawing.Point(12, 22)
$txtInfo.Size        = New-Object System.Drawing.Size(636, 110)
$grpInfo.Controls.Add($txtInfo)

# --- Commands --------------------------------------------------------------
$lblInstall = New-Object System.Windows.Forms.Label
$lblInstall.Text     = 'Silent install command'
$lblInstall.Location = New-Object System.Drawing.Point(20, 250)
$lblInstall.AutoSize = $true
$form.Controls.Add($lblInstall)

$txtInstall = New-Object System.Windows.Forms.TextBox
$txtInstall.ReadOnly = $true
$txtInstall.Font     = $mono
$txtInstall.Location = New-Object System.Drawing.Point(20, 270)
$txtInstall.Size     = New-Object System.Drawing.Size(570, 23)
$form.Controls.Add($txtInstall)

$btnCopyInstall = New-Object System.Windows.Forms.Button
$btnCopyInstall.Text     = 'Copy'
$btnCopyInstall.Location = New-Object System.Drawing.Point(600, 269)
$btnCopyInstall.Size     = New-Object System.Drawing.Size(80, 25)
$form.Controls.Add($btnCopyInstall)

$lblUninstall = New-Object System.Windows.Forms.Label
$lblUninstall.Text     = 'Silent uninstall command'
$lblUninstall.Location = New-Object System.Drawing.Point(20, 305)
$lblUninstall.AutoSize = $true
$form.Controls.Add($lblUninstall)

$txtUninstall = New-Object System.Windows.Forms.TextBox
$txtUninstall.ReadOnly = $true
$txtUninstall.Font     = $mono
$txtUninstall.Location = New-Object System.Drawing.Point(20, 325)
$txtUninstall.Size     = New-Object System.Drawing.Size(570, 23)
$form.Controls.Add($txtUninstall)

$btnCopyUninstall = New-Object System.Windows.Forms.Button
$btnCopyUninstall.Text     = 'Copy'
$btnCopyUninstall.Location = New-Object System.Drawing.Point(600, 324)
$btnCopyUninstall.Size     = New-Object System.Drawing.Size(80, 25)
$form.Controls.Add($btnCopyUninstall)

# --- Action buttons --------------------------------------------------------
# Six buttons, 103px wide with 8px gaps, from x=20 to x=680
$buttonSpecs = @(
    @{ Var = 'btnInstall';   Text = 'Install' }
    @{ Var = 'btnUninstall'; Text = 'Uninstall' }
    @{ Var = 'btnExport';    Text = 'Export .cmd' }
    @{ Var = 'btnIntune';    Text = 'Make .intunewin' }
    @{ Var = 'btnDetails';   Text = 'Intune details' }
    @{ Var = 'btnLogs';      Text = 'Open C:\Temp' }
)
$x = 20
foreach ($spec in $buttonSpecs) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text     = $spec.Text
    $b.Location = New-Object System.Drawing.Point($x, 365)
    $b.Size     = New-Object System.Drawing.Size(103, 35)
    $form.Controls.Add($b)
    Set-Variable -Name $spec.Var -Value $b -Scope Script
    $x += 111
}

$tips = New-Object System.Windows.Forms.ToolTip
$tips.SetToolTip($btnExport, 'Copies the MSI + Install.cmd + Uninstall.cmd into a package folder')
$tips.SetToolTip($btnIntune, 'Wraps the package folder into a .intunewin for an Intune Win32 app')
$tips.SetToolTip($btnDetails, 'Every field you need in Intune: app info, program, requirements, detection rules...')

# --- Status + activity -----------------------------------------------------
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Style    = 'Marquee'
$progress.Location = New-Object System.Drawing.Point(20, 412)
$progress.Size     = New-Object System.Drawing.Size(660, 12)
$progress.Visible  = $false
$form.Controls.Add($progress)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text     = 'Ready.'
$lblStatus.Location = New-Object System.Drawing.Point(20, 430)
$lblStatus.Size     = New-Object System.Drawing.Size(660, 20)
$form.Controls.Add($lblStatus)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(20, 455)
$tabs.Size     = New-Object System.Drawing.Size(660, 290)
$form.Controls.Add($tabs)

# Tab 1: what SilentDrop itself is doing
$tabActivity = New-Object System.Windows.Forms.TabPage
$tabActivity.Text = 'Activity'
$tabs.TabPages.Add($tabActivity)

$txtActivity = New-Object System.Windows.Forms.TextBox
$txtActivity.Multiline  = $true
$txtActivity.ReadOnly   = $true
$txtActivity.ScrollBars = 'Vertical'
$txtActivity.Font       = $mono
$txtActivity.Dock       = 'Fill'
$tabActivity.Controls.Add($txtActivity)

# Tab 2: the msiexec log as it's being written
$tabLive = New-Object System.Windows.Forms.TabPage
$tabLive.Text = 'Live log'
$tabs.TabPages.Add($tabLive)

$pnlLiveTop = New-Object System.Windows.Forms.Panel
$pnlLiveTop.Dock   = 'Top'
$pnlLiveTop.Height = 30

$chkImportant = New-Object System.Windows.Forms.CheckBox
$chkImportant.Text     = 'Only important lines (actions, errors, result)'
$chkImportant.Checked  = $true
$chkImportant.AutoSize = $true
$chkImportant.Location = New-Object System.Drawing.Point(6, 6)
$pnlLiveTop.Controls.Add($chkImportant)

$lblLiveCount = New-Object System.Windows.Forms.Label
$lblLiveCount.Text      = ''
$lblLiveCount.AutoSize  = $false
$lblLiveCount.TextAlign = 'MiddleRight'
$lblLiveCount.Location  = New-Object System.Drawing.Point(380, 4)
$lblLiveCount.Size      = New-Object System.Drawing.Size(170, 22)
$pnlLiveTop.Controls.Add($lblLiveCount)

$btnClearLive = New-Object System.Windows.Forms.Button
$btnClearLive.Text     = 'Clear'
$btnClearLive.Location = New-Object System.Drawing.Point(560, 3)
$btnClearLive.Size     = New-Object System.Drawing.Size(80, 24)
$pnlLiveTop.Controls.Add($btnClearLive)

$txtLive = New-Object System.Windows.Forms.TextBox
$txtLive.Multiline  = $true
$txtLive.ReadOnly   = $true
$txtLive.WordWrap   = $false
$txtLive.ScrollBars = 'Both'
$txtLive.Font       = $mono
$txtLive.BackColor  = [System.Drawing.Color]::FromArgb(30, 30, 30)
$txtLive.ForeColor  = [System.Drawing.Color]::FromArgb(220, 220, 220)
$txtLive.Dock       = 'Fill'

$tabLive.Controls.Add($txtLive)
$tabLive.Controls.Add($pnlLiveTop)
# Fill has to be in front of the docked panel or it slides underneath it
$txtLive.BringToFront()

# --- Footer: credits ------------------------------------------------------
$pnlFooter = New-Object System.Windows.Forms.Panel
$pnlFooter.Location  = New-Object System.Drawing.Point(0, 755)
$pnlFooter.Size      = New-Object System.Drawing.Size(700, 35)
$pnlFooter.BackColor = [System.Drawing.Color]::FromArgb(246, 248, 250)
$form.Controls.Add($pnlFooter)

$lblMadeBy = New-Object System.Windows.Forms.Label
$lblMadeBy.Text      = "Made by $script:Author"
$lblMadeBy.AutoSize  = $true
$lblMadeBy.ForeColor = [System.Drawing.Color]::DimGray
$lblMadeBy.Location  = New-Object System.Drawing.Point(20, 10)
$pnlFooter.Controls.Add($lblMadeBy)

function New-FooterLink {
    param([string]$Text, [int]$X, [string]$Url, [string]$Tip)
    $link = New-Object System.Windows.Forms.LinkLabel
    $link.Text     = $Text
    $link.AutoSize = $true
    $link.Location = New-Object System.Drawing.Point($X, 10)
    $link.Tag      = $Url
    $link.Add_LinkClicked({ param($s, $e) Start-Process $s.Tag })
    $tips.SetToolTip($link, $Tip)
    $pnlFooter.Controls.Add($link)
    return $link
}

$lnkLinkedIn = New-FooterLink -Text 'LinkedIn' -X 470 -Url $script:LinkedInUrl -Tip "Connect with me on LinkedIn`n$script:LinkedInUrl"
$lnkGitHub   = New-FooterLink -Text 'GitHub'   -X 540 -Url $script:GitHubUrl   -Tip "More of my projects`n$script:GitHubUrl"

$lnkAbout = New-Object System.Windows.Forms.LinkLabel
$lnkAbout.Text     = 'About'
$lnkAbout.AutoSize = $true
$lnkAbout.Location = New-Object System.Drawing.Point(610, 10)
$lnkAbout.Add_LinkClicked({ Show-About })
$pnlFooter.Controls.Add($lnkAbout)

# --- Timers so nothing freezes the window ---------------------------------
# msiexec: twice a second so the live log feels live
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500

# IntuneWinAppUtil
$packTimer = New-Object System.Windows.Forms.Timer
$packTimer.Interval = 1000


# ===========================================================================
#  Events
# ===========================================================================

$onDragEnter = {
    param($sender, $e)
    $e.Effect = 'None'
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $files = $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
        if ($files.Count -ge 1 -and $files[0] -like '*.msi') {
            $e.Effect = 'Copy'
        }
    }
}

$onDragDrop = {
    param($sender, $e)
    $files = $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    if ($files -and $files.Count -ge 1) {
        if (($script:Proc -and -not $script:Proc.HasExited) -or
            ($script:PackProc -and -not $script:PackProc.HasExited)) {
            Write-Activity 'Busy right now, wait for it to finish first.'
            return
        }
        Import-Msi -Path $files[0]
    }
}

# Drop events don't bubble up in WinForms. If you only hook the form, dropping
# on a textbox or the group box does nothing. So hook every control on the window.
function Enable-DropOn {
    param($Control)
    $Control.AllowDrop = $true
    $Control.Add_DragEnter($onDragEnter)
    $Control.Add_DragDrop($onDragDrop)
    foreach ($child in $Control.Controls) { Enable-DropOn $child }
}
Enable-DropOn $form

$btnBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'Windows Installer (*.msi)|*.msi'
    $dialog.Title  = 'Pick an MSI'
    if ($dialog.ShowDialog() -eq 'OK') {
        Import-Msi -Path $dialog.FileName
    }
})

$btnCopyInstall.Add_Click({
    if ($txtInstall.Text) {
        [System.Windows.Forms.Clipboard]::SetText($txtInstall.Text)
        Write-Activity 'Install command copied.'
    }
})

$btnCopyUninstall.Add_Click({
    if ($txtUninstall.Text) {
        [System.Windows.Forms.Clipboard]::SetText($txtUninstall.Text)
        Write-Activity 'Uninstall command copied.'
    }
})

$btnInstall.Add_Click({   Start-MsiAction -Action 'Install' })
$btnUninstall.Add_Click({ Start-MsiAction -Action 'Uninstall' })
$btnExport.Add_Click({    [void](Export-Package) })
$btnIntune.Add_Click({    New-IntuneWin })
$btnDetails.Add_Click({   Show-IntuneDetails })

$btnClearLive.Add_Click({
    $txtLive.Clear()
    $script:LogLines   = 0
    $lblLiveCount.Text = ''
})

$btnLogs.Add_Click({
    if (-not (Test-Path $script:LogRoot)) {
        New-Item -Path $script:LogRoot -ItemType Directory -Force | Out-Null
    }
    Start-Process explorer.exe -ArgumentList "`"$script:LogRoot`""
})

$timer.Add_Tick({
    if (-not $script:Proc) { $timer.Stop(); return }
    Read-LiveLog
    if ($script:Proc.HasExited) {
        Complete-MsiAction
    }
})

$packTimer.Add_Tick({
    if ($script:PackProc -and $script:PackProc.HasExited) {
        Complete-IntuneWin
    }
})

$form.Add_FormClosing({
    param($sender, $e)
    $msiBusy  = $script:Proc -and -not $script:Proc.HasExited
    $packBusy = $script:PackProc -and -not $script:PackProc.HasExited
    if ($msiBusy -or $packBusy) {
        $what = if ($msiBusy) { 'msiexec' } else { 'IntuneWinAppUtil' }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "$what is still running. It will keep going in the background if you close this.`n`nClose anyway?",
            'SilentDrop', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { $e.Cancel = $true; return }
    }
    Reset-LiveLog
})

$form.Add_Shown({
    Write-Activity "SilentDrop $AppVersion by $script:Author ready. Logs go to $script:LogRoot"
    Write-Activity "Like it? Star it on GitHub: $script:RepoUrl"

    if (Test-IsAdmin) {
        # Windows (UIPI) blocks drag and drop from a normal Explorer window
        # into an elevated app. Nothing in WinForms can work around that.
        $lblDrop.Text = "Running as admin, so Windows blocks drag and drop.`r`nUse Browse, or restart SilentDrop without admin."
        $lblDrop.BackColor = [System.Drawing.Color]::FromArgb(255, 244, 229)
        Write-Activity 'Running elevated: drag and drop is blocked by Windows.'

        $launcher = Join-Path $PSScriptRoot 'SilentDrop.cmd'
        if (Test-Path $launcher) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "SilentDrop is running as administrator, and Windows blocks drag and drop into admin windows.`n`nRestart it as a normal user? (You'll still get a UAC prompt when you install.)",
                'SilentDrop', 'YesNo', 'Information')
            if ($answer -eq 'Yes') {
                # Anything started through explorer.exe runs as the normal,
                # non-elevated user. Old trick, still works.
                Start-Process explorer.exe -ArgumentList "`"$launcher`""
                $form.Close()
                return
            }
        }
    }

    if ($MsiPath) { Import-Msi -Path $MsiPath }
})


# ===========================================================================
#  Go
# ===========================================================================
Update-Ui
[void]$form.ShowDialog()
$timer.Dispose()
$form.Dispose()
