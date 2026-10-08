#!/bin/bash
# ----------------------------------------------------------------------------
# zbx-patch-linux.sh
# Checks pending package updates on Linux and sends the result to Zabbix with
# zabbix_sender, to the OS independent template 'APP Patch management all OS'
# (keys patch.*, the same keys as zbx-patch-windows.ps1 on Windows).
#
# Supports apt (Debian / Ubuntu) and dnf / yum (RHEL / Rocky / Alma / Oracle / Fedora / CentOS).
#
# Values that don't exist on Linux (definition, service packs, update rollups, drivers,
# upgrades) are sent as 0. Values that can't be determined (severity and bugfix /
# enhancement on apt, repository availability when not root) are not sent.
#
# Run it as root from cron (recommended), for example /etc/cron.d/zbx-patch-linux:
#   0 */3 * * * root /usr/local/bin/zbx-patch-linux.sh >/dev/null 2>&1
#
# Settings (environment variables):
#   ZABBIX_SENDER   path to zabbix_sender          (default: zabbix_sender)
#   ZABBIX_CONF     agent config with Hostname / ServerActive
#                   (default: /etc/zabbix/zabbix_agent2.conf or zabbix_agentd.conf)
#   ZABBIX_SERVER   optional Zabbix server / proxy (instead of ServerActive)
#   ZABBIX_HOST     optional host name in Zabbix   (instead of Hostname; default uname -n
#                   when the config has no Hostname, for example HostnameItem=system.hostname)
#   HISTORY_LINES   number of lines in the update history item (default: 50)
#   PATCH_CONF      patch settings of the host (default: /etc/zabbix/zbx-patch.conf)
#
# Patch settings (PATCH_CONF, optional, the same file format on Windows):
#   MAINTENANCE_WINDOW="3 03:00-05:00"     when updates may be installed and the host rebooted
#                                          (day: 1-7 = Mon-Sun or Mon..Sun, 1-5, *, 2.3 = 2nd Wednesday)
#   AUTO_UPDATE="false"                    true = this script installs the updates itself in the
#                                          maintenance window (--auto-update from cron), false = check only
#   EXCLUDE="kernel*, docker-ce"           packages that are not updated (wildcards allowed)
#   REBOOT="yes"                           reboot after updates when needed (no = report only)
# They are sent to Zabbix (patch.maintenance.*, patch.exclude, patch.updates.excluded,
# patch.reboot.allowed, patch.autoupdate) and read by the install job (Ansible) with --show-config.
#
# Options:
#   --show-config   print the patch settings as JSON (window active now, next window,
#                   exclusions, reboot, auto update) and exit - nothing is checked or sent
#   --update        install the updates now (apt / dnf / yum, without EXCLUDE), only in the
#                   maintenance window (with --force also outside), send the result to Zabbix
#                   (patch.install.*), reboot when needed and REBOOT="yes", then check
#   --auto-update   for cron (every 15 min): with AUTO_UPDATE="true" and an open maintenance
#                   window does --update once per window, otherwise exits right away
#                   (log: /var/log/zbx-patch-update.log via cron)
#
# Author : Dusan Priechodsky
# Source : https://github.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux
# Contact: info@duprtech.sk
# License: MIT
# ----------------------------------------------------------------------------

ZABBIX_SENDER="${ZABBIX_SENDER:-zabbix_sender}"
HISTORY_LINES="${HISTORY_LINES:-50}"
if [ -z "$ZABBIX_CONF" ]; then
    for c in /etc/zabbix/zabbix_agent2.conf /etc/zabbix/zabbix_agentd.conf; do
        [ -f "$c" ] && ZABBIX_CONF="$c" && break
    done
fi

# Host name: zabbix_sender takes Hostname from the agent config, but it can't resolve
# HostnameItem (for example HostnameItem=system.hostname). Without Hostname in the config
# (or its Include files) send the name of system.hostname, that is uname -n.
if [ -z "$ZABBIX_HOST" ] && [ -n "$ZABBIX_CONF" ]; then
    CONF_FILES="$ZABBIX_CONF"
    for inc in $(sed -n 's/^Include=//p' "$ZABBIX_CONF"); do
        [ -d "$inc" ] && inc="$inc/*"
        CONF_FILES="$CONF_FILES $inc"
    done
    # shellcheck disable=SC2086
    grep -hqs '^Hostname=' $CONF_FILES || ZABBIX_HOST=$(uname -n)
fi

