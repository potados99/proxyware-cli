#!/usr/bin/env bash
# earnapp FD 누수 감시 & 자동 종료
#
# earnapp은 파일 디스크립터를 누수시킨 전력이 있다(2026-03 LXC 시절, 원본:
# github.com/potados/earnapp-fd-monitor). 임계치를 넘은 프로세스를 kill하면
# systemd의 Restart=always가 새로 띄운다.
#
# ⚠️ 임계치 주의(2026-08-20 실측): earnapp은 릴레이 프록시라 **정상 부하에서도 FD가 많다** —
#    평시 26~62, 스파이크 110~127. 원본의 임계치 100은 건강한 워커를 죽인다(실제로 2대가
#    kill됐다). 그래서 500으로 올렸다. 누수는 이보다 훨씬 크게 자라므로 충분히 잡힌다.
#    FD 상한은 systemd 기본 524288이라 "상한 도달"로는 판정할 수 없다.
#
# 사용법: earnapp-fd-monitor.sh [--dry-run] [--verbose]
set -uo pipefail

DRY_RUN=0
VERBOSE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help) echo "사용법: $0 [--dry-run] [--verbose]"; exit 0 ;;
        *) echo "모르는 옵션: $1" >&2; exit 1 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "root로 실행하세요 (sudo)." >&2; exit 1; }

FD_THRESHOLD="${FD_THRESHOLD:-500}"
MINIMUM_UPTIME="${MINIMUM_UPTIME:-300}"   # 기동 직후는 건드리지 않는다(초)
# proxyware-cli는 /usr/local/bin에 깔지만, 공식 install.sh를 쓴 흔적이 있으면 /usr/bin에도 있다.
TARGETS="/usr/local/bin/earnapp /usr/bin/earnapp"

TS="$(date '+%Y-%m-%d %H:%M:%S')"
[ "$DRY_RUN" -eq 1 ] && echo "[$TS] DRY RUN — 아무것도 죽이지 않습니다"

# ps etime([[DD-]HH:]MM:SS) → 초
uptime_to_seconds() {
    local e="${1// /}" d=0 h=0 m=0 s=0 parts
    case "$e" in *-*) d="${e%%-*}"; e="${e#*-}" ;; esac
    IFS=':' read -ra parts <<< "$e"
    case ${#parts[@]} in
        3) h="${parts[0]}"; m="${parts[1]}"; s="${parts[2]}" ;;
        2) m="${parts[0]}"; s="${parts[1]}" ;;
        1) s="${parts[0]}" ;;
    esac
    echo $((10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s))
}

pids=""
for t in $TARGETS; do
    pids="$pids $(pgrep -f "^$t" 2>/dev/null)"
done
pids="$(echo "$pids" | tr ' ' '\n' | grep -v '^$' | sort -u)"
[ -n "$pids" ] || exit 0

for pid in $pids; do
    [ -d "/proc/$pid" ] || continue

    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null)"
    match=0
    for t in $TARGETS; do [ "$exe" = "$t" ] && match=1; done
    [ "$match" -eq 1 ] || continue

    et="$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ')"
    [ -n "$et" ] || continue
    [ "$(uptime_to_seconds "$et")" -lt "$MINIMUM_UPTIME" ] && continue

    fd="$(ls "/proc/$pid/fd" 2>/dev/null | wc -l)"
    [ "$VERBOSE" -eq 1 ] && echo "[$TS] PID $pid — FD $fd / 임계 $FD_THRESHOLD — 업타임 $et"
    [ "$fd" -gt "$FD_THRESHOLD" ] || continue

    sockets="$(ls -l "/proc/$pid/fd" 2>/dev/null | grep -c socket)"
    mem="$(grep -E '^(VmRSS|VmSize):' "/proc/$pid/status" 2>/dev/null | tr '\n' ' ')"
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[$TS] [DRY RUN] KILL 대상 PID $pid — FD 임계 초과"
    else
        echo "[$TS] KILLING PID $pid — FD 임계 초과"
    fi
    echo "  └─ 실행파일: $exe"
    echo "  └─ 커맨드: $cmd"
    echo "  └─ FD: $fd (임계 $FD_THRESHOLD), 소켓: $sockets"
    echo "  └─ 메모리: $mem"
    echo "  └─ 업타임: $et"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  └─ [DRY RUN] kill 생략"
    elif kill -9 "$pid" 2>/dev/null; then
        echo "  └─ kill 완료 (systemd Restart=always가 재기동)"
    else
        echo "  └─ kill 실패"
    fi
    echo
done
