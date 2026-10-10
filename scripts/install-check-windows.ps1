#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Check only (no updates are installed): installs the check script zbx-patch-windows.ps1,
    runs it by Task Scheduler every N hours and runs it once now.

.DESCRIPTION
    Zabbix (template 'APP Patch management all OS') then gets the update status of this host.
    Use it when you only want the reporting (updates are installed by WSUS, SCCM, Intune,
    another tool or by hand), or to run the check more often than your install job.

    - finds the Zabbix agent (zabbix_sender.exe and the agent config)
    - copies zbx-patch-windows.ps1 from the same folder (or downloads it from GitHub)
      to <Zabbix agent folder>\scripts
    - creates the scheduled task "Zabbix patch check" (SYSTEM) every N hours, shifted by
      a fixed per-host offset of -30..+30 min, so the hosts don't run at the same time
    - runs the check now

.PARAMETER IntervalHours
    Check interval in hours, a divisor of 24 (default 12).

.PARAMETER AgentDir
    Zabbix agent folder (default: C:\Program Files\Zabbix Agent 2, then C:\Program Files\Zabbix Agent).

.PARAMETER ZabbixServer
    Optional: Zabbix server / proxy for the check (instead of ServerActive from the agent config).

.PARAMETER HostName
    Optional: host name in Zabbix (instead of Hostname from the agent config / the computer name).

.PARAMETER NoRun
    Install only, don't run the check now.

.PARAMETER MaintenanceWindow
    Patch settings <Zabbix agent folder>\zbx-patch.conf (written every time: values already in the file
    are kept unless given here, missing settings get the defaults; see the comments in the file):
    when updates may be installed, for example "3 03:00-05:00" (Wednesday)
    (default: "* 03:00-05:00" - every night, never during the day).

.PARAMETER AutoUpdate
    true = the check script installs the updates itself in the maintenance window
    (task "Zabbix patch auto update" every 15 min, once per window); false = check only (default).

.PARAMETER Exclude
    Updates that are not installed, for example "KB5034441, Preview" (KB number or a part of the title).

.PARAMETER Reboot
    Reboot after updates when needed: yes / no (default: yes).

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File install-check-windows.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File install-check-windows.ps1 -IntervalHours 4
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File install-check-windows.ps1 -MaintenanceWindow "3 03:00-05:00" -AutoUpdate true
    Running it again updates an existing installation (script, tasks, new settings).

.NOTES
    Author : Dusan Priechodsky
    Source : https://github.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux
    Contact: info@duprtech.sk
    License: MIT
#>
param(
    [ValidateSet(1, 2, 3, 4, 6, 8, 12, 24)]
    [int]$IntervalHours = 12,
    [string]$AgentDir = "",
    [string]$ZabbixServer = "",
    [string]$HostName = "",
    [switch]$NoRun,
    [string]$MaintenanceWindow,
    [ValidateSet('true', 'false')]
    [string]$AutoUpdate,
    [string]$Exclude,
    [ValidateSet('yes', 'no')]
    [string]$Reboot
)
$ErrorActionPreference = 'Stop'
$Url      = 'https://raw.githubusercontent.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux/main/scripts/zbx-patch-windows.ps1'
$TaskName = 'Zabbix patch check'
$AutoTaskName = 'Zabbix patch auto update'

# 1. Zabbix agent
if (-not $AgentDir) {
    $AgentDir = @('C:\Program Files\Zabbix Agent 2', 'C:\Program Files\Zabbix Agent') |
        Where-Object { Test-Path (Join-Path $_ 'zabbix_sender.exe') } | Select-Object -First 1
}
if (-not $AgentDir -or -not (Test-Path (Join-Path $AgentDir 'zabbix_sender.exe'))) {
    throw "zabbix_sender.exe not found - install the Zabbix agent 2 (it includes zabbix_sender) or use -AgentDir."
}
$sender = Join-Path $AgentDir 'zabbix_sender.exe'
$conf   = Get-ChildItem $AgentDir -Filter 'zabbix_agent*.conf' | Select-Object -First 1
if (-not $conf) { throw "Zabbix agent config not found in $AgentDir" }

# 2. Check script: local copy next to this script, or download
$scripts = Join-Path $AgentDir 'scripts'
New-Item -ItemType Directory -Force $scripts | Out-Null
$dest  = Join-Path $scripts 'zbx-patch-windows.ps1'
$local = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'zbx-patch-windows.ps1' } else { '' }
if ($local -and (Test-Path $local) -and ($local -ne $dest)) {
    Copy-Item $local $dest -Force
} elseif (-not ($local -and $local -eq $dest)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Url -OutFile $dest -UseBasicParsing
}
Write-Output "Installed $dest"

