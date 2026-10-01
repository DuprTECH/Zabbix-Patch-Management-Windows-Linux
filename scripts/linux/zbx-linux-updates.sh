#!/bin/bash
# ----------------------------------------------------------------------------
# zbx-linux-updates.sh
# Checks pending package updates and sends the result to Zabbix with zabbix_sender.
#
# Supports apt (Debian / Ubuntu) and dnf / yum (RHEL / Rocky / Alma / Fedora / CentOS).
# Sends to the trapper items of template 'APP Linux updates check':
#   linux.updates.all, linux.updates.security, linux.updates.list (one package per line)
#   linux.updates.rebootrequired, linux.updates.repoavailability, linux.updates.pkgmanager
#   linux.updates.timestamp
#
# Run it as root from cron (recommended), for example /etc/cron.d/zbx-linux-updates:
#   0 */3 * * * root /usr/local/bin/zbx-linux-updates.sh >/dev/null 2>&1
#
# Settings (environment variables):
#   ZABBIX_SENDER   path to zabbix_sender          (default: zabbix_sender)
#   ZABBIX_CONF     agent config with Hostname / ServerActive
#                   (default: /etc/zabbix/zabbix_agent2.conf or zabbix_agentd.conf)
#   ZABBIX_SERVER   optional Zabbix server / proxy (instead of ServerActive)
#   ZABBIX_HOST     optional host name in Zabbix   (instead of Hostname)
#
# Author : Dusan Priechodsky
# Source : https://github.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux
# Contact: info@duprtech.sk
# License: MIT
# ----------------------------------------------------------------------------

ZABBIX_SENDER="${ZABBIX_SENDER:-zabbix_sender}"
if [ -z "$ZABBIX_CONF" ]; then
    for c in /etc/zabbix/zabbix_agent2.conf /etc/zabbix/zabbix_agentd.conf; do
        [ -f "$c" ] && ZABBIX_CONF="$c" && break
    done
fi

send() {
    local args=()
    [ -n "$ZABBIX_CONF" ]   && args+=(-c "$ZABBIX_CONF")
    [ -n "$ZABBIX_SERVER" ] && args+=(-z "$ZABBIX_SERVER")
    [ -n "$ZABBIX_HOST" ]   && args+=(-s "$ZABBIX_HOST")
    "$ZABBIX_SENDER" "${args[@]}" "$@"
}

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1

ALL=0
SECURITY=0
LIST=""
REBOOT=0
REPO=""        # empty = not checked (not root)
PKGMGR="unknown"

if command -v apt-get >/dev/null 2>&1; then
    # ---------------- Debian / Ubuntu ----------------
    PKGMGR="apt"
    if [ "$IS_ROOT" -eq 1 ]; then
        if apt-get update -qq >/dev/null 2>&1; then REPO=1; else REPO=0; fi
    fi
    # "Inst <package> [<old version>] (<new version> <suite> [<arch>])"
    INST=$(LANG=C apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | grep '^Inst ')
    if [ -n "$INST" ]; then
        ALL=$(printf '%s\n' "$INST" | wc -l)
        SECURITY=$(printf '%s\n' "$INST" | grep -ci 'security')
        LIST=$(printf '%s\n' "$INST" | sed -E 's/^Inst ([^ ]+) (\[[^]]*\] )?\(([^ ]+).*/\1 \3/')
    fi
    [ -f /var/run/reboot-required ] && REBOOT=1

elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    # ---------------- RHEL family ----------------
    if command -v dnf >/dev/null 2>&1; then PKGMGR="dnf"; else PKGMGR="yum"; fi
    OUT=$(LANG=C "$PKGMGR" -q check-update 2>/dev/null)
    RC=$?   # 100 = updates available, 0 = none, 1 = error
    if [ "$RC" -eq 1 ]; then REPO=0; else REPO=1; fi
    LIST=$(printf '%s\n' "$OUT" | awk 'NF==3 && $1 !~ /^(Obsoleting|Security:|Last)/ {print $1" "$2}')
    [ -n "$LIST" ] && ALL=$(printf '%s\n' "$LIST" | wc -l)
    SECURITY=$(LANG=C "$PKGMGR" -q updateinfo list --security 2>/dev/null | awk 'NF>=3' | wc -l)
    # needs-restarting -r: exit 1 = reboot required (dnf-utils / yum-utils)
    if command -v needs-restarting >/dev/null 2>&1; then
        needs-restarting -r >/dev/null 2>&1; [ $? -eq 1 ] && REBOOT=1
    elif [ "$PKGMGR" = "dnf" ]; then
        dnf needs-restarting -r >/dev/null 2>&1; [ $? -eq 1 ] && REBOOT=1
    fi
else
    echo "No supported package manager found (apt, dnf, yum)." >&2
fi

[ -z "$LIST" ] && LIST="No pending updates"

TMP=$(mktemp)
{
    echo "- linux.updates.all $ALL"
    echo "- linux.updates.security $SECURITY"
    echo "- linux.updates.rebootrequired $REBOOT"
    echo "- linux.updates.pkgmanager $PKGMGR"
    echo "- linux.updates.timestamp $(date +%s)"
    [ -n "$REPO" ] && echo "- linux.updates.repoavailability $REPO"
} > "$TMP"
send -i "$TMP"
rm -f "$TMP"

# The list of updates (multi-line text) is sent separately
send -k linux.updates.list -o "$LIST"

echo "Pending updates: $ALL (security $SECURITY), reboot required: $REBOOT, package manager: $PKGMGR"
exit 0
