# Zabbix – Patch management for Windows and Linux (dashboard, check scripts, Ansible)

Zabbix 7.4 templates and scripts to see the **update status of all your Windows and Linux servers in one place**: how many updates are pending (critical, security, …), which ones, whether a reboot is needed, when updates were last installed and with what result.

![Example Zabbix patch management dashboard](screen.png)

*Example dashboard built from the data of these templates: all hosts with pending updates by category, reboot needed, WSUS status, last check, last install run and result; totals, servers with / without updates over a year, average uptime.*

- 🕵️ **The screenshot is anonymized.** In the real dashboard you see your **real host names** instead of *SERVER-01, 02, …*. **Click a host** to open its details and the full history of its updates in Zabbix.
- 🧩 **The dashboard is not part of the template.** Zabbix can't export a global dashboard together with a template, so it isn't in this repository. If you'd like a dashboard like this, I can help you build one to fit your needs. Get in touch: 📧 [info@duprtech.sk](mailto:info@duprtech.sk)

## ✨ Highlights

- 🪟🐧 **Windows and Linux**: Windows Update / WSUS, and apt (Debian, Ubuntu) or dnf / yum (RHEL, Rocky, Alma, Fedora)
- 📋 **Pending updates by category**: all, critical, security, definition, service packs, update rollups, plus the **list of individual updates** (KB and title / package and version)
- 🔁 **Reboot required**, WSUS / repository availability, Windows Update service startup type
- 🛠️ **Last install run**: date, age, result, installed updates, last restart, and the **patch day** (for example *2.Tue* = 2nd Tuesday) as a host tag
- 🚨 **Triggers**: critical / security updates pending, reboot required, WSUS / repository unavailable, **no data from a host** (script stopped running)
- 🧰 **Works your way**: the check runs from the Zabbix agent **or** from Task Scheduler / cron with zabbix_sender. Updates are installed by Task Scheduler / cron, **Ansible** (playbook included) or any other tool.

## How it works

```mermaid
flowchart LR
    subgraph Host[Windows / Linux host]
        C[Check script<br/>zbx-windows-updates.ps1<br/>zbx-linux-updates.sh]
        I[Install updates<br/>Task Scheduler / cron /<br/>your update script]
    end
    A[Zabbix agent<br/>system.run] -. option 1 .-> C
    S[Task Scheduler / cron] -. option 2 .-> C
    AN[Ansible playbook<br/>patch-and-report.yml] -->|installs updates| Host
    C -->|zabbix_sender| Z[(Zabbix server / proxy)]
    I -->|zabbix_sender| Z
    AN -->|zabbix_sender| Z
    Z --> D[Dashboard, triggers, history]
```

**1. Checking pending updates** (the *check* items) – choose one:

| Option | How | When to use |
|--------|-----|-------------|
| **Zabbix agent** | Item *Run update check* starts the script with `system.run[…,nowait]`, the script sends the results with zabbix_sender | Simple, everything is controlled from Zabbix. Needs `AllowKey=system.run[*]` in the agent config. |
| **Task Scheduler / cron** | The script runs on a schedule and sends the results with zabbix_sender | You don't want `system.run` enabled, or you want full control over the schedule. Disable the item *Run update check*. |

**2. Installing updates** (the *install* items) – choose what fits you:

| Option | How |
|--------|-----|
| **Task Scheduler / cron** | Your own update script (a Windows install script will be added to this repository) installs the updates and sends the result with zabbix_sender |
| **Ansible** | [`ansible/patch-and-report.yml`](ansible/patch-and-report.yml) installs the updates on Windows and Linux, reboots if needed and sends the result to Zabbix |
| **Other tools** | AWX / Ansible Tower, Rundeck, WSUS, SCCM, Intune, … Send the result to the *install* items with zabbix_sender (see the keys below) |

## Contents

| File | Description |
|------|-------------|
| `template_patch_management.yaml` | Zabbix **7.4** export with 2 templates: `APP Winupdates check` and `APP Linux updates check` |
| `scripts/windows/zbx-windows-updates.ps1` | Windows check script (PowerShell, Windows Update Agent API) |
| `scripts/linux/zbx-linux-updates.sh` | Linux check script (bash, apt / dnf / yum) |
| `ansible/patch-and-report.yml` | Ansible playbook: install updates on Windows and Linux, report to Zabbix |
| `ansible/inventory.example.ini` | Example inventory |

