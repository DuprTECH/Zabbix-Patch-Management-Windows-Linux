# setup-windows.ps1 - Zabbix patch management on a Windows server without Ansible: setup, check, updates
#
# Paste the whole file into PowerShell as administrator, or run it as a file:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File setup-windows.ps1
# A menu asks what to do (or set $env:ZBX_PATCH_MODE = 'update' before):
#   1 monitor  = like ansible/check-windows.yml: checker zbx-patch-windows.ps1, scheduled tasks (check every
#                12 h and after a reboot, automatic update every 15 min), patch settings <Zabbix agent folder>\zbx-patch.conf,
#                UserParameter patch.config (host macros {$PATCH.CONF.*}), first check. Running it again updates an installed server and keeps the settings.
#   2 check    = run the update check now (pending updates -> Zabbix) and show the patch settings
#   3 update   = install updates now (security, critical, rollups, definitions,
#                updates) in the maintenance window, without EXCLUDE, reboot when needed and REBOOT="yes", result to Zabbix
#   4 force    = like 3, also outside the maintenance window
#
# AUTO_UPDATE="false" in zbx-patch.conf (default) = the checker only checks; "true" = it installs the
# updates itself in the maintenance window (once per window, like 3).
#
# The checker zbx-patch-windows.ps1 is embedded (no internet needed); a copy in %TEMP% or C:\Temp wins.
# Requires the Zabbix agent 2 (zabbix_sender.exe). Docs: README.md (https://github.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux)
#
# Author : Dusan Priechodsky
# Source : https://github.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux
# Contact: info@duprtech.sk
# License: MIT
& {
$Mode          = "$env:ZBX_PATCH_MODE"     # monitor | check | update | force, empty = menu
$IntervalHours = 12
$DefaultWindow = '* 03:00-05:00'   # maintenance window of a new zbx-patch.conf: every night, never during the day
$TaskName      = 'Zabbix patch check'
$AutoTaskName  = 'Zabbix patch auto update'
#
function Ask([string]$Question, [string]$Default) {
    $a = Read-Host "$Question [$Default]"
    if ([string]::IsNullOrWhiteSpace($a)) { $Default } else { $a.Trim() }
}
#
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Warning 'Run PowerShell as administrator.'; return }
$AgentDir = @('C:\Program Files\Zabbix Agent 2', 'C:\Program Files\Zabbix Agent') |
    Where-Object { Test-Path (Join-Path $_ 'zabbix_sender.exe') } | Select-Object -First 1