send() {
    local args=()
    [ -n "$ZABBIX_CONF" ]   && args+=(-c "$ZABBIX_CONF")
    [ -n "$ZABBIX_SERVER" ] && args+=(-z "$ZABBIX_SERVER")
    [ -n "$ZABBIX_HOST" ]   && args+=(-s "$ZABBIX_HOST")
    "$ZABBIX_SENDER" "${args[@]}" "$@"
}

# Quoted value for the zabbix_sender input file
q() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

# Patch day of a unix timestamp, for example 2.Tue (2nd Tuesday of the month)
patchday() {
    local d
    d=$(date -d "@$1" +%-d)
    echo "$(( (d - 1) / 7 + 1 )).$(LC_ALL=C date -d "@$1" +%a)"
}

# ---------------- Patch settings (zbx-patch.conf) ----------------
PATCH_CONF="${PATCH_CONF:-/etc/zabbix/zbx-patch.conf}"

# Value of KEY="value" (also 'value' or value # comment); the last one wins
conf_get() {
    [ -r "$PATCH_CONF" ] || return 0
    local v
    v=$(sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$PATCH_CONF" | tail -n 1)
    case "$v" in
        \"*) v=${v#\"}; v=${v%%\"*} ;;
        \'*) v=${v#\'}; v=${v%%\'*} ;;
        *)   v=${v%%#*} ;;
    esac
    printf '%s' "$v"
}

trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

MAINTENANCE_WINDOW=$(trim "$(conf_get MAINTENANCE_WINDOW)")
EXCLUDE=$(trim "$(conf_get EXCLUDE)")
REBOOT_ALLOWED=1
case "$(trim "$(conf_get REBOOT)" | tr '[:upper:]' '[:lower:]')" in no|false|0|off) REBOOT_ALLOWED=0 ;; esac
AUTO_UPDATE=0
case "$(trim "$(conf_get AUTO_UPDATE)" | tr '[:upper:]' '[:lower:]')" in yes|true|1|on) AUTO_UPDATE=1 ;; esac

# Exclusions: comma separated package names, wildcards allowed
EXCL=()
IFS=',' read -ra _excl <<< "$EXCLUDE"
for p in "${_excl[@]}"; do p=$(trim "$p"); [ -n "$p" ] && EXCL+=("$p"); done

is_excluded() {
    local p
    for p in "${EXCL[@]}"; do
        # shellcheck disable=SC2053
        [[ $1 == $p ]] && return 0
    done
    return 1
}

# Day of a maintenance window: 3 or Wed (1 = Monday ... 7 = Sunday), a range 1-5 / Mon-Fri,
# * (every day), 2.3 / 2.Wed (2nd Wednesday of the month)
DAYS=(mon tue wed thu fri sat sun)
day_num() {
    local i
    case "$1" in [1-7]) echo "$1"; return 0 ;; esac
    for i in 0 1 2 3 4 5 6; do [ "${DAYS[$i]}" = "${1,,}" ] && { echo $(( i + 1 )); return 0; }; done
    return 1
}
# day_match <day spec> <day of week 1-7> <day of month>: 0 match, 1 no match, 2 invalid spec
day_match() {
    local a b
    case "$1" in
        '*') return 0 ;;
        [1-5].*)
            a=$(day_num "${1#*.}") || return 2
            [ "$2" -eq "$a" ] && [ $(( ($3 - 1) / 7 + 1 )) -eq "${1%%.*}" ] ;;
        *-*)
            a=$(day_num "${1%-*}") || return 2
            b=$(day_num "${1#*-}") || return 2
            if [ "$a" -le "$b" ]; then [ "$2" -ge "$a" ] && [ "$2" -le "$b" ]
            else [ "$2" -ge "$a" ] || [ "$2" -le "$b" ]; fi ;;
        *)
            a=$(day_num "$1") || return 2
            [ "$2" -eq "$a" ] ;;
    esac
}