# 3. Scheduled task: every IntervalHours, shifted by a per-host offset of -30..+30 min
$hash   = 0; foreach ($ch in $env:COMPUTERNAME.ToCharArray()) { $hash = ($hash * 31 + [int]$ch) % 1000003 }
$offset = ($hash % 61) - 30
$arg    = "-NoProfile -ExecutionPolicy Bypass -File `"$dest`" -SenderPath `"$sender`" -ConfigPath `"$($conf.FullName)`""
if ($ZabbixServer) { $arg += " -ZabbixServer `"$ZabbixServer`"" }
if ($HostName)     { $arg += " -HostName `"$HostName`"" }
$triggers = @(foreach ($h in (0..23 | Where-Object { $_ % $IntervalHours -eq 0 })) {
    New-ScheduledTaskTrigger -Daily -At (Get-Date).Date.AddHours($h).AddMinutes($offset)
})
# Check also 5 minutes after a reboot (after an update)
$boot = New-ScheduledTaskTrigger -AtStartup; $boot.Delay = 'PT5M'; $triggers += $boot
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
Write-Output ("Scheduled task '{0}': every {1} h, offset {2} min, and after a reboot" -f $TaskName, $IntervalHours, $offset)
# Automatic update (AUTO_UPDATE="true" in zbx-patch.conf): every 15 min, the script exits right away
# outside the maintenance window, so it installs the updates once per window
$every15 = New-ScheduledTaskTrigger -Daily -At '00:00'
$every15.Repetition = (New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Hours 24)).Repetition
Register-ScheduledTask -TaskName "$AutoTaskName" -Force -Principal $principal -Trigger $every15 `
    -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "$arg -AutoUpdate") `
    -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 4)) | Out-Null
Write-Output "Scheduled task '$AutoTaskName': every 15 min (installs updates only with AUTO_UPDATE=`"true`")"

# 4. Patch settings: written every time - the values already in the file are kept (unless given
#    here), missing settings are added with the defaults
$patchConf = Join-Path $AgentDir 'zbx-patch.conf'
$cur = @{}
if (Test-Path $patchConf) {
    foreach ($l in Get-Content $patchConf) { if ($l -match '^\s*([A-Z_]+)\s*=\s*"?([^"#]*)"?') { $cur[$Matches[1]] = $Matches[2].Trim() } }
}
$MaintenanceWindow = if ($PSBoundParameters.ContainsKey('MaintenanceWindow')) { $MaintenanceWindow } elseif ($cur.ContainsKey('MAINTENANCE_WINDOW')) { $cur['MAINTENANCE_WINDOW'] } else { '* 03:00-05:00' }
$AutoUpdate        = if ($PSBoundParameters.ContainsKey('AutoUpdate')) { $AutoUpdate } elseif ($cur.ContainsKey('AUTO_UPDATE')) { $cur['AUTO_UPDATE'] } else { 'false' }
$Exclude           = if ($PSBoundParameters.ContainsKey('Exclude')) { $Exclude } elseif ($cur.ContainsKey('EXCLUDE')) { $cur['EXCLUDE'] } else { '' }
$Reboot            = if ($PSBoundParameters.ContainsKey('Reboot')) { $Reboot } elseif ($cur.ContainsKey('REBOOT')) { $cur['REBOOT'] } else { 'yes' }
@"
# zbx-patch.conf - patch management settings of this host
# Read by the check script zbx-patch-windows.ps1 (sent to Zabbix, template 'APP Patch management all OS')
# and by the install job (Ansible playbook, your update script, ...).
#
# Maintenance window - when updates may be installed and the host rebooted.
#   "<day> <HH:MM>-<HH:MM>", several separated by commas, local time of the host
#   day: 1-7 = Monday-Sunday (or Mon..Sun), a range 1-5, * = every day, 2.3 = 2nd Wednesday of the month
#   an end lower than the start = the window ends the next day (6 22:00-04:00)
#   empty = any time
#   MAINTENANCE_WINDOW="3 03:00-05:00"   = every Wednesday 03:00-05:00
MAINTENANCE_WINDOW="$MaintenanceWindow"

# Automatic updates: true = the check script installs the updates itself in the maintenance window
# (task "Zabbix patch auto update" every 15 min, once per window, log C:\ProgramData\zbx-patch\update.log);
# false = check only
AUTO_UPDATE="$AutoUpdate"

# Updates that are not installed, separated by commas: KB number or a part of the title
#   EXCLUDE="KB5034441, Preview"
EXCLUDE="$Exclude"

# Reboot after updates when needed: yes / no (no = the reboot is only reported to Zabbix)
REBOOT="$Reboot"
"@ | Set-Content -Path $patchConf -Encoding ASCII
Write-Output "Patch settings ${patchConf}: window '$MaintenanceWindow', auto update $AutoUpdate, exclude '$Exclude', reboot $Reboot"

# 5. Settings from Zabbix: UserParameter patch.config (host macros {$PATCH.CONF.*} ->
#    zbx-patch-from-zbx-host-macro.cache, wins over zbx-patch.conf); the agent is restarted only
#    when its config changed (undone when it doesn't start)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dest -ConfigPath $conf.FullName -InstallAgentConfig
if ($LASTEXITCODE -ne 0) { Write-Warning 'UserParameter not installed - the host macros {$PATCH.CONF.*} do not apply on this host' }

# 6. Run the check now
if (-not $NoRun) {
    Write-Output "Running the check (the update search can take a few minutes) ..."
    $params = @{ SenderPath = $sender; ConfigPath = $conf.FullName }
    if ($ZabbixServer) { $params.ZabbixServer = $ZabbixServer }
    if ($HostName)     { $params.HostName = $HostName }
    & $dest @params
}