if (-not $AgentDir) { Write-Warning 'zabbix_sender.exe not found - install the Zabbix agent 2 first.'; return }
$ZSender   = Join-Path $AgentDir 'zabbix_sender.exe'
$AgentConf = (Get-ChildItem $AgentDir -Filter 'zabbix_agent*.conf' | Select-Object -First 1).FullName
$Check     = Join-Path $AgentDir 'scripts\zbx-patch-windows.ps1'
$PatchConf = Join-Path $AgentDir 'zbx-patch.conf'
#
# ---------------- Checker ----------------
# The checker is embedded before the menu (no internet needed); a newer copy in %TEMP% or C:\Temp is used instead
function Get-Check {
    New-Item -ItemType Directory -Force (Split-Path $Check) | Out-Null
    $tmp   = "$Check.new"
    $local = @("$env:TEMP\zbx-patch-windows.ps1", 'C:\Temp\zbx-patch-windows.ps1') | Where-Object { Test-Path $_ } | Select-Object -First 1
    $src   = if ($local) { $local } else { 'embedded' }
    try {
        if ($local) { Copy-Item $local $tmp -Force }
        else {
            # gzip + base64 -> original bytes
            $in  = New-Object IO.MemoryStream(, [Convert]::FromBase64String(($CheckB64 -replace '\s', '')))
            $gz  = New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress)
            $out = New-Object IO.MemoryStream
            $gz.CopyTo($out); $gz.Close()
            [IO.File]::WriteAllBytes($tmp, $out.ToArray())
        }
    } catch {}
    if (-not ((Test-Path $tmp) -and (Select-String -Path $tmp -Pattern 'AutoUpdate' -Quiet))) {
        Remove-Item $tmp -ErrorAction SilentlyContinue
        Write-Warning "The checker ($src) is damaged or old - copy zbx-patch-windows.ps1 to $env:TEMP and run again."
        return $false
    }
    Move-Item $tmp $Check -Force
    Write-Host "Checker: $Check ($src)"
    return $true
}
function Test-Checker { (Test-Path $Check) -and (Select-String -Path $Check -Pattern 'AutoUpdate' -Quiet) }
function Invoke-Check([string[]]$Extra) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Check, '-SenderPath', $ZSender, '-ConfigPath', $AgentConf, '-PatchConfig', $PatchConf) + $Extra
    & powershell.exe @a
}
function Get-PatchSettings {
    if (-not (Test-Checker)) { return $null }
    try { ((Invoke-Check '-ShowConfig') -join '') | ConvertFrom-Json } catch { $null }
}
function Show-PatchSettings($c) {
    $win  = if ($c.maintenance_window) { $c.maintenance_window } else { '- (any time)' }
    $open = if ($c.maintenance_active) { ' - open now' } else { '' }
    $next = if ($c.maintenance_next) { [DateTimeOffset]::FromUnixTimeSeconds([long]$c.maintenance_next).LocalDateTime.ToString('yyyy-MM-dd HH:mm') } else { '-' }
    $excl = if (@($c.exclude).Count -gt 0) { @($c.exclude) -join ', ' } else { '-' }
    Write-Host "Maintenance window: $win$open"
    if ($c.maintenance_error) { Write-Host "  ERROR: $($c.maintenance_error)" }
    Write-Host "Next window:        $next"
    Write-Host "Auto update:        $($c.auto_update)"
    Write-Host "Excluded:           $excl"
    Write-Host "Reboot allowed:     $($c.reboot_allowed)"
}
function Invoke-CheckNow {
    if (-not (Test-Checker)) { Write-Warning 'The checker is not installed (or old) - choose 1 (monitor) first.'; return }
    Write-Host '=== Patch settings'
    $c = Get-PatchSettings
    if ($c) { Show-PatchSettings $c }
    Write-Host '=== Update check (sends to Zabbix, the update search can take a few minutes)'
    Invoke-Check | Out-Host
}
#
# ---------------- 1. Monitor: checker, scheduled tasks, patch settings ----------------
function Install-Monitor {
    Write-Host '=== Update checker for Zabbix'
    if (-not (Get-Check)) { return $false }
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$Check`" -SenderPath `"$ZSender`" -ConfigPath `"$AgentConf`""
    # Check every IntervalHours (shifted by a per-host offset of -30..+30 min) and 5 min after a reboot
    $hash = 0; foreach ($ch in $env:COMPUTERNAME.ToCharArray()) { $hash = ($hash * 31 + [int]$ch) % 1000003 }
    $offset   = ($hash % 61) - 30
    $times    = foreach ($h in (0..23 | Where-Object { $_ % $IntervalHours -eq 0 })) { (Get-Date).Date.AddHours($h).AddMinutes($offset) }
    $triggers = @($times | ForEach-Object { New-ScheduledTaskTrigger -Daily -At $_ })
    $boot = New-ScheduledTaskTrigger -AtStartup; $boot.Delay = 'PT5M'; $triggers += $boot
    Register-ScheduledTask -TaskName $TaskName -Force -Principal $principal -Trigger $triggers `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg) `
        -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)) | Out-Null
    Write-Host ("Scheduled task '{0}': {1} and after a reboot" -f $TaskName, (($times | ForEach-Object { $_.ToString('HH:mm') }) -join ', '))
    # Automatic update every 15 min: installs only with AUTO_UPDATE="true", in the maintenance window, once per window
    $every15 = New-ScheduledTaskTrigger -Daily -At '00:00'
    $every15.Repetition = (New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Hours 24)).Repetition
    Register-ScheduledTask -TaskName $AutoTaskName -Force -Principal $principal -Trigger $every15 `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "$arg -AutoUpdate") `
        -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 4)) | Out-Null
    Write-Host "Scheduled task '$AutoTaskName': every 15 min (installs updates only with AUTO_UPDATE=`"true`")"
    Unregister-ScheduledTask -TaskName 'Zabbix patch check after reboot' -Confirm:$false -ErrorAction SilentlyContinue
    # Patch settings: the values already in the file are kept, new settings get the defaults;
    # the file is written every time, so new settings are added to an existing file
    $cur = @{}
    if (Test-Path $PatchConf) {
        foreach ($l in Get-Content $PatchConf) { if ($l -match '^\s*([A-Z_]+)\s*=\s*"?([^"#]*)"?') { $cur[$Matches[1]] = $Matches[2].Trim() } }
    }
    $win    = if ($cur.ContainsKey('MAINTENANCE_WINDOW')) { $cur['MAINTENANCE_WINDOW'] } else { $DefaultWindow }
    $auto   = if ($cur.ContainsKey('AUTO_UPDATE')) { $cur['AUTO_UPDATE'] } else { 'false' }
    $ex     = if ($cur.ContainsKey('EXCLUDE')) { $cur['EXCLUDE'] } else { '' }
    $rb     = if ($cur.ContainsKey('REBOOT')) { $cur['REBOOT'] } else { 'yes' }
    $keep   = 'n'
    if (Test-Path $PatchConf) {
        Write-Host "Patch settings ${PatchConf}:"
        Write-Host "  MAINTENANCE_WINDOW=`"$win`"`n  AUTO_UPDATE=`"$auto`"`n  EXCLUDE=`"$ex`"`n  REBOOT=`"$rb`""
        $keep = Ask 'Keep them? (y/n)' 'y'
    }
    if ($keep -notmatch '^[Yy]') {
        Write-Host "Maintenance window: '<day> <HH:MM>-<HH:MM>', several separated by commas; day 1-7 = Monday-Sunday"
        Write-Host "  (or Mon..Sun), 1-5, * = every day, 2.3 = 2nd Wednesday; '-' = any time. Example: 3 03:00-05:00 = Wednesday"
        $win = Ask 'Maintenance window' $(if ($win) { $win } else { '-' })
        if ($win -eq '-') { $win = '' }
        $auto = Ask 'Automatic updates in the maintenance window (true/false)' $auto
        $ex = Ask "Excluded updates, comma separated: KB number or a part of the title ('-' = none)" $(if ($ex) { $ex } else { '-' })
        if ($ex -eq '-') { $ex = '' }
        $rb = Ask 'Reboot after updates when needed (yes/no)' $rb
    }
    @"
