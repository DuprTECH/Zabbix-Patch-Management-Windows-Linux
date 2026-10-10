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

# Embedded check script: zbx-patch-linux.sh from DuprTECH/Zabbix-Patch-Management-Windows-Linux 098b49e (embed-check.sh)
CHECK_B64='
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
guS0wB3Mm6MG/xeUb7+utKUAAA==
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