### `APP Winupdates check` (Windows)

| Item | Key | Sent by |
|------|-----|---------|
| WU - All / Critical / Security / Definition / ServicePacks / UpdateRollups | `zbx.winupdate.vbs.all`, `.critical`, `.security`, `.definition`, `.servicepacks`, `.updaterollups` | check script |
| WU - Pending updates list | `zbx.winupdate.vbs.list` | check script |
| WU - Reboot required | `zbx.winupdate.vbs.rebootrequired` | check script, Ansible |
| WU - WSUS availability | `zbx.winupdate.vbs.wsusavailability` | check script |
| WU - Last check date / age | `zbx.winupdate.vbs.datetime` / `.datetime.timestamp` | check script / calculated |
| WU - Service startup type | `service.info[wuauserv,startup]` | Zabbix agent |
| WU install - Last install date / age / patch day | `zbx.winupdate.vbs.install.datetime`, `.install.datetime.timestamp`, `.install.datetime.day_of_mounth` | install job / calculated |
| WU install - Search / Download / Install result, Installed updates, Last restart | `zbx.winupdate.vbs.install.search`, `.install.download`, `.install.install.res`, `.install.install`, `.install.lastrestart` | install job, Ansible |

Triggers: critical updates (High), security updates (Warning), reboot required (Info), Windows Update service disabled / manual / unknown (Warning), no data for `{$WU.NODATA}` (Warning), WSUS unavailable and any updates available (*disabled by default*).

> The keys keep the prefix `zbx.winupdate.vbs.` for compatibility with existing installations.

### `APP Linux updates check` (Linux)

| Item | Key | Sent by |
|------|-----|---------|
| LU - All / Security | `linux.updates.all`, `linux.updates.security` | check script |
| LU - Pending updates list | `linux.updates.list` | check script |
| LU - Reboot required | `linux.updates.rebootrequired` | check script, Ansible |
| LU - Repository availability | `linux.updates.repoavailability` | check script (as root) |
| LU - Package manager | `linux.updates.pkgmanager` | check script |
| LU - Last check timestamp / age | `linux.updates.timestamp` / `linux.updates.age` | check script / calculated |
| LU install - Last install timestamp / age | `linux.updates.install.timestamp` / `linux.updates.install.age` | install job, Ansible / calculated |
| LU install - Installed packages / count / result | `linux.updates.install.list`, `.install.count`, `.install.result` | install job, Ansible |

Triggers: security updates (Warning), reboot required (Info), repository unavailable (Warning), no data for `{$LINUX.UPDATES.NODATA}` (Warning), no updates installed for `{$LINUX.UPDATES.INSTALL.MAXAGE}` and any updates available (*disabled by default*).

## Requirements

- Zabbix server / proxy **7.4** or newer, reachable from the hosts on port **10051** (zabbix_sender)
- **Windows**: Zabbix agent 2 (includes `zabbix_sender.exe`), Windows PowerShell 5.1
- **Linux**: `zabbix_sender` (package `zabbix-sender`), bash; `needs-restarting` (dnf-utils / yum-utils) on RHEL for the reboot check
- **Ansible** (optional): `zabbix_sender` on the controller, collection `ansible.windows` for Windows hosts
- The **host name in Zabbix** must match the `Hostname` in the agent config (or the name you pass to zabbix_sender), otherwise the values are rejected

## Installation

### Zabbix
1. Import `template_patch_management.yaml` (*Data collection → Templates → Import*).
2. Link `APP Winupdates check` to Windows hosts and `APP Linux updates check` to Linux hosts.
3. Check the macros (see below), mainly `{$WU.TIMEZONE}`.

