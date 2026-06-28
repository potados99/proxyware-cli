#!/usr/bin/env bash
# honeygain이 멈췄는지 봅니다. (5분마다 timer가 실행합니다)
#
# honeygain은 정상일 때도 오래 조용합니다(연결/해제/오류 때만 로그를 남깁니다).
# 그래서 silence는 고장이 아닙니다. 멀쩡한 honeygain을 재시작하면 서버에서
# "device name already active" 충돌이 나고, 그게 연쇄 실패로 번집니다.
# 따라서 silence로는 절대 재시작하지 않고, 실제 오류 폭주일 때만 재시작합니다.
#
# 특히 device_limit(계정 디바이스 한도 초과) 상태는 재시작으로 절대 못 고칩니다.
# 오히려 ghost 세션 충돌로 더 망가지므로, 이 경우엔 손대지 않고 그대로 둡니다.
# 외부 파일에 기대지 않도록 필요한 값은 이 파일 안에 두었습니다.
set -u

UNIT="honeygain.service"
ERROR_TAIL=10   # 최근 이만큼의 줄이 전부 오류면 오류 폭주로 봅니다.

# HEARTBEAT_URL 줄만 뽑아 옵니다(자격증명까지 통째로 source하지 않도록). 없으면 핑은 생략합니다.
HEARTBEAT_URL="$(sed -n 's/^HEARTBEAT_URL=//p' /etc/default/honeygain 2>/dev/null | tr -d '"')"

# 서비스가 실패 상태(죽음)인 경우
if [ "$(systemctl is-active "$UNIT" 2>/dev/null)" != "active" ]; then
    if systemctl is-failed --quiet "$UNIT"; then
        LAST_LOG="$(journalctl -u "$UNIT" -n 3 --no-pager -o cat 2>/dev/null)"
        if echo "$LAST_LOG" | grep -q "device_limit_exceeded"; then
            # 디바이스 한도 초과 — 재시작으로 절대 못 고칩니다. 건드리지 않고 둡니다.
            logger -t honeygain-watchdog "device_limit 상태이므로 재시작하지 않습니다."
        else
            # 이름 충돌 / 연결 종료 등은 몇 분 안에 자가 복구되므로 다시 띄웁니다.
            systemctl reset-failed "$UNIT"
            systemctl start "$UNIT"
            logger -t honeygain-watchdog "실패 상태에서 다시 시작합니다."
        fi
    fi
    exit 0
fi

# 프로세스는 살아 있는 경우: 진짜 고장 신호는 API 오류 폭주뿐입니다.
# (프로세스는 떠 있는데 최근 줄이 전부 오류) — 이때만 재시작합니다.
RECENT="$(journalctl -u "$UNIT" -n "$ERROR_TAIL" --no-pager -o cat 2>/dev/null)"
TOTAL="$(echo "$RECENT" | wc -l)"
ERRORS="$(echo "$RECENT" | grep -c "API Ping Error" || true)"

if [ "${TOTAL:-0}" -ge "$ERROR_TAIL" ] && [ "${ERRORS:-0}" -eq "${TOTAL:-0}" ]; then
    logger -t honeygain-watchdog "API 오류 폭주(${ERRORS}/${TOTAL})로 재시작합니다."
    systemctl restart "$UNIT"
    exit 0
fi

# 프로세스가 살아 있고 오류 폭주도 아니면 → 정상입니다 (조용해도 정상).
# 정상이므로 핑을 보냅니다.
if [ -n "${HEARTBEAT_URL:-}" ]; then
    if command -v curl >/dev/null 2>&1; then curl -fsS -m 10 "$HEARTBEAT_URL" >/dev/null 2>&1 || true
    else wget -qO- -T 10 "$HEARTBEAT_URL" >/dev/null 2>&1 || true; fi
fi
exit 0
