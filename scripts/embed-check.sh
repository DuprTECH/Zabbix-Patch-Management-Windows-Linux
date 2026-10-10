#!/bin/bash
# ----------------------------------------------------------------------------
# embed-check.sh - embeds the check scripts zbx-patch-linux.sh / zbx-patch-windows.ps1 (gzip + base64)
# into setup-linux.sh / setup-windows.ps1, so they work on servers without access to GitHub.
# Run it after a change of the check scripts and commit the result (it takes the committed
# version of the check scripts, HEAD):
#   bash scripts/embed-check.sh
#
# Author : Dusan Priechodsky
# Source : https://github.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux
# Contact: info@duprtech.sk
# License: MIT
# ----------------------------------------------------------------------------
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(git -C "$DIR" rev-parse --show-toplevel)
REV=$(git -C "$REPO" rev-parse --short HEAD)

# embed <target> <check script> <begin line> <end line>: replaces the lines between begin and end
embed() {
    local target="$DIR/$1"
    DATA=$(git -C "$REPO" show "HEAD:scripts/$2" | gzip -9n | base64 -w 76) \
    REV_LINE="# Embedded check script: $2 from DuprTECH/Zabbix-Patch-Management-Windows-Linux $REV (embed-check.sh)" \
    awk -v b="$3" -v e="$4" '
        index($0, "# Embedded check script:") == 1 { print ENVIRON["REV_LINE"]; next }
        $0 == b && ! skip { print; print ENVIRON["DATA"]; skip = 1; next }
        skip && $0 == e   { skip = 0 }
        ! skip' "$target" > "$target.tmp"
    mv "$target.tmp" "$target"
    echo "$1: $2 $REV ($(grep -c '' "$target") lines)"
}
embed setup-linux.sh    zbx-patch-linux.sh    "CHECK_B64='" "'"
embed setup-windows.ps1 zbx-patch-windows.ps1 "\$CheckB64 = @'" "'@"
