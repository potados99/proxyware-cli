#!/usr/bin/env bash
# repocket 헬스체크 + Kuma heartbeat입니다. (5분마다 timer가 실행합니다)
# repocket은 정상일 때 연결 모니터/PING 로그가 주기적으로 쌓입니다. 그래서 서비스가 떠 있는데도
# 일정 시간(기본 10분) 로그가 하나도 없으면 멈춘 것으로 보고 다시 시작합니다.
# 정상일 때는 HEARTBEAT_URL(설정돼 있으면)로 핑을 보냅니다. 멈춰서 재시작할 땐 핑을 보내지
# 않으므로, Uptime Kuma가 그 사이 다운을 감지합니다.
# 외부 파일에 기대지 않도록 판정 로직은 이 파일 안에 두었습니다.
set -u

UNIT="repocket.service"
WINDOW=600   # 이 시간(초) 동안 로그가 전혀 없으면 멈춘 것으로 봅니다.

# HEARTBEAT_URL을 읽어 옵니다. 없으면 핑은 생략합니다.
[ -f /etc/default/repocket ] && . /etc/default/repocket

# 서비스가 떠 있지 않으면 systemd가 알아서 하므로 여기서는 손대지 않습니다.
[ "$(systemctl is-active "$UNIT" 2>/dev/null)" = "active" ] || exit 0

lines="$(journalctl -u "$UNIT" --since "-${WINDOW}s" -o cat 2>/dev/null | wc -l)"
if [ "${lines:-0}" -eq 0 ]; then
    logger -t repocket-watchdog "최근 ${WINDOW}초간 로그가 없어 재시작합니다."
    systemctl restart "$UNIT"
    exit 0
fi

# 여기까지 왔으면 정상입니다. 핑을 보냅니다.
if [ -n "${HEARTBEAT_URL:-}" ]; then
    if command -v curl >/dev/null 2>&1; then curl -fsS -m 10 "$HEARTBEAT_URL" >/dev/null 2>&1 || true
    else wget -qO- -T 10 "$HEARTBEAT_URL" >/dev/null 2>&1 || true; fi
fi
