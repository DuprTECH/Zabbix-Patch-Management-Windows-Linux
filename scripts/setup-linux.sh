#!/bin/bash
# setup-linux.sh - Zabbix patch management on a Linux server without Ansible: setup, check, updates
#
# Paste the whole file into a root shell (sudo -i), or run it as a file: sudo bash setup-linux.sh
# or straight from GitHub (no terminal = menu choice 1, settings kept / defaults):
#   curl -fsSL https://raw.githubusercontent.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux/main/scripts/setup-linux.sh | sudo bash
# A menu asks what to do (or MODE=update bash setup-linux.sh):
#   1 monitor  = like ansible/check-linux.yml: checker zbx-patch-linux.sh, zabbix-sender, cron (check every
#                12 h and after a reboot, automatic update every 15 min), patch settings /etc/zabbix/zbx-patch.conf,
#                UserParameter patch.config (host macros {$PATCH.CONF.*}), first check. Running it again updates an installed server and keeps the settings.
#   2 check    = run the update check now (pending updates -> Zabbix) and show the patch settings
#   3 update   = install updates now in the maintenance window,
#                without EXCLUDE packages, reboot when needed and REBOOT="yes", result to Zabbix
#   4 force    = like 3, also outside the maintenance window
#
# AUTO_UPDATE="false" in zbx-patch.conf (default) = the checker only checks; "true" = it installs the
# updates itself in the maintenance window (once per window, like 3).
#
# The checker zbx-patch-linux.sh is embedded (no internet needed); a copy in /tmp/zbx-patch-linux.sh wins.
# Supported: apt (Debian / Ubuntu), dnf / yum (RHEL / Rocky / Alma / Oracle / CentOS).
# Docs: README.md (https://github.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux)
#
# Author : Dusan Priechodsky
# Source : https://github.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux
# Contact: info@duprtech.sk
# License: MIT
(
MODE="${MODE:-}"                  # monitor | check | update | force, empty = menu
INTERVAL_HOURS="${INTERVAL_HOURS:-12}"
DEFAULT_WINDOW="* 03:00-05:00"    # maintenance window of a new zbx-patch.conf: every night, never during the day

CHECK=/usr/local/bin/zbx-patch-linux.sh
CRON=/etc/cron.d/zbx-patch-linux
CONF=/etc/zabbix/zbx-patch.conf

warn() { echo "WARNING: $*" >&2; }

# ask <question> <default> -> REPLY (default without a terminal)
ask() {
    local a=""
    [ -t 0 ] && read -r -p "$1 [$2]: " a
    REPLY="${a:-$2}"
}

# Value from the patch settings JSON (zbx-patch-linux.sh --show-config)
json_get() { printf '%s' "$CFG" | sed -n "s/.*\"$1\": \(\"[^\"]*\"\|[a-z0-9]*\).*/\1/p" | sed 's/^"//; s/"$//'; }

if [ "$(id -u)" -ne 0 ]; then echo "Run as root (sudo -i)." >&2; exit 1; fi
PM=""
for p in apt-get dnf yum; do command -v $p >/dev/null 2>&1 && { PM=$p; break; }; done
[ -n "$PM" ] || { echo "Unsupported package manager (apt, dnf, yum)." >&2; exit 1; }

# ---------------- Checker ----------------
# The checker is embedded before the menu (no internet needed); a newer copy in
# /tmp/zbx-patch-linux.sh is used instead
get_check() {
    local tmp="$CHECK.new" src="embedded"
    if [ -f /tmp/zbx-patch-linux.sh ]; then cp /tmp/zbx-patch-linux.sh "$tmp"; src=/tmp/zbx-patch-linux.sh
    else printf '%s' "$CHECK_B64" | base64 -d 2>/dev/null | gunzip > "$tmp" 2>/dev/null; fi
    if ! grep -q -- '--auto-update' "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        echo "ERROR: the checker ($src) is damaged or old - copy zbx-patch-linux.sh to /tmp/zbx-patch-linux.sh and run again." >&2
        return 1
    fi
    install -m 755 "$tmp" "$CHECK" && rm -f "$tmp"
    echo "Checker: $CHECK ($src)"
}

checker_ok() { [ -x "$CHECK" ] && grep -q -- '--auto-update' "$CHECK"; }

show_config() {
    CFG=$("$CHECK" --show-config)
    local next
    next=$(json_get maintenance_next)
    echo "Maintenance window: $(json_get maintenance_window | sed 's/^$/- (any time)/')$( [ "$(json_get maintenance_active)" = true ] && echo ' - open now')"
    [ -n "$(json_get maintenance_error)" ] && echo "  ERROR: $(json_get maintenance_error)"
    echo "Next window:        $( [ "$next" != null ] && date -d "@$next" '+%Y-%m-%d %H:%M' || echo -)"
    echo "Auto update:        $(json_get auto_update)"
    echo "Excluded:           $(printf '%s' "$CFG" | sed -n 's/.*"exclude": \[\([^]]*\)\].*/\1/p' | tr -d '"' | sed 's/^$/-/')"
    echo "Reboot allowed:     $(json_get reboot_allowed)"
}

# ---------------- 1. Monitor: checker, cron, patch settings ----------------
monitor() {
    echo "=== Update checker for Zabbix"
    get_check || return 1
    if ! command -v zabbix_sender >/dev/null 2>&1; then
        if [ "$PM" = apt-get ]; then DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zabbix-sender >/dev/null 2>&1
        else $PM install -y -q zabbix-sender >/dev/null 2>&1; fi
        command -v zabbix_sender >/dev/null 2>&1 || warn "zabbix_sender is not installed - install the package zabbix-sender (Zabbix repository)."
    fi
    # Check every INTERVAL_HOURS (shifted by a per-host offset of -30..+30 min) and after a reboot,
    # automatic update every 15 min (installs only with AUTO_UPDATE="true", in the maintenance window)
    local offset minute shift hours h keep win auto excl reboot
    offset=$(( $(uname -n | cksum | cut -d' ' -f1) % 61 - 30 ))
    minute=$(( (offset + 60) % 60 )); shift=0; [ "$offset" -lt 0 ] && shift=-1
    hours=""
    for (( h = 0; h < 24; h += INTERVAL_HOURS )); do
        hours="${hours:+$hours,}$(( (h + shift + 24) % 24 ))"
    done
    rm -f /etc/cron.d/zbx-patch-linux-afterboot
    cat > "$CRON" <<EOF
# Zabbix patch check (template 'APP Patch management all OS') - installed by setup-linux.sh
# check every $INTERVAL_HOURS h, check after a reboot, automatic update (AUTO_UPDATE="true" in $CONF) every 15 min
$minute $hours * * * root $CHECK >/dev/null 2>&1
@reboot root sleep 300; $CHECK >/dev/null 2>&1
*/15 * * * * root $CHECK --auto-update >>/var/log/zbx-patch-update.log 2>&1
EOF
    chmod 644 "$CRON"
    echo "Cron $CRON: check $minute $hours * * * and after a reboot, auto update every 15 min"
    # Patch settings: the values already in the file are kept, new settings get the defaults;
    # the file is written every time, so new settings are added to an existing file
    cur() { [ -f "$CONF" ] && grep -qE "^[[:space:]]*$1[[:space:]]*=" "$CONF" || return 1
            sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"#]*)\"?.*/\1/p" "$CONF" | tail -n 1 | sed 's/[[:space:]]*$//'; }
    win=$(cur MAINTENANCE_WINDOW)  || win=$DEFAULT_WINDOW
    auto=$(cur AUTO_UPDATE)        || auto=false
    excl=$(cur EXCLUDE)            || excl=""
    reboot=$(cur REBOOT)           || reboot=yes
    keep=n
    if [ -f "$CONF" ]; then
        echo "Patch settings $CONF:"
        printf '  MAINTENANCE_WINDOW="%s"\n  AUTO_UPDATE="%s"\n  EXCLUDE="%s"\n  REBOOT="%s"\n' "$win" "$auto" "$excl" "$reboot"
        ask "Keep them? (y/n)" y; keep=$REPLY
    fi
    case "$keep" in
        [Yy]*) ;;
        *)
            echo "Maintenance window: '<day> <HH:MM>-<HH:MM>', several separated by commas; day 1-7 = Monday-Sunday"
            echo "  (or Mon..Sun), 1-5, * = every day, 2.3 = 2nd Wednesday; '-' = any time. Example: 3 03:00-05:00 = Wednesday"
            ask "Maintenance window" "${win:--}"; win=$REPLY; [ "$win" = "-" ] && win=""
            ask "Automatic updates in the maintenance window (true/false)" "$auto"; auto=$REPLY
            ask "Excluded packages, comma separated, wildcards allowed ('-' = none)" "${excl:--}"; excl=$REPLY; [ "$excl" = "-" ] && excl=""
            ask "Reboot after updates when needed (yes/no)" "$reboot"; reboot=$REPLY
            ;;
    esac
    mkdir -p "$(dirname "$CONF")"
    cat > "$CONF" <<EOF
