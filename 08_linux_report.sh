#!/usr/bin/env bash
# CCDC Linux HTML inventory report.
# Usage: sudo bash 08_linux_report.sh [-d DAYS]
set -u

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }

DAYS=3
while getopts "d:" opt; do
    case "$opt" in
        d) DAYS="$OPTARG" ;;
        *) echo "Usage: $0 [-d DAYS]" >&2; exit 1 ;;
    esac
done
[[ "$DAYS" =~ ^[0-9]+$ ]] && [ "$DAYS" -ge 1 ] || {
    echo "-d needs a number of days (1 or more)." >&2
    exit 1
}

D=/root/ccdc
mkdir -p "$D"; chmod 700 "$D"
HOST=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)
HOSTSAFE=$(printf '%s' "$HOST" | tr -cd 'A-Za-z0-9._-')
OUT="$D/report_${HOSTSAFE}_$(date +%Y%m%d_%H%M%S).html"

esc() {
    sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

section() {
    local title="$1"
    shift
    printf '<details open><summary>%s</summary><pre>' "$title"
    "$@" 2>&1 | head -n 300 | esc
    printf '</pre></details>\n'
}

have() { command -v "$1" >/dev/null 2>&1; }

{
cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$HOST inventory</title>
<style>
body{font:15px/1.45 system-ui,sans-serif;margin:24px;max-width:1100px}
header{border-bottom:1px solid #ccc;margin-bottom:18px}
details{border:1px solid #ddd;border-radius:6px;margin:8px 0}
summary{cursor:pointer;font-weight:bold;padding:10px;background:#f6f6f6}
pre{white-space:pre-wrap;overflow-wrap:anywhere;padding:10px;margin:0}
.warn{color:#b3261e;font-weight:bold}
</style>
</head>
<body>
<header><h1>$HOST inventory</h1>
<p>Generated $(date '+%Y-%m-%d %H:%M:%S %Z') &middot; recent changes: $DAYS day(s)</p></header>
EOF

section "Host" sh -c 'hostname; grep -E "^PRETTY_NAME=" /etc/os-release 2>/dev/null; uname -r; uptime'
section "Listening ports" sh -c 'if command -v ss >/dev/null; then ss -tulpn; elif command -v netstat >/dev/null; then netstat -tulpn; else echo "(no ss or netstat)"; fi'
section "Accounts" sh -c 'awk -F: '"'"'$3 == 0 {print "UID0 " $1}'"'"' /etc/passwd; awk -F: '"'"'$2 == "" {print "EMPTY " $1}'"'"' /etc/shadow'
section "Sudo" sh -c 'grep -EHn "NOPASSWD|!authenticate" /etc/sudoers /etc/sudoers.d/* 2>/dev/null || echo "(none)"'
section "SSH" sh -c 'if command -v sshd >/dev/null; then sshd -T 2>/dev/null | grep -Ei "^(permitrootlogin|passwordauthentication|permitemptypasswords|pubkeyauthentication|allowusers|allowgroups)"; fi'
section "Processes" sh -c 'ps -eo pid,ppid,user,stime,args --forest'
section "Scheduled jobs" sh -c 'grep -EHv "^[[:space:]]*(#|$)" /etc/crontab /etc/cron.d/* 2>/dev/null; for u in $(cut -d: -f1 /etc/passwd); do crontab -l -u "$u" 2>/dev/null; done'
section "Recent system changes" sh -c "find /etc /bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin -xdev -type f -mtime -$DAYS -printf '%TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort -r"
section "Firewall" sh -c 'if command -v ufw >/dev/null; then ufw status verbose; fi; if command -v firewall-cmd >/dev/null; then firewall-cmd --list-all 2>/dev/null; fi; if command -v iptables >/dev/null; then iptables -S; fi; if command -v nft >/dev/null; then nft list ruleset 2>/dev/null; fi'
section "Containers" sh -c 'if command -v docker >/dev/null; then docker ps -a; fi; if command -v podman >/dev/null; then podman ps -a; fi; if command -v kubectl >/dev/null; then kubectl get pods -A -o wide; fi'
section "Temp and executable files" sh -c 'find /tmp /var/tmp /dev/shm -type f -exec ls -la {} + 2>/dev/null'

cat <<EOF
</body>
</html>
EOF
} > "$OUT"

chmod 600 "$OUT"
echo "Report saved to $OUT"
