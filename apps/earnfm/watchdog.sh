#!/usr/bin/env bash
# earnfm이 멈췄는지 봅니다. (5분마다 timer가 실행합니다)
# earnfm은 정상일 때 프록시 세션 로그가 계속 쌓입니다. 그래서 서비스가 떠 있는데도
# 일정 시간(기본 10분) 로그가 하나도 없으면 멈춘 것으로 보고 다시 시작합니다.
# 외부 파일에 기대지 않도록 필요한 함수는 이 파일 안에 두었습니다.
set -u

UNIT="earnfm.service"
WINDOW=600   # 이 시간(초) 동안 로그가 전혀 없으면 멈춘 것으로 봅니다.

# 서비스가 떠 있지 않으면 systemd가 알아서 하므로 여기서는 손대지 않습니다.
[ "$(systemctl is-active "$UNIT" 2>/dev/null)" = "active" ] || exit 0

lines="$(journalctl -u "$UNIT" --since "-${WINDOW}s" -o cat 2>/dev/null | wc -l)"
if [ "${lines:-0}" -eq 0 ]; then
    logger -t earnfm-watchdog "최근 ${WINDOW}초간 로그가 없어 재시작합니다."
    systemctl restart "$UNIT"
fi
