<#
    IntuneDetails.ps1 - part of SilentDrop
    by Vinay Kumar Kamtam | https://github.com/Vinay-LazyButSecure

    Turns what we know about an MSI (+ what the test install did) into every
    field you fill in when you create a Windows app (Win32) in Intune,
    in the same order as the portal:

        App information > Program > Requirements > Detection rules >
        Dependencies > Supersedence > Assignments

    Plus what was found on the test machine and the test results.

    Get-IntuneDetails       -> list of rows (Section / Field / Value / Note)
    New-DetectionScript     -> Detect.ps1 content for a custom detection rule
    Export-IntuneDetailsTxt -> plain text version
    Export-IntuneDetailsHtml-> nice HTML report to keep with the package
    Show-IntuneDetailsWindow-> the window with all of it, click to copy
#>

$script:IntuneSections = @(
    '1. App information'
    '2. Program'
    '3. Requirements'
    '4a. Detection rule - MSI (recommended)'
    '4b. Detection rule - Registry'
    '4c. Detection rule - File'
    '4d. Detection rule - Custom script'
    '5. Dependencies'
    '6. Supersedence'
    '7. Assignments'
    'Found on the test machine'
    'Test results'
)

$script:MsiExitMeaning = @{
    0    = 'Success'
    1602 = 'Cancelled by user'
    1603 = 'Fatal error'
    1605 = 'Not installed'
    1618 = 'Another install running'
    1619 = 'Package could not be opened'
    1625 = 'Blocked by policy'
    1638 = 'Other version installed'
    1641 = 'Success, restart started'
    3010 = 'Success, restart required'
}