# zbx-patch.conf - patch management settings of this host
# Read by the checker zbx-patch-linux.sh (sent to Zabbix, template 'APP Patch management all OS')
# and by setup-linux.sh (update). Written by setup-linux.sh -
# you can edit it, the values are kept when the setup runs again.
#
# Maintenance window - when updates may be installed and the host rebooted.
#   "<day> <HH:MM>-<HH:MM>", several separated by commas, local time of the host
#   day: 1-7 = Monday-Sunday (or Mon..Sun), a range 1-5, * = every day, 2.3 = 2nd Wednesday of the month
#   an end lower than the start = the window ends the next day (6 22:00-04:00)
#   empty = any time
#   MAINTENANCE_WINDOW="3 03:00-05:00"   = every Wednesday 03:00-05:00
MAINTENANCE_WINDOW="$win"

# Automatic updates: true = the checker installs the updates itself in the maintenance window
# (cron every 15 min, once per window, log /var/log/zbx-patch-update.log); false = check only
AUTO_UPDATE="$auto"

# Updates that are not installed, separated by commas: package names, wildcards allowed
#   EXCLUDE="kernel*, docker-ce"
EXCLUDE="$excl"

# Reboot after updates when needed: yes / no (no = the reboot is only reported to Zabbix)
REBOOT="$reboot"
EOF
    chmod 644 "$CONF"
    echo "Saved $CONF"
    # Settings from Zabbix: UserParameter patch.config (host macros {$PATCH.CONF.*} -> zbx-patch-from-zbx-host-macro.cache),
    # the agent is restarted only when its config changed (undone when it doesn't start)
    echo "=== Zabbix agent: UserParameter patch.config (settings from the host macros)"
    "$CHECK" --install-agent-config || warn "UserParameter not installed - the host macros {\$PATCH.CONF.*} don't apply on this host"
    run_check
}

