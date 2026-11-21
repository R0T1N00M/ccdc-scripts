#!/usr/bin/env bash
# CCDC Linux inbound firewall with automatic rollback.
# Usage: sudo bash 04_linux_firewall.sh TCP_PORTS [UDP_PORTS]
set -u

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
die()  { echo "ERROR: $*"; exit 1; }

TCP="${1:-}"; UDP="${2:-}"
valid() {
    local p
    [[ "$1" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
    for p in ${1//,/ }; do
        [ "${#p}" -le 5 ] && [ "$((10#$p))" -ge 1 ] && [ "$((10#$p))" -le 65535 ] || return 1
    done
}
[ -n "$TCP" ] || die "Usage: $0 TCP_PORTS [UDP_PORTS]"
valid "$TCP" || die "TCP ports must look like 22,80,443"
[ -z "$UDP" ] || valid "$UDP" || die "UDP ports must look like 53,123"

if have systemctl && systemctl is-active --quiet firewalld; then
    echo "firewalld is active on this host. Use it instead:"; exit 2
fi
if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    echo "ufw is active on this host. Use it instead:"; exit 2
fi

have iptables && have iptables-save && have iptables-restore || die "iptables tools not found."
D=/root/ccdc
mkdir -p "$D"; chmod 700 "$D"
TS=$(date +%Y%m%d_%H%M%S)
B4="$D/iptables.before.$TS"; B6="$D/ip6tables.before.$TS"; FLAG="$D/fw.keep.$TS"
V6=0
if have ip6tables && have ip6tables-save && have ip6tables-restore && ip6tables -S >/dev/null 2>&1; then V6=1; fi

iptables-save > "$B4" || die "Could not save current rules."
if [ "$V6" -eq 1 ]; then ip6tables-save > "$B6" || V6=0; fi

RBS="$D/fw.rollback.$TS.sh"
{
    echo '#!/usr/bin/env bash'
    echo "iptables -P INPUT ACCEPT; iptables -F INPUT; iptables-restore < '$B4'"
    if [ "$V6" -eq 1 ]; then echo "ip6tables -P INPUT ACCEPT; ip6tables -F INPUT; ip6tables-restore < '$B6'"; fi
} > "$RBS"
chmod 700 "$RBS"
restore() { bash "$RBS"; }

RB="sleep 120; [ -e '$FLAG' ] || bash '$RBS'"
if have setsid; then nohup setsid bash -c "$RB" >/dev/null 2>&1 &
else nohup bash -c "$RB" >/dev/null 2>&1 & fi

apply() {
    local ipt="$1" icmp="$2" p
    "$ipt" -P INPUT ACCEPT || return 1
    "$ipt" -F INPUT || return 1
    "$ipt" -A INPUT -i lo -j ACCEPT || return 1
    "$ipt" -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || return 1
    "$ipt" -A INPUT -p "$icmp" -j ACCEPT || return 1
    [ "$ipt" != ip6tables ] || "$ipt" -A INPUT -p udp --dport 546 -j ACCEPT || return 1
    for p in ${TCP//,/ }; do "$ipt" -A INPUT -p tcp --dport "$p" -j ACCEPT || return 1; done
    for p in ${UDP//,/ }; do "$ipt" -A INPUT -p udp --dport "$p" -j ACCEPT || return 1; done
    "$ipt" -A INPUT -m limit --limit 6/min -j LOG --log-prefix 'CCDC-DROP: ' 2>/dev/null || true
    "$ipt" -P INPUT DROP || return 1
}

ok=1
apply iptables icmp || ok=0
if [ "$ok" -eq 1 ] && [ "$V6" -eq 1 ]; then apply ip6tables ipv6-icmp || ok=0; fi
if [ "$ok" -ne 1 ]; then restore; touch "$FLAG"; exit 1; fi

echo "Rules applied. Open a NEW SSH session and verify services."
printf 'Type KEEP within 90 seconds: '
read -r -t 90 ans || ans=""
if [ "${ans:-}" != "KEEP" ]; then restore; touch "$FLAG"; exit 1; fi

touch "$FLAG"
iptables-save > "$D/iptables.rules.v4"
[ "$V6" -eq 1 ] && ip6tables-save > "$D/iptables.rules.v6"
echo "Rules kept. Rollback: bash $RBS"