### Windows
1. Copy `zbx-windows-updates.ps1` to `C:\Program Files\Zabbix Agent 2\scripts\`.
2. Choose how the check runs:
   - **Zabbix agent**: add `AllowKey=system.run[*]` to `zabbix_agent2.conf` and restart the agent. The item *WU - Run update check* starts the script (every 12 h, and every 3 h on working days 07:00–17:00).
   - **Task Scheduler**: disable the item *WU - Run update check* and create a task, for example:
     ```powershell
     schtasks /Create /TN "Zabbix Windows Update check" /SC HOURLY /MO 3 /RU SYSTEM /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\Program Files\Zabbix Agent 2\scripts\zbx-windows-updates.ps1\""
     ```
3. Test it: `powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\Zabbix Agent 2\scripts\zbx-windows-updates.ps1"`. The update search can take a few minutes.

Script parameters: `-SenderPath`, `-ConfigPath` (agent config with `Hostname` and `ServerActive`), optionally `-ZabbixServer` and `-HostName`.

### Linux
1. Copy the script and make it executable:
   ```bash
   install -m 755 zbx-linux-updates.sh /usr/local/bin/zbx-linux-updates.sh
   ```
2. Run it from **cron as root** (recommended, root can refresh the package lists), for example `/etc/cron.d/zbx-linux-updates`:
   ```
   0 */3 * * * root /usr/local/bin/zbx-linux-updates.sh >/dev/null 2>&1
   ```
   Or enable the item *LU - Run update check* (Zabbix agent, `AllowKey=system.run[*]`). As the zabbix user the script can't refresh the package lists, so it uses the cached ones and doesn't send *repository availability*.
3. Test it: `/usr/local/bin/zbx-linux-updates.sh`

Settings via environment variables: `ZABBIX_SENDER`, `ZABBIX_CONF`, `ZABBIX_SERVER`, `ZABBIX_HOST`.

### Ansible (optional)
1. Copy `ansible/inventory.example.ini` to `inventory.ini` and fill in your hosts.
2. Set `zabbix_server` in the playbook (or with `-e zabbix_server=…`).
3. Run:
   ```bash
   ansible-galaxy collection install ansible.windows
   ansible-playbook -i inventory.ini ansible/patch-and-report.yml
   ansible-playbook -i inventory.ini ansible/patch-and-report.yml -e patch_reboot=false   # no automatic reboot
   ```
The playbook patches 25 % of the hosts at a time (`patch_serial`), reboots when needed (`patch_reboot`), sends the result to the *install* items and runs the check script again, so the dashboard shows the new state right away.

## Macros

| Macro | Default | Description |
|-------|---------|-------------|
| `{$WU.SCRIPT.PATH}` | `C:\Program Files\Zabbix Agent 2\scripts\zbx-windows-updates.ps1` | Windows check script path (agent option) |
| `{$WU.TIMEZONE}` | `Europe/Bratislava` | Time zone of the Windows hosts, used for the *age* items. **Set your own.** |
| `{$WU.TIMEZONE.CORRECTION}` | `3600` | Extra correction in seconds for the *age* items. Set `0` if the age is 1 hour off. |
| `{$WU.NODATA}` | `2d` | No data alert (Windows) |
| `{$LINUX.UPDATES.SCRIPT}` | `/usr/local/bin/zbx-linux-updates.sh` | Linux check script path (agent option) |
| `{$LINUX.UPDATES.NODATA}` | `2d` | No data alert (Linux) |
| `{$LINUX.UPDATES.INSTALL.MAXAGE}` | `45d` | Alert when no updates were installed for this time |

## Notes

- **Test on a few hosts first**, especially the Linux script and the Ansible playbook on your distributions and Windows versions.
- *Security* on Linux: on Debian / Ubuntu the packages from a `*-security` suite, on RHEL the packages with a security advisory (`updateinfo`).
- The Windows update categories are detected by their classification ID, so it works on Windows in any language.
- The patch day item (for example *2.Tue*) is stored in the host inventory field *Type* and used in the tag `UpdatePlan`, so you can filter problems and dashboards by patch window.

## Custom work & support

Need something extra? I can extend or customize this for your company's needs, for example the Windows install script, a patch management dashboard, maintenance windows, approval workflows, reporting or integration with WSUS, SCCM, Intune or AWX. Feel free to get in touch: 📧 [info@duprtech.sk](mailto:info@duprtech.sk)

If this saved you time and you're happy with my work, you can buy me a coffee ☕

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/duprtech)

## License

[MIT](LICENSE)