# ---------------- 2. Check now ----------------
run_check() {
    checker_ok || { echo "The checker is not installed (or old) - choose 1 (monitor) first." >&2; return 1; }
    echo "=== Patch settings"
    show_config
    echo "=== Update check (sends to Zabbix)"
    "$CHECK"
}

# ---------------- 3. / 4. Install updates now (the checker does it: --update [--force]) ----------------
update() {
    if ! checker_ok; then
        echo "The update checker is not installed (or old) - installing it first."
        monitor || return 1
    fi
    echo "=== Patch settings"
    show_config
    if [ "$1" = 1 ]; then "$CHECK" --update --force; else "$CHECK" --update; fi
}

# Embedded check script: zbx-patch-linux.sh from DuprTECH/Zabbix-Patch-Management-Windows-Linux 20cfdb9 (embed-check.sh)
CHECK_B64='
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
3MO8OWjwfwGlqF2siakAAA==
'
#
# ---------------- Menu ----------------
if [ -z "$MODE" ]; then
    echo "Zabbix patch management - $(uname -n)"
    echo "  1) monitor - install / update the checker for Zabbix (cron, zbx-patch.conf incl. AUTO_UPDATE)"
    echo "  2) check   - run the update check now"
    echo "  3) update  - install updates (only in the maintenance window)"
    echo "  4) force   - install updates now (also outside the maintenance window)"
    ask "Choose" 1
    MODE=$REPLY
fi
case "$MODE" in
    1|monitor) monitor ;;
    2|check)   run_check ;;
    3|update)  update 0 ;;
    4|force)   update 1 ;;
    *) echo "Unknown choice: $MODE" >&2; exit 1 ;;
esac
)
