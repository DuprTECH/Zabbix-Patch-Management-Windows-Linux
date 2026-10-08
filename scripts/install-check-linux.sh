#!/bin/bash
# ----------------------------------------------------------------------------
# install-check-linux.sh
# Check only (no updates are installed): installs the check script zbx-patch-linux.sh,
# runs it by cron every N hours and runs it once now, so Zabbix (template
# 'APP Patch management all OS') gets the update status of this host.
#
# Use it when you only want the reporting (updates are installed by another tool,
# unattended-upgrades / dnf-automatic or by hand), or to run the check more often
# than your install job.
#
#   sudo ./install-check-linux.sh
#   sudo INTERVAL_HOURS=4 ./install-check-linux.sh
#   curl -fsSL https://raw.githubusercontent.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux/main/scripts/install-check-linux.sh | sudo bash
#
# Settings (environment variables):
#   INTERVAL_HOURS     check interval in hours, a divisor of 24 (default: 12)
#                      the time is shifted by a fixed per-host offset of -30..+30 min,
#                      so the hosts don't run at the same time
#   RUN_NOW=0          install only, don't run the check now
#   INSTALL_SENDER=0   don't install the package zabbix-sender when it's missing
#   ZABBIX_SERVER      optional Zabbix server / proxy for the check (instead of ServerActive)
#   ZABBIX_HOST        optional host name in Zabbix (instead of Hostname / uname -n)
#
# Patch settings /etc/zabbix/zbx-patch.conf (written every time: values already in the file are
# kept unless given here, missing settings get the defaults; see the comments in the file):
#   MAINTENANCE_WINDOW when updates may be installed, for example "3 03:00-05:00" (Wednesday)
#                      (default: "* 03:00-05:00" - every night, never during the day)
#   AUTO_UPDATE        true = the check script installs the updates in the window (default: false)
#   EXCLUDE            packages that are not updated, for example "kernel*, docker-ce"
#   REBOOT             reboot after updates when needed: yes / no (default: yes)
#
#   sudo MAINTENANCE_WINDOW="3 03:00-05:00" AUTO_UPDATE=true ./install-check-linux.sh
#
# Running it again updates an existing installation (script, cron, new settings).
#
# Uses zbx-patch-linux.sh from the same folder, or downloads it from GitHub.
#
# Author : Dusan Priechodsky
# Source : https://github.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux
# Contact: info@duprtech.sk
# License: MIT
# ----------------------------------------------------------------------------
set -e

INTERVAL_HOURS="${INTERVAL_HOURS:-12}"
RUN_NOW="${RUN_NOW:-1}"
INSTALL_SENDER="${INSTALL_SENDER:-1}"
URL="https://raw.githubusercontent.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux/main/scripts/zbx-patch-linux.sh"
DEST=/usr/local/bin/zbx-patch-linux.sh
CRON=/etc/cron.d/zbx-patch-linux
CONF=/etc/zabbix/zbx-patch.conf

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 1; }
case "$INTERVAL_HOURS" in 1|2|3|4|6|8|12|24) ;; *) echo "INTERVAL_HOURS must be a divisor of 24." >&2; exit 1 ;; esac

# 1. Check script: local copy next to this script, or download
SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)
if [ -f "$SRC_DIR/zbx-patch-linux.sh" ]; then
    install -m 755 "$SRC_DIR/zbx-patch-linux.sh" "$DEST"
elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "$URL" -o "$DEST" && chmod 755 "$DEST"
else
    wget -qO "$DEST" "$URL" && chmod 755 "$DEST"
fi
echo "Installed $DEST"

# 2. zabbix_sender
if ! command -v zabbix_sender >/dev/null 2>&1 && [ "$INSTALL_SENDER" = "1" ]; then
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zabbix-sender >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q zabbix-sender >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q zabbix-sender >/dev/null 2>&1 || true
    fi
fi
command -v zabbix_sender >/dev/null 2>&1 \
    || echo "WARNING: zabbix_sender is not installed - install the package zabbix-sender (Zabbix repository)." >&2