# Maintenance window "<day> <HH:MM>-<HH:MM>, ..." (an end lower than the start = the next day)
# Sets MAINT_ACTIVE (0 / 1), MAINT_START (start of the open window), MAINT_NEXT (start of the
# next window, unix time) and MAINT_ERROR
maint_eval() {
    MAINT_ACTIVE=0; MAINT_START=""; MAINT_NEXT=""; MAINT_ERROR=""
    [ -z "$MAINTENANCE_WINDOW" ] && return 0
    local w spec range extra now base d dow dom day0 s e i
    local -a wins specs starts ends
    local re='^([01]?[0-9]|2[0-3]):([0-5][0-9])-([01]?[0-9]|2[0-3]):([0-5][0-9])$'
    IFS=',' read -ra wins <<< "$MAINTENANCE_WINDOW"
    for w in "${wins[@]}"; do
        read -r spec range extra <<< "$w"
        [ -z "$spec" ] && continue
        day_match "$spec" 1 1; [ $? -eq 2 ] && spec=""
        if [ -z "$spec" ] || [ -n "$extra" ] || ! [[ $range =~ $re ]]; then
            [ -z "$MAINT_ERROR" ] && MAINT_ERROR="invalid maintenance window '$(trim "$w")'"
            continue
        fi
        specs+=("$spec")
        starts+=($(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} )))
        ends+=($(( 10#${BASH_REMATCH[3]} * 60 + 10#${BASH_REMATCH[4]} )))
    done
    now=$(date +%s); base=$(date +%F)
    for d in $(seq -1 62); do
        read -r dow dom day0 <<< "$(date -d "$base $d day" '+%u %-d %s')"
        [ -n "$MAINT_NEXT" ] && [ "$day0" -gt "$MAINT_NEXT" ] && break
        for i in "${!specs[@]}"; do
            day_match "${specs[$i]}" "$dow" "$dom" || continue
            s=$(( day0 + starts[i] * 60 )); e=$(( day0 + ends[i] * 60 ))
            [ "$e" -le "$s" ] && e=$(( e + 86400 ))
            [ "$now" -ge "$s" ] && [ "$now" -lt "$e" ] && { MAINT_ACTIVE=1; MAINT_START=$s; }
            if [ "$s" -gt "$now" ] && { [ -z "$MAINT_NEXT" ] || [ "$s" -lt "$MAINT_NEXT" ]; }; then MAINT_NEXT=$s; fi
        done
    done
}
maint_eval

MODE=check; FORCE=0
for a in "$@"; do
    case "$a" in
        --show-config) MODE=show ;;
        --update)      MODE=update ;;
        --auto-update) MODE=auto ;;
        --force)       FORCE=1 ;;
    esac
done
tf() { [ "$1" -eq 1 ] && echo true || echo false; }

if [ "$MODE" = show ]; then
    printf '{"config": %s, "config_found": %s, "maintenance_window": %s, "maintenance_active": %s, ' \
        "$(q "$PATCH_CONF")" "$([ -r "$PATCH_CONF" ] && echo true || echo false)" \
        "$(q "$MAINTENANCE_WINDOW")" "$(tf "$MAINT_ACTIVE")"
    printf '"maintenance_next": %s, "maintenance_error": %s, "exclude": [' "${MAINT_NEXT:-null}" "$(q "$MAINT_ERROR")"
    sep=""; for p in "${EXCL[@]}"; do printf '%s%s' "$sep" "$(q "$p")"; sep=", "; done
    printf '], "reboot_allowed": %s, "auto_update": %s}\n' "$(tf "$REBOOT_ALLOWED")" "$(tf "$AUTO_UPDATE")"
    exit 0
fi

# --auto-update (cron every 15 min): only with AUTO_UPDATE="true", in an open window, once per window
STAMP=/var/lib/zbx-patch/last-auto-update
if [ "$MODE" = auto ]; then
    [ "$AUTO_UPDATE" -eq 1 ] && [ "$MAINT_ACTIVE" -eq 1 ] || exit 0
    [ "$(cat "$STAMP" 2>/dev/null || echo 0)" -ge "$MAINT_START" ] 2>/dev/null && exit 0
    mkdir -p "$(dirname "$STAMP")" && date +%s > "$STAMP"
    echo "=== $(date '+%Y-%m-%d %H:%M') automatic update in the maintenance window '$MAINTENANCE_WINDOW'"
    MODE=update; FORCE=1
fi
[ -n "$MAINT_ERROR" ] && echo "WARNING: $PATCH_CONF: $MAINT_ERROR" >&2

# One run at a time (check, update and cron can overlap; apt / dnf need the lock too)
{ exec 9>/run/zbx-patch-linux.lock; } 2>/dev/null && command -v flock >/dev/null 2>&1 && flock -w 1800 9