# zbx-patch.conf - patch management settings of this host
# Read by the checker zbx-patch-windows.ps1 (sent to Zabbix, template 'APP Patch management all OS')
# and by setup-windows.ps1 (update). Written by setup-windows.ps1 -
# you can edit it, the values are kept when the setup runs again.
#
# Maintenance window - when updates may be installed and the host rebooted.
#   "<day> <HH:MM>-<HH:MM>", several separated by commas, local time of the host
#   day: 1-7 = Monday-Sunday (or Mon..Sun), a range 1-5, * = every day, 2.3 = 2nd Wednesday of the month
#   an end lower than the start = the window ends the next day (6 22:00-04:00)
#   empty = any time
#   MAINTENANCE_WINDOW="3 03:00-05:00"   = every Wednesday 03:00-05:00
MAINTENANCE_WINDOW="$win"
#
# Automatic updates: true = the checker installs the updates itself in the maintenance window
# (task "Zabbix patch auto update" every 15 min, once per window, log C:\ProgramData\zbx-patch\update.log);
# false = check only
AUTO_UPDATE="$auto"
#
# Updates that are not installed, separated by commas: KB number or a part of the title
#   EXCLUDE="KB5034441, Preview"
EXCLUDE="$ex"
#
# Reboot after updates when needed: yes / no (no = the reboot is only reported to Zabbix)
REBOOT="$rb"
"@ | Set-Content -Path $PatchConf -Encoding ASCII
    Write-Host "Saved $PatchConf"
    # Settings from Zabbix: UserParameter patch.config (host macros {$PATCH.CONF.*} -> zbx-patch-from-zbx-host-macro.cache),
    # the agent is restarted only when its config changed (undone when it doesn't start)
    Write-Host '=== Zabbix agent: UserParameter patch.config (settings from the host macros)'
    Invoke-Check '-InstallAgentConfig' | Out-Host
    Invoke-CheckNow
    return $true
}
#
# ---------------- 3. / 4. Install updates now (the checker does it: -Update [-Force]) ----------------
function Install-UpdatesNow([bool]$Force) {
    if (-not (Test-Checker)) {
        Write-Host 'The update checker is not installed (or old) - installing it first.'
        if (-not (Install-Monitor)) { return }
    }
    Write-Host '=== Patch settings'
    $c = Get-PatchSettings
    if ($c) { Show-PatchSettings $c }
    if ($Force) { Invoke-Check '-Update', '-Force' | Out-Host } else { Invoke-Check '-Update' | Out-Host }
}
#
# Embedded check script: zbx-patch-windows.ps1 from DuprTECH/Zabbix-Patch-Management-Windows-Linux 20cfdb9 (embed-check.sh)
$CheckB64 = @'
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
/v28Q7YInKasyGyLR2Qc4v8Bg4grSlOUAAA=
'@
#
# ---------------- Menu ----------------
if (-not $Mode) {
    Write-Host "Zabbix patch management - $env:COMPUTERNAME"
    Write-Host '  1) monitor - install / update the checker for Zabbix (scheduled tasks, zbx-patch.conf incl. AUTO_UPDATE)'
    Write-Host '  2) check   - run the update check now'
    Write-Host '  3) update  - install updates (only in the maintenance window)'
    Write-Host '  4) force   - install updates now (also outside the maintenance window)'
    $Mode = Ask 'Choose' '1'
}
switch -Regex ($Mode) {
    '^(1|monitor)$' { [void](Install-Monitor) }
    '^(2|check)$'   { Invoke-CheckNow }
    '^(3|update)$'  { Install-UpdatesNow $false }
    '^(4|force)$'   { Install-UpdatesNow $true }
    default         { Write-Warning "Unknown choice: $Mode" }
}
}
