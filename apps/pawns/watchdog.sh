#!/usr/bin/env bash
# pawns가 멈췄는지 봅니다. (5분마다 timer가 실행합니다)
#
# pawns는 조용해도(silence) 정상입니다. 그래서 earnfm식 "로그 없으면 재시작"을 쓰면 안 됩니다.
# 대신 라이프사이클 이벤트(running / not_running)의 가장 최근 상태로 판정합니다.
#   - 최근 이벤트가 running 이면: 조용해도 정상이므로 절대 재시작하지 않습니다.
#   - 최근 이벤트가 not_running 이고 5분 넘게 지속되면: 터널이 끊긴 채 멈춘 것이라 재시작합니다.
#     (websocket close, could_not_mark_peer_alive 등으로 active인 채 몇 시간 멈추는 사례가 있습니다)
#   - 서비스 시작 후 한 번도 running/not_running 에 도달 못 한 채 active만 오래 지속되면:
#     터널을 열기 전에 멈춘 것이라 재시작합니다. (예: 호스트 재부팅 직후 dial hang)
# 외부 파일에 기대지 않도록 필요한 값은 이 파일 안에 두었습니다.
set -u

UNIT="pawns.service"
NOT_RUNNING_GRACE=300   # not_running이 이 시간(초) 넘게 지속되면 멈춘 것으로 보고 재시작합니다.

# 서비스가 떠 있지 않으면 systemd가 알아서 하므로 여기서는 손대지 않습니다.
[ "$(systemctl is-active "$UNIT" 2>/dev/null)" = "active" ] || exit 0

# 서비스가 active로 진입한 시각부터의 이벤트만 봅니다.
ENTER=$(date -d "$(systemctl show -p ActiveEnterTimestamp --value "$UNIT")" +%s 2>/dev/null || echo 0)
NOW=$(date +%s)
UP=$(( ENTER > 0 ? NOW - ENTER : 0 ))
LAST_EVT=$(journalctl -u "$UNIT" --since "@$ENTER" --no-pager -o cat 2>/dev/null \
    | grep -oE '"name":"(running|not_running)"' | tail -1 || true)

if [ "$LAST_EVT" = '"name":"not_running"' ]; then
    # 터널이 현재 끊긴 상태입니다. 잠깐의 자가 복구 여유를 준 뒤 그래도 안 되면 재시작합니다.
    NR_TS=$(journalctl -u "$UNIT" --since "@$ENTER" --no-pager -o short-unix 2>/dev/null \
        | grep not_running | tail -1 | awk '{print int($1)}')
    DOWN_FOR=$(( ${NR_TS:-0} > 0 ? NOW - NR_TS : 0 ))
    if [ "$DOWN_FOR" -gt "$NOT_RUNNING_GRACE" ]; then
        logger -t pawns-watchdog "not_running 상태가 ${DOWN_FOR}초 지속되어 재시작합니다."
        systemctl restart "$UNIT"
    fi
    exit 0
fi

if [ -z "$LAST_EVT" ] && [ "$UP" -gt 180 ]; then
    # active인데 running/not_running 에 한 번도 도달 못 함 — 터널을 열기 전에 멈춘 상태입니다.
    logger -t pawns-watchdog "active ${UP}초이나 running에 도달하지 못해 재시작합니다."
    systemctl restart "$UNIT"
    exit 0
fi

# 최근 이벤트가 running 이거나, 막 시작해서(180초 미만) 아직 이벤트가 없는 경우 → 정상입니다.
exit 0
