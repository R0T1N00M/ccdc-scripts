#!/usr/bin/env bash
# CCDC Linux credential rotation.
# Sets a new random password on every account that currently has a usable
# (or empty) password, and writes the results to a CSV for your password
# change request to the white team / scoring engine.
# Usage: sudo bash 03_linux_passwords.sh [-x user1,user2] [-y]
set -u

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }

EXCLUDE=""; YES=0
while getopts "x:y" opt; do
    case "$opt" in
        x) EXCLUDE="$OPTARG" ;;
        y) YES=1 ;;
        *) echo "Usage: $0 [-x user1,user2] [-y]"; exit 1 ;;
    esac
done

D=/root/ccdc
mkdir -p "$D"; chmod 700 "$D"
CSV="$D/passwords_$(hostname)_$(date +%H%M%S).csv"

gen() {
    local s
    s=$(LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9' < /dev/urandom | head -c 20)
    printf '%s-%s-%s-%s' "${s:0:5}" "${s:5:5}" "${s:10:5}" "${s:15:5}"
}

targets=()
while read -r u; do
    case ",$EXCLUDE," in *",$u,"*) continue ;; esac
    targets+=("$u")
done < <(awk -F: '$2 !~ /^[!*]/ {print $1}' /etc/shadow)

if [ "${#targets[@]}" -eq 0 ]; then
    echo "No accounts to change."; exit 0
fi

echo "Passwords will be changed for these accounts:"
for u in "${targets[@]}"; do
    printf '  %-20s uid=%-6s shell=%s\n' "$u" "$(id -u "$u" 2>/dev/null)" "$(getent passwd "$u" | cut -d: -f7)"
done
echo
if [ "$YES" -ne 1 ]; then
    printf 'Type YES to continue: '
    read -r ans
    [ "$ans" = "YES" ] || { echo "Aborted. Nothing changed."; exit 1; }
fi

umask 077
echo "host,user,password" > "$CSV"
fail=0
for u in "${targets[@]}"; do
    pw=$(gen)
    if [ "${#pw}" -ne 23 ]; then
        echo "[FAIL] $u: password generation failed, account left unchanged"; fail=1; continue
    fi
    if printf '%s:%s\n' "$u" "$pw" | chpasswd; then
        echo "$(hostname),$u,$pw" >> "$CSV"
        echo "[ OK ] $u"
        if [ "$YES" -eq 1 ]; then echo "CSV,$(hostname),$u,$pw"; fi
    else
        echo "[FAIL] $u: chpasswd failed, account left unchanged"; fail=1
    fi
done

echo
echo "New passwords saved to $CSV (root only)."
echo "Submit changes for scored accounts, open a NEW session, and delete the CSV when no longer needed."
exit "$fail"
