#!/usr/bin/env bash
# CCDC Linux triage. READ ONLY: this script changes nothing on the system.
# Usage: sudo bash 01_linux_inventory.sh
# Output: printed to screen and saved under /root/ccdc/
set -u

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }

D=/root/ccdc
mkdir -p "$D"; chmod 700 "$D"
OUT="$D/inventory_$(hostname)_$(date +%Y%m%d_%H%M%S).txt"

sec()  { printf '\n\n========== %s ==========' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
ffind() { find / \( -path /proc -o -path /sys -o -path /run -o -path /dev -o -path /snap \) -prune -o "$@" -print 2>/dev/null; }

{
sec "HOST"
hostname
grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null
uname -r
if have ip; then ip -br addr; ip route
elif have ifconfig; then ifconfig -a; have route && route -n
else echo "(no ip or ifconfig tool found)"; fi

sec "LISTENING PORTS (compare against your scored services list)"
if have ss; then ss -tulpn
elif have netstat; then netstat -tulpn
else echo "(no ss or netstat tool found)"; fi

sec "UID 0 ACCOUNTS (should be root only)"
awk -F: '$3==0 {print $1}' /etc/passwd

sec "ACCOUNTS WITH A LOGIN SHELL (name uid home shell)"
grep -Ev '(nologin|false|sync|shutdown|halt)$' /etc/passwd | awk -F: '{print $1, $3, $6, $7}'

sec "ACCOUNTS WITH A USABLE PASSWORD HASH"
awk -F: '$2 !~ /^[!*]/ && $2 != "" {print $1}' /etc/shadow

sec "ACCOUNTS WITH AN EMPTY PASSWORD (fix immediately)"
awk -F: '$2 == "" {print $1}' /etc/shadow

sec "ADMIN GROUP MEMBERS"
getent group sudo wheel admin root adm 2>/dev/null

sec "SUDOERS (non-comment lines)"
grep -EHv '^\s*(#|$)' /etc/sudoers /etc/sudoers.d/* 2>/dev/null

sec "SSH AUTHORIZED KEYS (every key here is a login that survives password changes)"
ffind -type f -name 'authorized_keys*' | while read -r f; do
    echo "--- $f"; ls -la "$f"; cat "$f"
done

sec "SSHD EFFECTIVE SETTINGS"
if have sshd; then
    sshd -T 2>/dev/null | grep -Ei '^(port|permitrootlogin|passwordauthentication|permitemptypasswords|pubkeyauthentication|authorizedkeysfile|allowusers|allowgroups) '
fi

sec "USER CRONTABS"
for u in $(cut -d: -f1 /etc/passwd); do
    c=$(crontab -l -u "$u" 2>/dev/null | grep -Ev '^\s*(#|$)')
    [ -n "$c" ] && printf '[%s]\n%s\n' "$u" "$c"
done

sec "SYSTEM CRON"
grep -EHv '^\s*(#|$)' /etc/crontab 2>/dev/null
grep -REHv '^\s*(#|$)' /etc/cron.d 2>/dev/null
ls -la /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly 2>/dev/null
have atq && atq

if have systemctl; then
    sec "SYSTEMD TIMERS"
    systemctl list-timers --all --no-pager 2>/dev/null
    sec "ENABLED SERVICES"
    systemctl list-unit-files --type=service --state=enabled --no-pager 2>/dev/null
    sec "RUNNING SERVICES"
    systemctl list-units --type=service --state=running --no-pager 2>/dev/null
    sec "UNIT FILES CHANGED IN THE LAST 7 DAYS"
    find /etc/systemd /usr/lib/systemd /lib/systemd -type f -mtime -7 2>/dev/null
fi

sec "WHO IS LOGGED IN"
w
last -n 20 2>/dev/null

sec "PROCESS TREE"
ps -eo pid,ppid,user,stime,args --forest

sec "PROCESSES RUNNING FROM A DELETED BINARY (classic implant sign)"
for e in /proc/[0-9]*/exe; do
    t=$(readlink "$e" 2>/dev/null) || continue
    case "$t" in *'(deleted)') echo "$e -> $t" ;; esac
done

sec "LD PRELOAD (should be empty or missing)"
cat /etc/ld.so.preload 2>/dev/null

sec "FILES IN TEMP DIRECTORIES"
find /tmp /var/tmp /dev/shm -type f -exec ls -la {} + 2>/dev/null

sec "SUID BINARIES (look for anything unusual, especially outside /usr)"
ffind -type f -perm -4000

sec "FILES CHANGED IN THE LAST 7 DAYS: system binaries, /etc, web roots"
find /etc /bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin \
     /var/www /srv /usr/share/nginx -type f -mtime -7 2>/dev/null | head -n 300

sec "SUDOERS RED FLAGS (NOPASSWD or !authenticate means sudo without a password)"
grep -EHn 'NOPASSWD|!authenticate' /etc/sudoers /etc/sudoers.d/* 2>/dev/null | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#' \
    || echo "(none)"

sec "FILE CAPABILITIES (cap_setuid and similar work like SUID root)"
if have getcap; then
    getcap -r /usr /bin /sbin /opt /home /srv /root /tmp /var/tmp 2>/dev/null | sort -u
else
    echo "(getcap not installed)"
fi

sec "WORLD-WRITABLE FILES IN SYSTEM DIRECTORIES (anyone can replace these)"
find /etc /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin /usr/lib/systemd /lib/systemd \
     -xdev -type f -perm -0002 2>/dev/null | head -n 100

sec "PAM RED FLAGS (login backdoors live here)"
echo "-- pam_exec lines (run a program at every login; verify each one):"
grep -REn 'pam_exec\.so' /etc/pam.d 2>/dev/null | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#' || echo "   (none)"
echo "-- nullok (accounts with an empty password may log in):"
grep -REn 'nullok' /etc/pam.d 2>/dev/null | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#' || echo "   (none)"
echo "-- auth 'sufficient' pam_permit.so (accepts ANY password; almost always a backdoor):"
grep -REn '^[[:space:]]*auth[[:space:]]+sufficient[[:space:]]+pam_permit\.so' /etc/pam.d 2>/dev/null || echo "   (none)"
echo "-- pam_permit before pam_deny in the main auth stacks:"
for f in /etc/pam.d/common-auth /etc/pam.d/system-auth /etc/pam.d/password-auth; do
    [ -f "$f" ] || continue
    d=$(grep -En '^[[:space:]]*auth[[:space:]].*pam_deny\.so' "$f" | head -n 1 | cut -d: -f1)
    a=$(grep -En '^[[:space:]]*auth[[:space:]].*pam_permit\.so' "$f" | head -n 1 | cut -d: -f1)
    if [ -z "$d" ]; then echo "   $f: no auth pam_deny.so line. INVESTIGATE"
    elif [ -n "$a" ] && [ "$a" -lt "$d" ]; then echo "   $f: pam_permit (line $a) comes before pam_deny (line $d). INVESTIGATE"
    else echo "   $f: order looks normal"
    fi
done

sec "PACKAGE FILE VERIFICATION (a changed login binary or PAM module is a likely backdoor)"
if have dpkg; then
    v=$(dpkg --verify libpam-modules libpam-modules-bin libpam-runtime openssh-server openssh-client sudo login passwd coreutils bash util-linux 2>/dev/null \
        | grep -v ' c /' | grep -Ev ' /usr/share/(man|doc|locale|info|lintian|bash-completion)/' | head -n 60)
    if [ -n "$v" ]; then echo "$v"; else echo "(no changed program files in the checked packages)"; fi
elif have rpm; then
    v=$(rpm -V pam openssh-server openssh-clients sudo coreutils bash shadow-utils util-linux 2>/dev/null \
        | grep -v ' c /' | grep -Ev ' /usr/share/(man|doc|locale|info)/' | head -n 60)
    if [ -n "$v" ]; then echo "$v"; else echo "(no changed program files in the checked packages)"; fi
else
    echo "(no dpkg or rpm on this host; cannot verify)"
fi

sec "CONTAINERS AND KUBERNETES"
if have docker; then docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>&1 | head -n 60; fi
if have podman; then podman ps -a 2>&1 | head -n 60; fi
if have kubectl; then
    kubectl get nodes -o wide 2>&1 | head -n 20
    kubectl get pods -A -o wide 2>&1 | head -n 80
    kubectl get svc -A 2>&1 | head -n 60
fi
if ! have docker && ! have podman && ! have kubectl; then echo "(none found)"; fi

sec "SERVICE CONFIG HIGHLIGHTS (what is this box actually serving?)"
for f in /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf; do
    if [ -f "$f" ]; then
        echo "-- FTP ($f):"
        grep -E '^(anonymous_enable|anon_upload_enable|anon_mkdir_write_enable|write_enable|local_enable|anon_root|local_root|chroot_local_user)' "$f"
    fi
done
if [ -f /etc/samba/smb.conf ]; then
    echo "-- Samba shares (/etc/samba/smb.conf):"
    grep -Ev '^[[:space:]]*([#;]|$)' /etc/samba/smb.conf | grep -E '^\[|path[[:space:]]*=|guest ok|public|writ(e|a)ble|valid users|read only' | head -n 60
fi
if have apache2ctl; then echo "-- Apache virtual hosts:"; apache2ctl -S 2>&1 | head -n 30
elif have httpd; then echo "-- Apache virtual hosts:"; httpd -S 2>&1 | head -n 30; fi
if have nginx; then
    echo "-- nginx listen / server_name / root:"
    nginx -T 2>/dev/null | grep -E '^[[:space:]]*(listen|server_name|root|proxy_pass)[[:space:]]' | sort -u | head -n 40
fi
if [ -f /etc/krb5.conf ] && grep -q 'default_realm' /etc/krb5.conf; then
    echo "-- Domain joined: $(grep -E '^[[:space:]]*default_realm' /etc/krb5.conf | head -n 1)"
fi

sec "DATABASE ACCOUNTS (works only when root can connect without a password)"
if have mysql; then
    mysql --connect-timeout=3 -N -B -e "SELECT user, host, plugin, IF(authentication_string='' OR authentication_string IS NULL,'EMPTY PASSWORD','password set') FROM mysql.user ORDER BY user, host" 2>/dev/null \
        || echo "(MySQL/MariaDB: could not query. Log in by hand and review: SELECT user,host FROM mysql.user;)"
fi
if have psql && id postgres >/dev/null 2>&1; then
    su postgres -c "psql -At -c \"SELECT rolname || ' superuser=' || rolsuper || ' login=' || rolcanlogin FROM pg_roles WHERE rolname NOT LIKE 'pg\\_%'\"" 2>/dev/null \
        || echo "(PostgreSQL: could not query)"
fi
if ! have mysql && ! have psql; then echo "(no mysql or psql client found)"; fi

sec "FIREWALL STATE"
have ufw && ufw status verbose 2>/dev/null
have firewall-cmd && firewall-cmd --list-all 2>/dev/null
have iptables && iptables -S 2>/dev/null
have nft && nft list ruleset 2>/dev/null | head -n 100

} 2>&1 | tee "$OUT"

chmod 600 "$OUT"
echo
echo "Saved to $OUT"
