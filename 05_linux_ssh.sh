#!/usr/bin/env bash
# CCDC SSH hardening: conservative settings with backup and config validation.
set -u

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
CFG=/etc/ssh/sshd_config
[ -f "$CFG" ] || { echo "No $CFG on this host."; exit 1; }
SSHD=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)
[ -x "$SSHD" ] || { echo "sshd binary not found."; exit 1; }

D=/root/ccdc
mkdir -p "$D"; chmod 700 "$D"
BAK="$D/sshd_config.$(date +%Y%m%d_%H%M%S)"
cp -p "$CFG" "$BAK" || { echo "Backup failed. Nothing changed."; exit 1; }

if grep -q '^# CCDC-HARDEN begin' "$CFG"; then
    echo "Already applied on this host."
else
    NEW=$(mktemp)
    {
        cat <<'EOF'
# CCDC-HARDEN begin
PermitEmptyPasswords no
HostbasedAuthentication no
IgnoreRhosts yes
PermitUserEnvironment no
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
MaxAuthTries 4
LoginGraceTime 30
LogLevel VERBOSE
# CCDC-HARDEN end
EOF
        cat "$CFG"
    } > "$NEW"

    if "$SSHD" -t -f "$NEW"; then
        cat "$NEW" > "$CFG"; rm -f "$NEW"
        if systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null \
           || service sshd reload 2>/dev/null || service ssh reload 2>/dev/null; then
            echo "[ OK ] sshd hardened and reloaded. Backup: $BAK"
        else
            echo "[WARN] Config installed but reload failed. Reload sshd manually."
        fi
    else
        rm -f "$NEW"
        echo "[FAIL] New config did not validate. Nothing changed."; exit 1
    fi
fi

echo
echo "Current effective settings to review:" 
"$SSHD" -T 2>/dev/null | grep -Ei '^(permitrootlogin|passwordauthentication|pubkeyauthentication|allowusers|allowgroups) '
echo "Test from a NEW session before closing this one. Undo: cp $BAK $CFG && reload sshd"