# 3. Cron: every INTERVAL_HOURS, shifted by a per-host offset of -30..+30 min
OFFSET=$(( $(uname -n | cksum | cut -d' ' -f1) % 61 - 30 ))
MINUTE=$(( (OFFSET + 60) % 60 ))
SHIFT=0; [ "$OFFSET" -lt 0 ] && SHIFT=-1
HOURS=""
for (( h = 0; h < 24; h += INTERVAL_HOURS )); do
    HOURS="${HOURS:+$HOURS,}$(( (h + SHIFT + 24) % 24 ))"
done
ENVS=""
[ -n "$ZABBIX_SERVER" ] && ENVS="$ENVS ZABBIX_SERVER=$ZABBIX_SERVER"
[ -n "$ZABBIX_HOST" ]   && ENVS="$ENVS ZABBIX_HOST=$ZABBIX_HOST"
cat > "$CRON" <<EOF
# Zabbix patch check (template 'APP Patch management all OS') - installed by install-check-linux.sh
# check every $INTERVAL_HOURS h, check after a reboot, automatic update (AUTO_UPDATE="true" in $CONF) every 15 min
$MINUTE $HOURS * * * root$ENVS $DEST >/dev/null 2>&1
@reboot root sleep 300;$ENVS $DEST >/dev/null 2>&1
*/15 * * * * root$ENVS $DEST --auto-update >>/var/log/zbx-patch-update.log 2>&1
EOF
chmod 644 "$CRON"
echo "Cron $CRON: check $MINUTE $HOURS * * * (every $INTERVAL_HOURS h) and after a reboot, auto update every 15 min"

# 4. Patch settings: written every time - the values already in the file are kept (unless given
#    here), missing settings are added with the defaults
cur() {
    [ -f "$CONF" ] && grep -qE "^[[:space:]]*$1[[:space:]]*=" "$CONF" || return 1
    sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"#]*)\"?.*/\1/p" "$CONF" | tail -n 1 | sed 's/[[:space:]]*$//'
}
[ -n "${MAINTENANCE_WINDOW+x}" ] || MAINTENANCE_WINDOW=$(cur MAINTENANCE_WINDOW) || MAINTENANCE_WINDOW="* 03:00-05:00"
[ -n "${AUTO_UPDATE+x}" ]        || AUTO_UPDATE=$(cur AUTO_UPDATE)               || AUTO_UPDATE="false"
[ -n "${EXCLUDE+x}" ]            || EXCLUDE=$(cur EXCLUDE)                       || EXCLUDE=""
[ -n "${REBOOT+x}" ]             || REBOOT=$(cur REBOOT)                         || REBOOT="yes"
mkdir -p "$(dirname "$CONF")"
cat > "$CONF" <<EOF
# zbx-patch.conf - patch management settings of this host
# Read by the check script zbx-patch-linux.sh (sent to Zabbix, template 'APP Patch management all OS')
# and by the install job (Ansible playbook, your update script, ...).
#
# Maintenance window - when updates may be installed and the host rebooted.
#   "<day> <HH:MM>-<HH:MM>", several separated by commas, local time of the host
#   day: 1-7 = Monday-Sunday (or Mon..Sun), a range 1-5, * = every day, 2.3 = 2nd Wednesday of the month
#   an end lower than the start = the window ends the next day (6 22:00-04:00)
#   empty = any time
#   MAINTENANCE_WINDOW="3 03:00-05:00"   = every Wednesday 03:00-05:00
MAINTENANCE_WINDOW="$MAINTENANCE_WINDOW"

# Automatic updates: true = the check script installs the updates itself in the maintenance window
# (cron every 15 min, once per window, log /var/log/zbx-patch-update.log); false = check only
AUTO_UPDATE="$AUTO_UPDATE"

# Updates that are not installed, separated by commas: package names, wildcards allowed
#   EXCLUDE="kernel*, docker-ce"
EXCLUDE="$EXCLUDE"

# Reboot after updates when needed: yes / no (no = the reboot is only reported to Zabbix)
REBOOT="$REBOOT"
EOF
chmod 644 "$CONF"
echo "Patch settings $CONF: window '$MAINTENANCE_WINDOW', auto update $AUTO_UPDATE, exclude '$EXCLUDE', reboot $REBOOT"

# 5. Run the check now
if [ "$RUN_NOW" = "1" ]; then
    echo "Running the check ..."
    env $ENVS "$DEST"
fi
