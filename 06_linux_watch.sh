#!/usr/bin/env bash
# CCDC Linux change alarm. Baseline and alert on account, credential,
# sudo, SSH, cron, service, listening port, SUID, PAM, and web-file changes.
set -u

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
INT="${1:-30}"
[[ "$INT" =~ ^[0-9]+$ ]] && [ "$INT" -ge 1 ] || { echo "Interval must be a number of seconds."; exit 1; }

D=/root/ccdc
mkdir -p "$D"; chmod 700 "$D"
LOG="$D/watch.log"
have() { command -v "$1" >/dev/null 2>&1; }
fp() { sha256sum | cut -c1-16; }
fpfiles() { local f; for f in "$@"; do [ -f "$f" ] && printf '%s %s\n' "$f" "$(fp < "$f")"; done; }

snap() {
    {
        echo "## ACCOUNTS"
        cut -d: -f1,3,4,6,7 /etc/passwd | sort
        echo "## PASSWORD FINGERPRINTS"
        while IFS=: read -r u h _; do printf '%s %s\n' "$u" "$(printf '%s' "$h" | fp)"; done < /etc/shadow | sort
        echo "## ADMIN GROUPS"
        getent group sudo wheel admin root adm docker 2>/dev/null | sort
        echo "## SUDOERS FILES"
        fpfiles /etc/sudoers /etc/sudoers.d/*
        echo "## SSH AUTHORIZED KEYS"
        cut -d: -f6 /etc/passwd | sort -u | while read -r h; do
            for f in "$h/.ssh/authorized_keys" "$h/.ssh/authorized_keys2"; do
                [ -f "$f" ] && printf '%s keys=%s %s\n' "$f" "$(grep -cEv '^[[:space:]]*(#|$)' "$f")" "$(fp < "$f")"
            done
        done
        echo "## LOGIN CONFIG"
        fpfiles /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* /etc/pam.d/* /etc/ld.so.preload /etc/environment
        echo "## CRON"
        fpfiles /etc/crontab /etc/anacrontab /etc/cron.d/* /etc/cron.hourly/* /etc/cron.daily/* /etc/cron.weekly/* /etc/cron.monthly/* /var/spool/cron/* /var/spool/cron/crontabs/*
        if have systemctl; then
            echo "## SYSTEMD: ENABLED UNITS"
            systemctl list-unit-files --state=enabled --no-legend --no-pager 2>/dev/null | awk '{print $1}' | sort
            echo "## SYSTEMD: LOCAL UNIT FILES"
            fpfiles /etc/systemd/system/*.service /etc/systemd/system/*.timer /etc/systemd/system/*.socket
        fi
        echo "## LISTENING PORTS"
        if have ss; then ss -H -tulpn 2>/dev/null | sort -u
        elif have netstat; then netstat -tuln 2>/dev/null | sort -u; fi
        echo "## SUID FILES"
        find /usr /bin /sbin /opt /home /root /tmp /var/tmp /dev/shm -xdev -type f -perm -4000 2>/dev/null | sort -u
        echo "## KERNEL MODULES"
        lsmod 2>/dev/null | awk 'NR>1 {print $1}' | sort
        if [ -z "${CCDC_WATCH_NOWEB:-}" ]; then
            echo "## WEB FILES"
            find /var/www /srv/www /srv/http /usr/share/nginx/html -xdev -type f \
                \( -name '*.php' -o -name '*.phtml' -o -name '*.html' -o -name '*.htm' -o -name '*.js' -o -name '*.jsp' -o -name '*.aspx' -o -name '*.cgi' -o -name '*.py' -o -name '.htaccess' \) \
                -printf '%p %s %T@\n' 2>/dev/null | sort | head -n 20000
        fi
        echo "## LOGGED IN"
        who 2>/dev/null | awk '{print $1, $2, $NF}' | sort
    } > "$1" 2>&1
}

snap "$D/watch.prev"
echo "Baseline taken $(date). Checking every $INT seconds."
echo "Changes are logged to $LOG."
while :; do
    sleep "$INT"
    snap "$D/watch.new"
    if ! cmp -s "$D/watch.prev" "$D/watch.new"; then
        {
            printf '\a\n!!!!! CHANGE DETECTED on %s at %s !!!!!\n' "$(hostname)" "$(date)"
            diff <(awk '/^## /{s=$0; next} {print s " | " $0}' "$D/watch.prev") \
                 <(awk '/^## /{s=$0; next} {print s " | " $0}' "$D/watch.new") | grep '^[<>]'
        } | tee -a "$LOG"
        mv "$D/watch.new" "$D/watch.prev"
    fi
    [ -n "${CCDC_WATCH_ONCE:-}" ] && break
done
