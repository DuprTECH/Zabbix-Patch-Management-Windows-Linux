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
# Patch settings /etc/zabbix/zbx-patch.conf (created when missing, overwritten when one of
# these is set; see the comments in the file):
#   MAINTENANCE_WINDOW when updates may be installed, for example "Sun 02:00-05:00"
#                      (default: "* 03:00-05:00" - every night, never during the day)
#   EXCLUDE            packages that are not updated, for example "kernel*, docker-ce"
#   REBOOT             reboot after updates when needed: yes / no (default: yes)
#
#   sudo MAINTENANCE_WINDOW="Sat 22:00-04:00" EXCLUDE="docker-ce*" ./install-check-linux.sh
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
$MINUTE $HOURS * * * root$ENVS $DEST >/dev/null 2>&1
EOF
chmod 644 "$CRON"
echo "Cron $CRON: $MINUTE $HOURS * * * (every $INTERVAL_HOURS h)"

# 4. Patch settings: created when missing, overwritten when a setting is given
if [ ! -f "$CONF" ] || [ -n "${MAINTENANCE_WINDOW+x}${EXCLUDE+x}${REBOOT+x}" ]; then
    # Default window: every night 03:00-05:00, never during the day
    [ -z "${MAINTENANCE_WINDOW+x}" ] && MAINTENANCE_WINDOW="* 03:00-05:00"
    mkdir -p "$(dirname "$CONF")"
    cat > "$CONF" <<EOF
# zbx-patch.conf - patch management settings of this host
# Read by the check script zbx-patch-linux.sh (sent to Zabbix, template 'APP Patch management all OS')
# and by the install job (Ansible playbook, your update script, ...).
#
# Maintenance window - when updates may be installed and the host rebooted.
#   "<day> <HH:MM>-<HH:MM>", several separated by commas, local time of the host
#   day: Mon..Sun, a range Mon-Fri, * = every day, 2.Sat = 2nd Saturday of the month
#   an end lower than the start = the window ends the next day (Sat 22:00-04:00)
#   empty = any time
MAINTENANCE_WINDOW="$MAINTENANCE_WINDOW"

# Updates that are not installed, separated by commas: package names, wildcards allowed
#   EXCLUDE="kernel*, docker-ce"
EXCLUDE="${EXCLUDE:-}"

# Reboot after updates when needed: yes / no (no = the reboot is only reported to Zabbix)
REBOOT="${REBOOT:-yes}"
EOF
    chmod 644 "$CONF"
    echo "Patch settings $CONF: window '$MAINTENANCE_WINDOW', exclude '${EXCLUDE:-}', reboot ${REBOOT:-yes}"
else
    echo "Patch settings $CONF: kept (set MAINTENANCE_WINDOW / EXCLUDE / REBOOT to overwrite)"
fi

# 5. Run the check now
if [ "$RUN_NOW" = "1" ]; then
    echo "Running the check ..."
    env $ENVS "$DEST"
fi