function Get-IntuneDetails {
    param(
        $Msi,
        $Snapshot,
        $Tests,
        [string]$PackageFile,
        [string]$ToolVersion
    )

    $rows = New-Object System.Collections.Generic.List[object]
    function Add-Row([string]$Section, [string]$Field, $Value, [string]$Note = '') {
        $text = if ($null -eq $Value) { '' } else { [string]$Value }
        $rows.Add([pscustomobject]@{ Section = $Section; Field = $Field; Value = $text; Note = $Note })
    }

    $s       = $script:IntuneSections
    $noTest  = '(do a test install to fill this in)'
    $arp     = if ($Snapshot) { $Snapshot.Uninstall } else { $null }
    $version = if ($arp -and $arp.DisplayVersion) { $arp.DisplayVersion } else { $Msi.ProductVersion }
    $infoUrl = if ($Msi.InfoUrl) { $Msi.InfoUrl } elseif ($arp -and $arp.URLInfoAbout) { $arp.URLInfoAbout } else { '' }

    $installOk   = $Tests -and $Tests.Install   -and ($Tests.Install.ExitCode   -in 0, 1641, 3010)
    $uninstallOk = $Tests -and $Tests.Uninstall -and ($Tests.Uninstall.ExitCode -in 0, 1641, 3010)

    # ------------------------------------------------------------------ 1
    $description = if ($Msi.Comments) { $Msi.Comments } else { "$($Msi.ProductName) $($Msi.ProductVersion) by $($Msi.Manufacturer)." }

    $notes = "Packaged with SilentDrop $ToolVersion ($script:RepoUrl) on $(Get-Date -Format 'yyyy-MM-dd') by $env:USERNAME."
    if ($installOk)   { $notes += " Install tested OK on $($Tests.Install.Computer) ($($Tests.Install.DurationSec)s)." }
    if ($uninstallOk) { $notes += " Uninstall tested OK." }

    $logo = if ($Snapshot -and $Snapshot.LogoPath) { 'logo.png (in the output folder)' } else { '(none found, add one manually)' }

    Add-Row $s[0] 'Select file (package)'  $(if ($PackageFile) { [IO.Path]::GetFileName($PackageFile) } else { '(click Make .intunewin first)' }) 'The .intunewin to upload'
    Add-Row $s[0] 'Name'                   $Msi.ProductName      'Shown in Company Portal'
    Add-Row $s[0] 'Description'            $description          'Required. Edit to something users understand'
    Add-Row $s[0] 'Publisher'              $Msi.Manufacturer     'Required'
    Add-Row $s[0] 'App version'            $Msi.ProductVersion
    Add-Row $s[0] 'Category'               ''                    'Pick one, e.g. Productivity / Utilities'
    Add-Row $s[0] 'Show as featured app'   'No'
    Add-Row $s[0] 'Information URL'        $infoUrl              $(if ($infoUrl) { 'From the MSI / ARP entry' } else { 'Vendor homepage' })
    Add-Row $s[0] 'Privacy URL'            ''                    'Vendor privacy policy page'
    Add-Row $s[0] 'Developer'              $Msi.Manufacturer
    Add-Row $s[0] 'Owner'                  $env:USERNAME         'Whoever looks after this app'
    Add-Row $s[0] 'Notes'                  $notes
    Add-Row $s[0] 'Logo'                   $logo                 $(if ($Snapshot -and $Snapshot.LogoPath) { 'Extracted from the main exe icon' } else { 'PNG or JPG, square works best' })

    # ------------------------------------------------------------------ 2
    $timeNote = 'Intune default is 60'
    $timeVal  = 60
    if ($Tests -and $Tests.Install -and $Tests.Install.DurationSec) {
        $sec = [int]$Tests.Install.DurationSec
        $timeNote = "Test install took $sec seconds. 60 is the default and plenty"
        if ($sec -gt 1200) { $timeVal = [math]::Ceiling($sec * 2 / 60); $timeNote = "Test install took $sec seconds, so give it double" }
    }

    $behavior = 'System'
    $behaviorNote = 'MSI is per-machine'
    if ($arp -and $arp.Scope -eq 'User') {
        $behavior = 'User'
        $behaviorNote = 'Test install registered under HKCU, so it is per-user'
    }
    elseif (-not $arp -and -not $Msi.AllUsers) {
        $behaviorNote = 'MSI has no ALLUSERS property and may install per-user. If so, add ALLUSERS=1 to the command or pick User'
    }

    $allowUninstall = if ($Msi.NoRemove) { 'No' } else { 'Yes' }

    Add-Row $s[1] 'Install command'                 'Install.cmd' 'Runs msiexec silently and logs to C:\Temp'
    Add-Row $s[1] 'Uninstall command'               'Uninstall.cmd'
    Add-Row $s[1] 'Install command (no .cmd)'       "msiexec /i `"$($Msi.FileName)`" /qn /norestart" 'Alternative, if you prefer no wrapper'
    Add-Row $s[1] 'Uninstall command (no .cmd)'     "msiexec /x $($Msi.ProductCode) /qn /norestart"
    Add-Row $s[1] 'Installation time required (mins)' $timeVal $timeNote
    Add-Row $s[1] 'Allow available uninstall'       $allowUninstall $(if ($Msi.NoRemove) { 'MSI sets ARPNOREMOVE' } else { 'Lets users uninstall from Company Portal' })
    Add-Row $s[1] 'Install behavior'                $behavior $behaviorNote
    Add-Row $s[1] 'Device restart behavior'         'Determine behavior based on return codes' $(if ($Msi.RebootProperty) { "MSI sets REBOOT=$($Msi.RebootProperty)" } else { '' })
    Add-Row $s[1] 'Return code 0'                   'Success'      'Default, already there'
    Add-Row $s[1] 'Return code 1707'                'Success'      'Default, already there'
    Add-Row $s[1] 'Return code 3010'                'Soft reboot'  'Default, already there'
    Add-Row $s[1] 'Return code 1641'                'Hard reboot'  'Default, already there'
    Add-Row $s[1] 'Return code 1618'                'Retry'        'Default, already there'

    # ------------------------------------------------------------------ 3
    $archVal = switch ($Msi.Architecture) {
        'x64'   { 'x64 only' }
        'x86'   { 'x86 and x64' }
        'ARM64' { 'ARM64 only' }
        default { 'Check manually' }
    }
    $archNote = "MSI template: $($Msi.Template)"

    $osNote = 'Nothing in the MSI says otherwise'
    $osConditions = @($Msi.LaunchConditions | Where-Object { $_.Condition -match 'VersionNT|WindowsBuild' })
    if ($osConditions.Count) { $osNote = 'MSI checks: ' + (($osConditions | ForEach-Object { $_.Condition }) -join '; ') }

    $diskVal = ''
    $diskNote = 'Optional'
    if ($arp -and $arp.EstimatedSizeKB) {
        $diskVal  = [math]::Ceiling([double]$arp.EstimatedSizeKB / 1024)
        $diskNote = 'Optional. From EstimatedSize in the ARP entry'
    }

    Add-Row $s[2] 'Operating system architecture' $archVal $archNote
    Add-Row $s[2] 'Minimum operating system'      'Your org baseline (e.g. Windows 10 22H2)' $osNote
    Add-Row $s[2] 'Disk space required (MB)'      $diskVal $diskNote
    Add-Row $s[2] 'Physical memory required (MB)' '' 'Optional, usually blank'
    Add-Row $s[2] 'Minimum number of logical processors' '' 'Optional, usually blank'

    # ------------------------------------------------------------------ 4a
    Add-Row $s[3] 'Rules format'             'Manually configure detection rules'
    Add-Row $s[3] 'Rule type'                'MSI'
    Add-Row $s[3] 'MSI product code'         $Msi.ProductCode 'Intune fills this in itself when the setup file is an MSI'
    Add-Row $s[3] 'MSI product version check' 'Yes'
    Add-Row $s[3] 'Operator'                 'Greater than or equal to'
    Add-Row $s[3] 'Value'                    $Msi.ProductVersion

    # ------------------------------------------------------------------ 4b
    if ($arp) {
        $regPath = $arp.IntunePath
        $reg32   = if ($arp.Is32BitOn64) { 'Yes' } else { 'No' }
        $regNote = "Seen on test machine at $($arp.ActualPath)"
    }
    else {
        $hive    = if ($Msi.AllUsers) { 'HKEY_LOCAL_MACHINE' } else { 'HKEY_LOCAL_MACHINE (or HKEY_CURRENT_USER if per-user)' }
        $regPath = "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($Msi.ProductCode)"
        $reg32   = if ($Msi.Architecture -eq 'x86') { 'Yes' } else { 'No' }
        $regNote = "Predicted from the MSI. $noTest"
    }
    Add-Row $s[4] 'Rule type'        'Registry'
    Add-Row $s[4] 'Key path'         $regPath $regNote
    Add-Row $s[4] 'Value name'       'DisplayVersion'
    Add-Row $s[4] 'Detection method' 'Version comparison'
    Add-Row $s[4] 'Operator'         'Greater than or equal to'
    Add-Row $s[4] 'Value'            $version
    Add-Row $s[4] 'Associated with a 32-bit app on 64-bit clients' $reg32 'Yes means Intune looks in WOW6432Node'

    # ------------------------------------------------------------------ 4c
    $main = if ($Snapshot) { $Snapshot.MainExe } else { $null }
    if ($main) {
        $file32 = if ($main.Folder -like '*Program Files (x86)*') { 'Yes' } else { 'No' }
        Add-Row $s[5] 'Rule type'             'File'
        Add-Row $s[5] 'Path'                  $main.Folder
        Add-Row $s[5] 'File or folder'        $main.Name $(if ($main.Description) { $main.Description } else { '' })
        if ($main.FileVersion) {
            Add-Row $s[5] 'Detection method'  'String (version)'
            Add-Row $s[5] 'Operator'          'Greater than or equal to'
            Add-Row $s[5] 'Value'             $main.FileVersion 'File version of the exe, not always the same as the MSI version'
        }
        else {
            Add-Row $s[5] 'Detection method'  'File or folder exists' 'The exe has no version info'
        }
        Add-Row $s[5] 'Associated with a 32-bit app on 64-bit clients' $file32
    }
    else {
        Add-Row $s[5] 'Rule type' 'File' $noTest
    }

    # ------------------------------------------------------------------ 4d
    Add-Row $s[6] 'Rules format'          'Use a custom detection script'
    Add-Row $s[6] 'Script file'           'Detect.ps1' 'Generated in the output folder'
    Add-Row $s[6] 'Run script as 32-bit process on 64-bit clients' 'No'
    Add-Row $s[6] 'Enforce script signature check' 'No' 'Yes only if you sign your scripts'
    Add-Row $s[6] 'How it works' "Checks both Uninstall keys for $($Msi.ProductCode), DisplayVersion >= $version"

    # ------------------------------------------------------------------ 5
    $deps = @($Msi.LaunchConditions | Where-Object { $_.Condition -notmatch '^\s*(Privileged|AdminUser|Installed)' })
    if ($deps.Count) {
        foreach ($d in $deps) { Add-Row $s[7] 'MSI launch condition' $d.Condition $d.Description }
        Add-Row $s[7] 'Suggestion' 'Check if any of these need another app first (e.g. .NET, VC++ runtime)' 'Add that app as a dependency, Automatically install = Yes'
    }
    else {
        Add-Row $s[7] 'Dependencies' 'None found' 'The MSI has no launch conditions that point to other software'
    }

    # ------------------------------------------------------------------ 6
    Add-Row $s[8] 'UpgradeCode' $Msi.UpgradeCode 'Same for every version of this product'
    if ($Msi.HasUpgradeTable) {
        Add-Row $s[8] 'Replacing an older version' 'Add the old Intune app here' 'MSI has an Upgrade table, so it removes old versions itself'
        Add-Row $s[8] 'Uninstall previous version' 'No' 'Let the MSI upgrade handle it'
    }
    else {
        Add-Row $s[8] 'Replacing an older version' 'Add the old Intune app here' 'MSI has no Upgrade table'
        Add-Row $s[8] 'Uninstall previous version' 'Yes' 'Otherwise both versions may end up installed'
    }

    # ------------------------------------------------------------------ 7
    Add-Row $s[9] 'Required'  'A pilot / test device group first' 'Widen it once the pilot looks good'
    Add-Row $s[9] 'Available for enrolled devices' 'Optional' 'If users should be able to grab it from Company Portal'
    Add-Row $s[9] 'Uninstall' 'Group for removal (optional)'

    # ------------------------------------------------------------------ found
    $f = $s[10]
    if ($Snapshot) {
        Add-Row $f 'Snapshot taken' "$($Snapshot.TakenOn) on $($Snapshot.Computer)" "Windows $($Snapshot.OsVersion)"
        Add-Row $f 'Install location' $Snapshot.InstallLocation
        if ($arp) {
            Add-Row $f 'ARP registry key'  $arp.ActualPath "Scope: $($arp.Scope)"
            Add-Row $f 'DisplayName'       $arp.DisplayName
            Add-Row $f 'DisplayVersion'    $arp.DisplayVersion
            Add-Row $f 'Publisher'         $arp.Publisher
            Add-Row $f 'InstallDate'       $arp.InstallDate
            if ($arp.EstimatedSizeKB) { Add-Row $f 'EstimatedSize' ("{0:N1} MB" -f ([double]$arp.EstimatedSizeKB / 1024)) }
            Add-Row $f 'UninstallString'   $arp.UninstallString
        }
        else {
            Add-Row $f 'ARP registry key' 'Not found' 'The MSI may hide itself from Programs and Features (ARPSYSTEMCOMPONENT)'
        }
        if ($main) { Add-Row $f 'Main exe (best guess)' $main.Path "v$($main.FileVersion)" }
        foreach ($exe in $Snapshot.Files) {
            if ($main -and $exe.Path -eq $main.Path) { continue }
            Add-Row $f 'Exe' $exe.Path $(if ($exe.FileVersion) { "v$($exe.FileVersion)" } else { '' })
        }
        foreach ($folder in $Snapshot.Folders) { Add-Row $f 'Folder' $folder }
        foreach ($rk in $Snapshot.RegistryKeys) {
            $view = if ($rk.Is64BitView) { '64-bit view' } elseif ($rk.Is32BitOn64) { '32-bit view (WOW6432Node)' } else { '' }
            Add-Row $f 'Registry' "$($rk.Key)  ->  $($rk.ValueName)" $view
        }
        Add-Row $f 'Files tracked by MSI' $Snapshot.FileCount 'Key files only, one per component'
    }
    else {
        Add-Row $f 'Snapshot' $noTest 'Install it once with SilentDrop and this fills in'
    }
    foreach ($sc in $Msi.Shortcuts) { Add-Row $f 'Shortcut (from MSI)' $sc }

    # ------------------------------------------------------------------ tests
    $t = $s[11]
    foreach ($action in 'Install', 'Uninstall') {
        $r = if ($Tests) { $Tests.$action } else { $null }
        if (-not $r) { Add-Row $t $action 'Not tested yet'; continue }
        $meaning = $script:MsiExitMeaning[[int]$r.ExitCode]
        Add-Row $t "$action result"   "Exit $($r.ExitCode) $(if ($meaning) { "($meaning)" })" "$($r.When) on $($r.Computer)"
        Add-Row $t "$action duration" "$($r.DurationSec) seconds"
        Add-Row $t "$action log"      $r.Log
        if ($action -eq 'Uninstall' -and $r.Leftovers) {
            Add-Row $t 'Leftovers after uninstall' $r.Leftovers 'Usually user data or config. Fine for most apps'
        }
    }

    return , $rows
}

function New-DetectionScript {
    param($Msi, $Snapshot)

    $version = $Msi.ProductVersion
    if ($Snapshot -and $Snapshot.Uninstall -and $Snapshot.Uninstall.DisplayVersion) {
        $version = $Snapshot.Uninstall.DisplayVersion
    }
    $root = if ($Snapshot -and $Snapshot.Uninstall -and $Snapshot.Uninstall.Scope -eq 'User') { 'HKCU:' } else { 'HKLM:' }

    return @"
<#
    Intune detection script
    App     : $($Msi.ProductName) $($Msi.ProductVersion)
    Created : $(Get-Date -Format 'yyyy-MM-dd') by SilentDrop
    Tool    : $($script:CreditLine)

    Intune treats the app as installed when this exits 0 AND writes
    something to standard output. Anything else = not installed.
#>

`$productCode = '$($Msi.ProductCode)'
`$minVersion  = '$version'

`$keys = @(
    "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\`$productCode"
    "$root\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\`$productCode"
)

foreach (`$key in `$keys) {
    `$app = Get-ItemProperty -Path `$key -ErrorAction SilentlyContinue
    if (-not `$app) { continue }

    try {
        if ([version]`$app.DisplayVersion -ge [version]`$minVersion) {
            Write-Output "Detected `$(`$app.DisplayName) `$(`$app.DisplayVersion)"
            exit 0
        }
    }
    catch {
        # Version isn't a clean x.y.z, fall back to a plain match
        if (`$app.DisplayVersion -eq `$minVersion) {
            Write-Output "Detected `$(`$app.DisplayName) `$(`$app.DisplayVersion)"
            exit 0
        }
    }
}

exit 1
"@
}

function Export-IntuneDetailsTxt {
    param($Rows, [string]$Path, [string]$Title)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($Title)
    [void]$sb.AppendLine("Generated by SilentDrop on $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    [void]$sb.AppendLine($script:CreditLine)

    foreach ($section in $script:IntuneSections) {
        $sectionRows = @($Rows | Where-Object { $_.Section -eq $section })
        if (-not $sectionRows.Count) { continue }
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("=== $section ===")
        $width = ($sectionRows | ForEach-Object { $_.Field.Length } | Measure-Object -Maximum).Maximum
        foreach ($r in $sectionRows) {
            $line = $r.Field.PadRight($width) + ' : ' + $r.Value
            if ($r.Note) { $line += "   ($($r.Note))" }
            [void]$sb.AppendLine($line)
        }
    }

    $text = $sb.ToString()
    if ($Path) { Set-Content -Path $Path -Value $text -Encoding UTF8 }
    return $text
}

function Export-IntuneDetailsHtml {
    param($Rows, [string]$Path, [string]$Title, [string]$LogoPath)

    function Enc([string]$t) { [System.Net.WebUtility]::HtmlEncode($t) }

    $logoTag = ''
    if ($LogoPath -and (Test-Path $LogoPath)) {
        $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($LogoPath))
        $logoTag = "<img src=`"data:image/png;base64,$b64`" alt=`"`">"
    }

    $body = New-Object System.Text.StringBuilder
    foreach ($section in $script:IntuneSections) {
        $sectionRows = @($Rows | Where-Object { $_.Section -eq $section })
        if (-not $sectionRows.Count) { continue }
        [void]$body.AppendLine("<h2>$(Enc $section)</h2><table>")
        foreach ($r in $sectionRows) {
            $val = if ($r.Value) { "<code>$(Enc $r.Value)</code>" } else { '<span class="empty">fill in</span>' }
            [void]$body.AppendLine("<tr><th>$(Enc $r.Field)</th><td>$val</td><td class=`"note`">$(Enc $r.Note)</td></tr>")
        }
        [void]$body.AppendLine('</table>')
    }

    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(Enc $Title)</title>
<style>
  body { font-family: 'Segoe UI', Arial, sans-serif; margin: 32px; color: #1f2328; background: #fff; max-width: 1100px; }
  header { display: flex; align-items: center; gap: 16px; border-bottom: 2px solid #0969da; padding-bottom: 12px; }
  header img { width: 48px; height: 48px; }
  h1 { font-size: 22px; margin: 0; }
  .sub { color: #59636e; font-size: 13px; }
  h2 { font-size: 16px; margin: 28px 0 8px; color: #0969da; }
  table { border-collapse: collapse; width: 100%; font-size: 13px; }
  th, td { border: 1px solid #d1d9e0; padding: 6px 10px; text-align: left; vertical-align: top; }
  th { width: 28%; background: #f6f8fa; font-weight: 600; }
  td.note { width: 30%; color: #59636e; }
  code { font-family: Consolas, monospace; word-break: break-all; }
  .empty { color: #bc4c00; font-style: italic; }
  footer { margin-top: 32px; padding-top: 12px; border-top: 1px solid #d1d9e0; font-size: 12px; color: #59636e; line-height: 1.7; }
  footer a { color: #0969da; }
</style>
</head>
<body>
<header>$logoTag<div><h1>$(Enc $Title)</h1><div class="sub">Intune Win32 app details, generated $(Get-Date -Format 'yyyy-MM-dd HH:mm')</div></div></header>
$($body.ToString())
<footer>
  Generated by <a href="$(Enc $script:RepoUrl)">SilentDrop</a>, built by <strong>$(Enc $script:Author)</strong> &middot;
  <a href="$(Enc $script:LinkedInUrl)">LinkedIn</a> &middot; <a href="$(Enc $script:GitHubUrl)">GitHub</a><br>
  Double-check everything before you publish, especially detection rules.
</footer>
</body>
</html>
"@

    Set-Content -Path $Path -Value $html -Encoding UTF8
}

function Show-IntuneDetailsWindow {
    param(
        $Rows,
        [string]$Title,
        [string]$LogoPath,
        [string]$Folder,
        [string]$HtmlPath,
        [string]$TxtPath
    )

    $win = New-Object System.Windows.Forms.Form
    $win.Text          = "Intune details - $Title  |  SilentDrop by $script:Author"
    $win.ClientSize    = New-Object System.Drawing.Size(1000, 680)
    $win.StartPosition = 'CenterParent'
    $win.Font          = New-Object System.Drawing.Font('Segoe UI', 9)
    $win.MinimumSize   = New-Object System.Drawing.Size(700, 400)

    # --- header ---
    $top = New-Object System.Windows.Forms.Panel
    $top.Dock   = 'Top'
    $top.Height = 64

    $pic = New-Object System.Windows.Forms.PictureBox
    $pic.Location = New-Object System.Drawing.Point(12, 8)
    $pic.Size     = New-Object System.Drawing.Size(48, 48)
    $pic.SizeMode = 'Zoom'
    if ($LogoPath -and (Test-Path $LogoPath)) {
        # Load from bytes so the png file isn't locked while the window is open
        $bytes = [IO.File]::ReadAllBytes($LogoPath)
        $pic.Image = [System.Drawing.Image]::FromStream((New-Object IO.MemoryStream(, $bytes)))
    }
    $top.Controls.Add($pic)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text     = $Title
    $lblTitle.Font     = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(70, 8)
    $lblTitle.AutoSize = $true
    $top.Controls.Add($lblTitle)

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text      = 'Same order as the Intune portal. Double-click a row to copy its value. Orange = you fill it in.'
    $lblHint.ForeColor = [System.Drawing.Color]::DimGray
    $lblHint.Location  = New-Object System.Drawing.Point(72, 38)
    $lblHint.AutoSize  = $true
    $top.Controls.Add($lblHint)

    # --- the list ---
    $list = New-Object System.Windows.Forms.ListView
    $list.View          = 'Details'
    $list.FullRowSelect = $true
    $list.GridLines     = $true
    $list.ShowItemToolTips = $true
    $list.Dock          = 'Fill'
    [void]$list.Columns.Add('Field', 250)
    [void]$list.Columns.Add('Value', 430)
    [void]$list.Columns.Add('Note', 290)

    $groups = @{}
    foreach ($section in $script:IntuneSections) {
        $g = New-Object System.Windows.Forms.ListViewGroup($section, $section)
        [void]$list.Groups.Add($g)
        $groups[$section] = $g
    }

    $orange = [System.Drawing.Color]::FromArgb(188, 76, 0)
    foreach ($r in $Rows) {
        $item = New-Object System.Windows.Forms.ListViewItem($r.Field)
        $displayValue = if ($r.Value) { $r.Value } else { '(fill in)' }
        [void]$item.SubItems.Add($displayValue)
        [void]$item.SubItems.Add($r.Note)
        $item.Group       = $groups[$r.Section]
        $item.Tag         = $r.Value
        $item.ToolTipText = "$($r.Value)`n$($r.Note)".Trim()
        if (-not $r.Value) { $item.ForeColor = $orange }
        [void]$list.Items.Add($item)
    }

    # --- bottom buttons ---
    $bottom = New-Object System.Windows.Forms.FlowLayoutPanel
    $bottom.Dock          = 'Bottom'
    $bottom.Height        = 44
    $bottom.FlowDirection = 'RightToLeft'
    $bottom.Padding       = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)

    $status = New-Object System.Windows.Forms.Label
    $status.AutoSize = $true
    $status.Margin   = New-Object System.Windows.Forms.Padding(12, 8, 12, 0)
    $status.ForeColor = [System.Drawing.Color]::DimGray

    function New-WinButton([string]$Text, [int]$Width = 120) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text   = $Text
        $b.Width  = $Width
        $b.Height = 30
        return $b
    }

    $btnClose  = New-WinButton 'Close' 90
    $btnFolder = New-WinButton 'Open folder'
    $btnHtml   = New-WinButton 'Open HTML report' 130
    $btnAll    = New-WinButton 'Copy all as text' 130
    $btnCopy   = New-WinButton 'Copy value'

    $credit = New-Object System.Windows.Forms.LinkLabel
    $credit.Text     = "SilentDrop by $script:Author  |  LinkedIn  |  GitHub"
    $credit.AutoSize = $true
    $credit.Margin   = New-Object System.Windows.Forms.Padding(12, 9, 12, 0)
    $credit.Links.Clear()
    $liStart = $credit.Text.IndexOf('LinkedIn')
    $ghStart = $credit.Text.IndexOf('GitHub')
    [void]$credit.Links.Add($liStart, 8, $script:LinkedInUrl)
    [void]$credit.Links.Add($ghStart, 6, $script:GitHubUrl)
    $credit.Add_LinkClicked({ param($s, $e) Start-Process ([string]$e.Link.LinkData) })

    $bottom.Controls.AddRange(@($btnClose, $btnFolder, $btnHtml, $btnAll, $btnCopy, $status, $credit))

    $copySelected = {
        if ($list.SelectedItems.Count -eq 0) { return }
        $sel = $list.SelectedItems[0]
        $val = [string]$sel.Tag
        if ($val) {
            [System.Windows.Forms.Clipboard]::SetText($val)
            $status.Text = "Copied: $($sel.Text)"
        }
        else {
            $status.Text = "$($sel.Text) is empty, nothing to copy"
        }
    }

    $list.Add_DoubleClick($copySelected)
    $btnCopy.Add_Click($copySelected)
    $btnAll.Add_Click({
        $text = Export-IntuneDetailsTxt -Rows $Rows -Path '' -Title $Title
        [System.Windows.Forms.Clipboard]::SetText($text)
        $status.Text = 'Copied everything'
    })
    $btnHtml.Add_Click({ if ($HtmlPath -and (Test-Path $HtmlPath)) { Start-Process $HtmlPath } })
    $btnFolder.Add_Click({ if ($Folder -and (Test-Path $Folder)) { Start-Process explorer.exe -ArgumentList "`"$Folder`"" } })
    $btnClose.Add_Click({ $win.Close() })

    $btnHtml.Enabled   = [bool]$HtmlPath
    $btnFolder.Enabled = [bool]$Folder

    # Dock order: Fill control must be added first / brought to front last
    $win.Controls.Add($list)
    $win.Controls.Add($top)
    $win.Controls.Add($bottom)
    $list.BringToFront()

    [void]$win.ShowDialog()
    if ($pic.Image) { $pic.Image.Dispose() }
    $win.Dispose()
}
