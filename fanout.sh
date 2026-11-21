#!/usr/bin/env bash
# CCDC fan-out: run one script on many Linux hosts over SSH.
# Usage: bash fanout.sh [-s] [-p PORT] [-j JOBS] [-o OUTDIR] HOSTS_FILE SCRIPT [ARGS...]
set -u

SUDO=0; PORT=22; JOBS=10; OUT=""
while getopts "sp:j:o:" opt; do
    case "$opt" in
        s) SUDO=1 ;;
        p) PORT="$OPTARG" ;;
        j) JOBS="$OPTARG" ;;
        o) OUT="$OPTARG" ;;
        *) exit 1 ;;
    esac
done
shift $((OPTIND - 1))
[ $# -ge 2 ] || { echo "Usage: $0 [-s] [-p PORT] [-j JOBS] [-o OUTDIR] HOSTS_FILE SCRIPT [ARGS...]"; exit 1; }
HOSTS="$1"; SCRIPT="$2"; shift 2

die() { echo "ERROR: $*" >&2; exit 1; }
[ -f "$HOSTS" ] || die "hosts file '$HOSTS' not found"
[ -f "$SCRIPT" ] || die "script '$SCRIPT' not found"
case "$PORT" in ''|*[!0-9]*) die "port must be a number" ;; esac
case "$JOBS" in ''|*[!0-9]*|0) die "jobs must be a number above 0" ;; esac
command -v ssh >/dev/null 2>&1 || die "ssh is not installed"

ARGS=""
for a in "$@"; do
    case "$a" in *[!A-Za-z0-9_.,:/=@+-]*|'') die "argument '$a' has unsupported characters" ;; esac
    ARGS="$ARGS $a"
done

[ -n "$OUT" ] || OUT="./fanout_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT" || die "cannot create $OUT"
chmod 700 "$OUT"
NAME=$(basename "$SCRIPT")

run_host() {
    local addr="$1" user="$2" pw="$3"
    local out="$OUT/$addr.out"
    local opts=(-p "$PORT" -o StrictHostKeyChecking=no -o "UserKnownHostsFile=$OUT/known_hosts" -o ConnectTimeout=10 -o LogLevel=ERROR)
    local pre=()
    if [ -n "$pw" ]; then
        pre=(sshpass -e)
        opts+=(-o PubkeyAuthentication=no -o "PreferredAuthentications=password,keyboard-interactive" -o NumberOfPasswordPrompts=1)
    else opts+=(-o BatchMode=yes); fi
    {
        echo "##### $NAME on $addr as $user ($(date)) #####"
        if [ "$SUDO" -eq 1 ]; then
            local f
            f=$(SSHPASS="$pw" ${pre[@]+"${pre[@]}"} ssh "${opts[@]}" "$user@$addr" 'f=$(mktemp /tmp/.ccdc.XXXXXX) && cat > "$f" && echo "$f"' < "$SCRIPT" 2>&1)
            rc=$?
            if [ $rc -eq 0 ] && [ -n "$f" ]; then
                printf '%s\n' "$pw" | SSHPASS="$pw" ${pre[@]+"${pre[@]}"} ssh "${opts[@]}" "$user@$addr" "sudo -S -p '' bash '$f' $ARGS < /dev/null; rc=$?; rm -f '$f'; exit $rc" 2>&1
                rc=$?
            fi
        else
            SSHPASS="$pw" ${pre[@]+"${pre[@]}"} ssh "${opts[@]}" "$user@$addr" "f=\$(mktemp /tmp/.ccdc.XXXXXX) && cat > \"\$f\" && bash \"\$f\" $ARGS < /dev/null; rc=\$?; rm -f \"\$f\"; exit \$rc" < "$SCRIPT" 2>&1
            rc=$?
        fi
    } > "$out"
    chmod 600 "$out"; echo "$rc" > "$OUT/$addr.rc"
}

ADDRS=(); USERS=(); PWS=(); need_sshpass=0
while read -r addr user pw _; do
    case "$addr" in ''|\#*) continue ;; esac
    case "$addr" in *[!A-Za-z0-9_.:-]*) die "bad host address '$addr'" ;; esac
    [ -n "${user:-}" ] || user=root
    ADDRS+=("$addr"); USERS+=("$user"); PWS+=("${pw:-}")
    [ -n "${pw:-}" ] && need_sshpass=1
done < "$HOSTS"
[ ${#ADDRS[@]} -gt 0 ] || die "no hosts in $HOSTS"
if [ "$need_sshpass" -eq 1 ]; then command -v sshpass >/dev/null 2>&1 || die "sshpass is required"; fi

echo "Running $NAME$ARGS on ${#ADDRS[@]} host(s). Output: $OUT/"
i=0
while [ $i -lt ${#ADDRS[@]} ]; do
    n=0
    while [ $n -lt "$JOBS" ] && [ $i -lt ${#ADDRS[@]} ]; do
        run_host "${ADDRS[$i]}" "${USERS[$i]}" "${PWS[$i]}" &
        i=$((i + 1)); n=$((n + 1))
    done
    wait
done

printf '%-22s %-9s %s\n' HOST RESULT "LAST LINE"
fails=0
for addr in "${ADDRS[@]}"; do
    rc=$(cat "$OUT/$addr.rc" 2>/dev/null || echo "?"); rm -f "$OUT/$addr.rc"
    case "$rc" in 0) res="OK" ;; 255) res="SSH-FAIL"; fails=$((fails + 1)) ;; *) res="FAIL($rc)"; fails=$((fails + 1)) ;; esac
    last=$(grep -v '^CSV,' "$OUT/$addr.out" | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-70)
    printf '%-22s %-9s %s\n' "$addr" "$res" "$last"
done

if grep -qs '^CSV,' "$OUT"/*.out; then
    ( umask 077
      echo "address,hostname,user,password" > "$OUT/passwords_all.csv"
      : > "$OUT/hosts.updated"
      idx=0
      for addr in "${ADDRS[@]}"; do
          sed -n "s/^CSV,/$addr,/p" "$OUT/$addr.out" >> "$OUT/passwords_all.csv"
          newpw=$(awk -F, -v u="${USERS[$idx]}" '$1=="CSV" && $3==u {print $4}' "$OUT/$addr.out" | tail -n 1)
          [ -n "$newpw" ] || newpw="${PWS[$idx]}"
          echo "$addr ${USERS[$idx]} $newpw" >> "$OUT/hosts.updated"
          idx=$((idx + 1))
      done )
fi

[ "$fails" -eq 0 ]
