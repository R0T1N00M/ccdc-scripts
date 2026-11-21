#!/usr/bin/env bash
# CCDC: show who is logged in, and optionally close every session except yours.
set -u

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
KILL=0; ONLY=""; YES=0
while getopts "ku:y" opt; do
    case "$opt" in
        k) KILL=1 ;;
        u) ONLY="$OPTARG" ;;
        y) YES=1 ;;
        *) echo "Usage: $0 [-k] [-u user] [-y]"; exit 1 ;;
    esac
done

mine=" "; p=$$
while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    mine="$mine$p "; p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
done
is_mine() { case "$mine" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
MYTTY=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')

echo "=== who ==="; who; echo
ssh_pids=(); ssh_desc=()
while read -r pid user args; do
    [ -n "$pid" ] || continue
    is_mine "$pid" && continue
    suser=${args#*: }; suser=${suser%%@*}
    [ -n "$ONLY" ] && [ "$suser" != "$ONLY" ] && continue
    ssh_pids+=("$pid"); ssh_desc+=("pid=$pid  $args  (process owner: $user)")
done < <(ps -eo pid=,user=,args= | awk '$3 ~ /^sshd(-session)?:$/ && $4 ~ /@/ {print}')

pts_list=()
while read -r tty; do
    [ -n "$tty" ] || continue
    [ "$tty" = "$MYTTY" ] && continue
    owner=$(ps -t "$tty" -o user= 2>/dev/null | sort | uniq -c | sort -rn | awk 'NR==1 {print $2}')
    [ -n "$ONLY" ] && [ "$owner" != "$ONLY" ] && continue
    skip=0
    for q in $(ps -t "$tty" -o pid= 2>/dev/null); do is_mine "$q" && skip=1; done
    [ "$skip" -eq 1 ] && continue
    pts_list+=("$tty")
done < <(ps -eo tty= | grep '^pts/' | sort -u)

echo "=== Other SSH sessions (${#ssh_pids[@]}) ==="
for d in ${ssh_desc[@]+"${ssh_desc[@]}"}; do echo "  $d"; done
echo
echo "=== Other terminals (${#pts_list[@]}) ==="
for t in ${pts_list[@]+"${pts_list[@]}"}; do
    echo "  $t:"; ps -t "$t" -o user=,pid=,args= 2>/dev/null | sed 's/^/      /' | cut -c1-150
done
echo "Your own session (terminal ${MYTTY:-none}) is never touched."

[ "$KILL" -eq 1 ] || { echo "List only. Add -k to close the sessions above."; exit 0; }
if [ $(( ${#ssh_pids[@]} + ${#pts_list[@]} )) -eq 0 ]; then echo "Nothing to close."; exit 0; fi
if [ -n "${TMUX:-}" ] || [ -n "${STY:-}" ]; then
    echo "You are inside tmux/screen. Run this from a plain SSH login."; exit 1
fi
if [ "$YES" -ne 1 ]; then
    printf 'Type YES to close everything listed above: '
    read -r ans
    [ "$ans" = "YES" ] || { echo "Aborted. Nothing closed."; exit 1; }
fi

descendants() {
    local k
    for k in $(ps -eo pid=,ppid= | awk -v p="$1" '$2 == p {print $1}'); do echo "$k"; descendants "$k"; done
}
for pid in ${ssh_pids[@]+"${ssh_pids[@]}"}; do
    tree=$(descendants "$pid")
    if kill -KILL "$pid" 2>/dev/null; then
        [ -n "$tree" ] && kill -KILL $tree 2>/dev/null
        echo "[ OK ] closed SSH session pid $pid"
    else echo "[skip] pid $pid already gone"; fi
done
for t in ${pts_list[@]+"${pts_list[@]}"}; do
    if pkill -KILL -t "$t" 2>/dev/null; then echo "[ OK ] closed terminal $t"; else echo "[skip] $t already gone"; fi
done
echo "Done."
