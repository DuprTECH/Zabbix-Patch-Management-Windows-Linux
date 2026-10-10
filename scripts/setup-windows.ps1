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
# Embedded check script: zbx-patch-windows.ps1 from DuprTECH/Zabbix-Patch-Management-Windows-Linux 098b49e (embed-check.sh)
$CheckB64 = @'
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
AAA=
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
