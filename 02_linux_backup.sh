#!/usr/bin/env bash
# CCDC Linux backup. Run BEFORE changing anything so you can restore a
# service that red team (or your own teammate) breaks.
# Usage: sudo bash 02_linux_backup.sh
# Set FORCE=1 to include directories larger than 2 GB.
set -u

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

D="/root/ccdc/backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$D"; chmod 700 /root/ccdc "$D"
MAX_MB=2048

for p in /etc /var/www /srv /opt /home /root/.ssh /var/spool/cron \
         /var/named /var/lib/bind /etc/bind /usr/share/nginx/html /var/lib/tftpboot; do
    [ -e "$p" ] || continue
    size=$(du -sm "$p" 2>/dev/null | cut -f1)
    size=${size:-0}
    if [ "$size" -gt "$MAX_MB" ] && [ "${FORCE:-0}" != "1" ]; then
        echo "[SKIP] $p is ${size} MB (rerun with FORCE=1 to include it)"
        continue
    fi
    name=$(echo "${p#/}" | tr '/' '_')
    tar -czpf "$D/$name.tgz" -C / "${p#/}" 2>>"$D/errors.log"
    rc=$?
    if [ "$rc" -le 1 ]; then echo "[ OK ] $p -> $D/$name.tgz"; else echo "[FAIL] $p (see $D/errors.log)"; fi
done

if have iptables-save; then iptables-save > "$D/iptables.rules" 2>>"$D/errors.log" && echo "[ OK ] iptables rules -> $D/iptables.rules"; fi
if have ip6tables-save; then ip6tables-save > "$D/ip6tables.rules" 2>>"$D/errors.log"; fi
if have nft; then nft list ruleset > "$D/nftables.rules" 2>>"$D/errors.log" && echo "[ OK ] nftables ruleset -> $D/nftables.rules"; fi
if have ufw; then ufw status numbered > "$D/ufw.status" 2>>"$D/errors.log"; fi
if have firewall-cmd; then firewall-cmd --list-all-zones > "$D/firewalld.zones" 2>>"$D/errors.log"; fi

if have mysqldump; then
    if mysqldump --all-databases --single-transaction --routines --events > "$D/mysql_all.sql" 2>>"$D/errors.log"; then
        echo "[ OK ] MySQL/MariaDB dump -> $D/mysql_all.sql"
    else
        rm -f "$D/mysql_all.sql"
        echo "[FAIL] MySQL/MariaDB dump needs credentials. Run: mysqldump -u USER -p --all-databases > $D/mysql_all.sql"
    fi
fi

if have pg_dumpall && id postgres >/dev/null 2>&1; then
    if su postgres -c 'pg_dumpall' > "$D/postgres_all.sql" 2>>"$D/errors.log"; then
        echo "[ OK ] PostgreSQL dump -> $D/postgres_all.sql"
    else
        rm -f "$D/postgres_all.sql"
        echo "[FAIL] PostgreSQL dump failed (see $D/errors.log)"
    fi
fi

( cd "$D" && sha256sum ./*.tgz ./*.sql 2>/dev/null > SHA256SUMS )
chmod -R go-rwx "$D"

echo
ls -lh "$D"
echo
echo "Backups are in $D"
echo "Red team with root can delete these. Copy them to another machine if your rules allow it."