# ---------------- Install updates (--update) ----------------
# Like the Ansible playbook: refresh, upgrade without EXCLUDE, autoremove, reboot when needed
# and allowed; the result goes to the patch.install.* items
do_update() {
    local pm="" need=0 rc=0 err="" changes count result doreboot=0 p n held_now newest
    local -a held=() x=()
    local w
    for p in apt-get dnf yum; do command -v $p >/dev/null 2>&1 && { pm=$p; break; }; done
    if [ -z "$pm" ]; then echo "ERROR: --update supports apt, dnf and yum" >&2; return 1; fi
    if [ -n "$MAINTENANCE_WINDOW" ] && [ "$MAINT_ACTIVE" -ne 1 ] && [ "$FORCE" -ne 1 ]; then
        echo "SKIPPED: outside the maintenance window '$MAINTENANCE_WINDOW'${MAINT_ERROR:+ ($MAINT_ERROR)}, next window: $( [ -n "$MAINT_NEXT" ] && date -d "@$MAINT_NEXT" '+%Y-%m-%d %H:%M' || echo -). Install now with --force."
        return 2
    fi
    w=$(mktemp -d)
    snap() {
        if [ "$pm" = apt-get ]; then
            dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package} ${Version}\n' | awk '$1 ~ /^ii/ {print $2" "$3}'
        else
            rpm -qa --qf '%{NAME}.%{ARCH} %{EPOCHNUM}:%{VERSION}-%{RELEASE}\n'
        fi | sort
    }
    snap > "$w/before"
    echo "=== Installing updates ($pm)${EXCL[0]:+, excluded: ${EXCL[*]}}"
    if [ "$pm" = apt-get ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q || { rc=1; err="apt-get update failed"; }
        # apt has no exclude: hold the excluded packages for the upgrade, release them afterwards
        if [ ${#EXCL[@]} -gt 0 ]; then
            held_now=$(apt-mark showhold)
            for p in "${EXCL[@]}"; do
                for n in $(dpkg-query -W -f='${Package}\n' "$p" 2>/dev/null | sort -u); do
                    printf '%s\n' "$held_now" | grep -qx "$n" || { apt-mark hold "$n" >/dev/null && held+=("$n"); }
                done
            done
            [ ${#held[@]} -gt 0 ] && echo "Held for the update: ${held[*]}"
        fi
        if [ "$rc" -eq 0 ]; then
            apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade \
                || { rc=1; err="apt-get dist-upgrade failed"; }
        fi
        [ ${#held[@]} -gt 0 ] && apt-mark unhold "${held[@]}" >/dev/null
        [ "$rc" -eq 0 ] && apt-get -y -q autoremove >/dev/null
        [ -f /var/run/reboot-required ] && need=1
    else
        for p in "${EXCL[@]}"; do x+=("--exclude=$p"); done
        [ "$pm" = dnf ] && dnf -q makecache >/dev/null 2>&1
        $pm -y upgrade "${x[@]}" || { rc=1; err="$pm upgrade failed"; }
        [ "$rc" -eq 0 ] && $pm -y -q autoremove >/dev/null 2>&1
        # needs-restarting -r: exit 1 = reboot required (dnf-plugins-core / yum-utils)
        if ! command -v needs-restarting >/dev/null 2>&1 && ! dnf needs-restarting --help >/dev/null 2>&1; then
            $pm install -y -q "$( [ "$pm" = yum ] && echo yum-utils || echo dnf-plugins-core)" >/dev/null 2>&1
        fi
        if command -v needs-restarting >/dev/null 2>&1; then needs-restarting -r >/dev/null 2>&1; [ $? -eq 1 ] && need=1
        elif dnf needs-restarting --help >/dev/null 2>&1; then dnf needs-restarting -r >/dev/null 2>&1; [ $? -eq 1 ] && need=1; fi
    fi
    # Fallback: the newest installed kernel is not the running one
    if [ "$need" -eq 0 ]; then
        newest=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|^/boot/vmlinuz-||' | grep -v rescue | sort -V | tail -n 1)
        [ -n "$newest" ] && [ "$newest" != "$(uname -r)" ] && need=1
    fi
    snap > "$w/after"
    changes=$(awk 'NR == FNR { b[$1] = $2; next }
        { a[$1] = $2
          if (($1 in b) == 0) print "Install  " $1 " " $2
          else if (b[$1] != $2) print "Upgrade  " $1 " " b[$1] " -> " $2 }
        END { for (k in b) if ((k in a) == 0) print "Remove  " k " " b[k] }' "$w/before" "$w/after")
    rm -rf "$w"
    count=$(printf '%s' "$changes" | grep -c .)
    [ "$rc" -eq 0 ] && [ "$need" -eq 1 ] && [ "$REBOOT_ALLOWED" -eq 1 ] && doreboot=1
    if [ "$rc" -ne 0 ]; then result="FAILED: $err"
    else result="OK, changed $count packages$( [ "$doreboot" -eq 1 ] && echo ', rebooting')$( [ "$need" -eq 1 ] && [ "$doreboot" -eq 0 ] && echo ', reboot required')"; fi
    echo "=== Result"
    [ -n "$changes" ] && printf '%s\n' "$changes"
    echo "$result"
    send -k patch.install.timestamp -o "$(date +%s)" >/dev/null
    send -k patch.install.status -o "$( [ "$rc" -eq 0 ] && echo 0 || echo 1)" >/dev/null
    send -k patch.install.count -o "$count" >/dev/null
    send -k patch.install.list -o "${changes:-No packages changed}" >/dev/null
    send -k patch.install.result -o "$result" >/dev/null
    if [ "$doreboot" -eq 1 ]; then
        send -k patch.reboot.required -o 0 >/dev/null
        # The check runs again after the reboot (@reboot line in /etc/cron.d/zbx-patch-linux)
        shutdown -r +2 "Reboot after the update (zbx-patch-linux.sh)"
        echo "Rebooting in 2 minutes (cancel: shutdown -c)."
        exit 0
    fi
    [ "$need" -eq 1 ] && echo "WARNING: a reboot is required, but REBOOT=\"no\" in $PATCH_CONF" >&2
    return "$rc"
}
if [ "$MODE" = update ]; then
    [ "$(id -u)" -eq 0 ] || { echo "ERROR: --update needs root" >&2; exit 1; }
    do_update; [ $? -eq 2 ] && exit 0
    echo "=== Update check"
fi

START=$(date +%s)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1

OS_NAME=$(uname -s)
[ -r /etc/os-release ] && OS_NAME=$(. /etc/os-release && echo "${PRETTY_NAME:-$NAME $VERSION}")
OS_VERSION=$(uname -r)
LASTBOOT=$(awk '/^btime/ {print $2}' /proc/stat)

# Kernel packages (Debian / Ubuntu linux-image-*, RHEL kernel / kernel-core / kernel-uek ...)
KERNEL_RE='^(linux-(image|headers|modules|generic|signed|virtual|lowlatency|kernel)|kernel)([-_.].*)?$'

ALL=0; SECURITY=0; KERNEL=0; HELD=0
CRITICAL=""; BUGFIX=""; ENHANCEMENT=""          # empty = can't be determined, not sent
SEV_CRITICAL=""; SEV_IMPORTANT=""; SEV_MODERATE=""; SEV_LOW=""
LIST=""; HISTORY=""; REBOOT=0; REBOOT_REASON=""
REPO=""; PKGMGR="unknown"; AUTOUPDATE=0; LASTUPDATE=""; RESULT="OK"

if command -v apt-get >/dev/null 2>&1; then
    # ======================= Debian / Ubuntu =======================
    PKGMGR="apt"
    if [ "$IS_ROOT" -eq 1 ]; then
        if apt-get update -qq >/dev/null 2>&1; then REPO=1; else REPO=0; fi
    fi
    # "Inst <package> [<old version>] (<new version> <suite> [<arch>])"
    LANG=C apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | grep '^Inst ' > "$WORK/inst"
    if [ -s "$WORK/inst" ]; then
        LIST=$(awk '{
            pkg = $2; old = ""
            if ($3 ~ /^\[/) { old = $3; gsub(/[][]/, "", old) }
            rest = $0; sub(/^[^(]*\(/, "", rest); split(rest, f, " ")
            cat = (rest ~ /[Ss]ecurity/) ? "security" : "update"
            print "[" cat "] " pkg " " (old != "" ? old " -> " : "") f[1]
        }' "$WORK/inst")
        ALL=$(wc -l < "$WORK/inst")
        SECURITY=$(printf '%s\n' "$LIST" | grep -c '^\[security\]')
        KERNEL=$(awk '{print $2}' "$WORK/inst" | grep -cE "$KERNEL_RE")
    fi
    HELD=$(apt-mark showhold 2>/dev/null | grep -c .)

    if [ -f /var/run/reboot-required ]; then
        REBOOT=1
        REBOOT_REASON="reboot-required"
        [ -f /var/run/reboot-required.pkgs ] && \
            REBOOT_REASON="Packages: $(sort -u /var/run/reboot-required.pkgs | tr '\n' ' ')"
    fi

    if dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed' \
       && apt-config dump 2>/dev/null | grep -qE '^APT::Periodic::Unattended-Upgrade "(1|always)"'; then
        AUTOUPDATE=1
    fi

    # History from /var/log/apt/history.log (+ the last rotated logs), oldest first
    LOGS=$(ls -1tr /var/log/apt/history.log* 2>/dev/null | tail -n 3)
    if [ -n "$LOGS" ]; then
        # shellcheck disable=SC2086
        zcat -f $LOGS 2>/dev/null | awk '
            /^Start-Date:/ { d = $2 " " substr($3, 1, 5) }
            /^(Install|Upgrade|Downgrade|Remove|Purge|Reinstall):/ {
                act = $1; sub(/:$/, "", act)
                s = $0; sub(/^[A-Za-z]+: /, "", s)
                n = split(s, parts, /\), /)
                for (i = 1; i <= n; i++) {
                    p = parts[i]; sub(/\)$/, "", p)
                    name = p; sub(/ \(.*/, "", name)
                    v = p; sub(/^[^(]*\(/, "", v); sub(/, automatic$/, "", v)
                    if (act == "Upgrade" || act == "Downgrade") sub(/, /, " -> ", v)
                    print d "  " act "  " name " " v
                }
            }' > "$WORK/hist"
        if [ -s "$WORK/hist" ]; then
            HISTORY=$(tail -n "$HISTORY_LINES" "$WORK/hist" | tac)
            LASTUPDATE=$(date -d "$(tail -n 1 "$WORK/hist" | cut -c1-16)" +%s 2>/dev/null)
        fi
    fi
    if [ -z "$LASTUPDATE" ]; then
        LASTUPDATE=$(find /var/lib/dpkg/info -name '*.list' -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1 | cut -d. -f1)
    fi

elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    # ======================= RHEL family =======================
    if command -v dnf >/dev/null 2>&1; then PKGMGR="dnf"; else PKGMGR="yum"; fi
    LANG=C "$PKGMGR" -q check-update > "$WORK/upd" 2>/dev/null
    RC=$?   # 100 = updates available, 0 = none, 1 = error
    if [ "$RC" -eq 1 ]; then
        REPO=0
        RESULT="ERROR: $PKGMGR check-update failed"
    else
        REPO=1
    fi
    # "<name>.<arch> <version> <repo>", the section "Obsoleting Packages" is skipped
    awk '/^Obsoleting/ {exit} NF == 3 && $1 !~ /^(Security:|Last)/ {
            n = $1; sub(/\.[^.]*$/, "", n); print n " " $2 }' "$WORK/upd" > "$WORK/pending"

    # Advisories of the available updates
    #   dnf4 / yum: <advisory> <type or severity/Sec.> <nevra>
    #   dnf5:       <advisory> <type> <severity> <nevra> <issued>
    if [ "$PKGMGR" = "dnf" ]; then UIARGS=(updateinfo list --available); else UIARGS=(updateinfo list); fi
    LANG=C "$PKGMGR" -q "${UIARGS[@]}" 2>/dev/null | awk '
        NF >= 3 && $1 != "Name" {
            if ($2 ~ /\/Sec\.?$/) { type = "security"; sev = $2; sub(/\/Sec\.?$/, "", sev); pkg = $3 }
            else if ($2 ~ /^(security|bugfix|enhancement|newpackage|unspecified)$/) {
                type = $2
                if (NF >= 5) { sev = $3; pkg = $4 } else { sev = ""; pkg = $3 }
            } else next
            sub(/-[^-]+-[^-]+$/, "", pkg)      # nevra -> name
            print pkg "\t" type "\t" sev
        }' > "$WORK/advisories"

    # Severity rank of a package = highest severity of its security advisories
    awk -F'\t' '
        function rank(s) { return s == "Critical" ? 4 : s == "Important" ? 3 : s == "Moderate" ? 2 : s == "Low" ? 1 : 0 }
        FILENAME == ARGV[1] {
            if ($2 == "security") { sec[$1] = 1; if (rank($3) > r[$1]) { r[$1] = rank($3); sv[$1] = $3 } }
            else if ($2 == "bugfix") bug[$1] = 1
            else if ($2 == "enhancement") enh[$1] = 1
            next
        }
        {
            split($0, f, " "); n = f[1]
            if (n in sec)      tag = "[security]" (sv[n] != "" ? " [" sv[n] "]" : "")
            else if (n in bug) tag = "[bugfix]"
            else if (n in enh) tag = "[enhancement]"
            else               tag = "[update]"
            print tag " " $0
        }' "$WORK/advisories" "$WORK/pending" > "$WORK/list"

    if [ -s "$WORK/list" ]; then
        LIST=$(cat "$WORK/list")
        ALL=$(wc -l < "$WORK/list")
        KERNEL=$(awk '{print $1}' "$WORK/pending" | grep -cE "$KERNEL_RE")
    fi
    SECURITY=$(grep -c '^\[security\]' "$WORK/list")
    CRITICAL=$(grep -c '^\[security\] \[Critical\]' "$WORK/list")
    SEV_CRITICAL=$CRITICAL
    SEV_IMPORTANT=$(grep -c '^\[security\] \[Important\]' "$WORK/list")
    SEV_MODERATE=$(grep -c '^\[security\] \[Moderate\]' "$WORK/list")
    SEV_LOW=$(grep -c '^\[security\] \[Low\]' "$WORK/list")
    BUGFIX=$(grep -c '^\[bugfix\]' "$WORK/list")
    ENHANCEMENT=$(grep -c '^\[enhancement\]' "$WORK/list")

    # Version lock (dnf4 / yum / dnf5)
    for f in /etc/dnf/plugins/versionlock.list /etc/yum/pluginconf.d/versionlock.list; do
        [ -f "$f" ] && HELD=$(( HELD + $(grep -cvE '^[[:space:]]*(#|$)' "$f") ))
    done
    [ -f /etc/dnf/versionlock.toml ] && HELD=$(( HELD + $(grep -c '^\[\[packages\]\]' /etc/dnf/versionlock.toml) ))

    # needs-restarting -r: exit 1 = reboot required (dnf-utils / yum-utils)
    NR=""
    if command -v needs-restarting >/dev/null 2>&1; then
        NR=$(LANG=C needs-restarting -r 2>/dev/null); [ $? -eq 1 ] && REBOOT=1
    elif [ "$PKGMGR" = "dnf" ]; then
        NR=$(LANG=C dnf -q needs-restarting -r 2>/dev/null); [ $? -eq 1 ] && REBOOT=1
    fi
    if [ "$REBOOT" -eq 1 ]; then
        REBOOT_REASON=$(printf '%s\n' "$NR" | sed -n 's/^ *\* *//p' | tr '\n' ' ')
        REBOOT_REASON="Updated: ${REBOOT_REASON:-see needs-restarting -r}"
    fi

    for t in dnf-automatic-install.timer; do
        systemctl is-enabled -q "$t" 2>/dev/null && AUTOUPDATE=1
    done
    for t in dnf-automatic.timer dnf5-automatic.timer; do
        systemctl is-enabled -q "$t" 2>/dev/null \
            && grep -qE '^[[:space:]]*apply_updates[[:space:]]*=[[:space:]]*(yes|true|1)' /etc/dnf/automatic.conf 2>/dev/null \
            && AUTOUPDATE=1
    done
    systemctl is-enabled -q yum-cron 2>/dev/null \
        && grep -qE '^[[:space:]]*apply_updates[[:space:]]*=[[:space:]]*yes' /etc/yum/yum-cron.conf 2>/dev/null \
        && AUTOUPDATE=1

    # History from the rpm database (install time of the packages), newest first
    rpm -qa --qf '%{INSTALLTIME} %{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null \
        | sort -rn | head -n "$HISTORY_LINES" > "$WORK/hist"
    if [ -s "$WORK/hist" ]; then
        LASTUPDATE=$(head -n 1 "$WORK/hist" | cut -d' ' -f1)
        HISTORY=$(while read -r ts name ver; do
            printf '%s  Installed  %s %s\n' "$(date -d "@$ts" '+%Y-%m-%d %H:%M')" "$name" "$ver"
        done < "$WORK/hist")
    fi
else
    RESULT="ERROR: no supported package manager found (apt, dnf, yum)"
fi

# Reboot fallback for both families: the newest installed kernel is not the running one
if [ "$REBOOT" -eq 0 ]; then
    NEWEST=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|^/boot/vmlinuz-||' | grep -v rescue | sort -V | tail -n 1)
    if [ -n "$NEWEST" ] && [ "$NEWEST" != "$OS_VERSION" ]; then
        REBOOT=1
        REBOOT_REASON="Running kernel $OS_VERSION, newest installed kernel $NEWEST"
    fi
fi

# Pending updates matching EXCLUDE: counted and marked in the list (they stay in the counts)
EXCLUDED=0
if [ ${#EXCL[@]} -gt 0 ] && [ -n "$LIST" ]; then
    LIST=$(set -f
        while IFS= read -r line; do
            name=""
            for tok in $line; do case "$tok" in \[*) ;; *) name=${tok%%:*}; break ;; esac; done
            if [ -n "$name" ] && is_excluded "$name"; then echo "$line (excluded)"; else echo "$line"; fi
        done <<< "$LIST")
    EXCLUDED=$(printf '%s\n' "$LIST" | grep -c ' (excluded)$')
fi

[ -z "$LIST" ] && LIST="No pending updates"
[ -z "$HISTORY" ] && HISTORY="No update history found"
[ -z "$REBOOT_REASON" ] && REBOOT_REASON="-"
CHECK_OK=1
case "$RESULT" in ERROR*) CHECK_OK=0 ;; esac

{
    echo "- patch.os Linux"
    echo "- patch.os.name $(q "$OS_NAME")"
    echo "- patch.os.version $(q "$OS_VERSION")"
    echo "- patch.source $PKGMGR"
    [ -n "$REPO" ] && echo "- patch.source.available $REPO"
    echo "- patch.check.timestamp $(date +%s)"
    echo "- patch.check.duration $(( $(date +%s) - START ))"
    echo "- patch.check.result $(q "$RESULT")"
    echo "- patch.reboot.required $REBOOT"
    [ -n "$LASTBOOT" ] && echo "- patch.lastboot $LASTBOOT"
    # AUTO_UPDATE="true" in zbx-patch.conf = this script installs the updates (--auto-update)
    echo "- patch.autoupdate $(( AUTOUPDATE | AUTO_UPDATE ))"
    echo "- patch.reboot.allowed $REBOOT_ALLOWED"
    echo "- patch.maintenance.window $(q "${MAINTENANCE_WINDOW:--}${MAINT_ERROR:+ ($MAINT_ERROR)}")"
    [ -n "$MAINT_NEXT" ] && echo "- patch.maintenance.next $MAINT_NEXT"
    echo "- patch.exclude $(q "${EXCLUDE:--}")"
    if [ -n "$LASTUPDATE" ]; then
        echo "- patch.lastupdate.timestamp $LASTUPDATE"
        echo "- patch.lastupdate.patchday $(patchday "$LASTUPDATE")"
    fi
    if [ "$CHECK_OK" -eq 1 ]; then
        echo "- patch.updates.all $ALL"
        echo "- patch.updates.security $SECURITY"
        echo "- patch.updates.kernel $KERNEL"
        echo "- patch.updates.held $HELD"
        echo "- patch.updates.excluded $EXCLUDED"
        [ -n "$CRITICAL" ]      && echo "- patch.updates.critical $CRITICAL"
        [ -n "$BUGFIX" ]        && echo "- patch.updates.bugfix $BUGFIX"
        [ -n "$ENHANCEMENT" ]   && echo "- patch.updates.enhancement $ENHANCEMENT"
        [ -n "$SEV_CRITICAL" ]  && echo "- patch.updates.severity.critical $SEV_CRITICAL"
        [ -n "$SEV_IMPORTANT" ] && echo "- patch.updates.severity.important $SEV_IMPORTANT"
        [ -n "$SEV_MODERATE" ]  && echo "- patch.updates.severity.moderate $SEV_MODERATE"
        [ -n "$SEV_LOW" ]       && echo "- patch.updates.severity.low $SEV_LOW"
        # Windows only categories
        for k in definition servicepacks updaterollups drivers upgrades; do
            echo "- patch.updates.$k 0"
        done
    fi
} > "$WORK/values"
send -i "$WORK/values"

# Multi-line text values are sent separately
send -k patch.reboot.reason -o "$REBOOT_REASON"
send -k patch.history -o "$HISTORY"
[ "$CHECK_OK" -eq 1 ] && send -k patch.updates.list -o "$LIST"

echo "$OS_NAME: pending $ALL (security $SECURITY, critical ${CRITICAL:-n/a}, kernel $KERNEL, excluded $EXCLUDED), reboot required: $REBOOT, result: $RESULT"
echo "Maintenance window: ${MAINTENANCE_WINDOW:--}${MAINT_NEXT:+ (next $(date -d "@$MAINT_NEXT" '+%Y-%m-%d %H:%M'))}, exclude: ${EXCLUDE:--}, reboot allowed: $REBOOT_ALLOWED"
exit 0
