#!/usr/bin/env bash
# proxyware-cli 설치기 (netns 방식)
#
# 컨테이너(LXC) 없이, 호스트 systemd 하나가 네트워크 네임스페이스 + macvlan으로
# 워커마다 별도 공인 IP를 주고 그 안에서 pawns/earnfm를 돌립니다.
#
# 서브커맨드:
#   worker  netns 워커 하나를 셋업 (공통 토대는 자동으로 먼저 깔립니다)
#   host    호스트 자신을 워커로 사용 (호스트 기본 네트워크로 나가는 IP 하나 추가)
#
# 워커 예:
#   sudo install.sh worker --id 01 --mac 00:16:3e:50:e5:55 \
#     --pawns-email a@b.c --pawns-pass pw --device-id side-worker01 \
#     --earnfm-token <TOKEN> \
#     --kuma-url https://status.example.com --kuma-user u --kuma-pass p
#   (Kuma 대신 직접 줄 수도: --pawns-hb <URL> --earnfm-hb <URL>)
set -euo pipefail

REPO="potados99/proxyware-cli"
BASE_URL="https://raw.githubusercontent.com/$REPO/main"
REL_URL="https://github.com/$REPO/releases/download/runtimes-arm64"
PROX_DIR="/etc/proxyware"
SBIN="/usr/local/sbin"
BIN="/usr/local/bin"
UNIT="/etc/systemd/system"

# 공통 함수 (로컬 우선, 없으면 내려받기)
HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -n "$HERE" ] && [ -f "$HERE/lib/common.sh" ]; then . "$HERE/lib/common.sh"
else
    if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "$BASE_URL/lib/common.sh")
    else . <(wget -qO- "$BASE_URL/lib/common.sh"); fi
fi

# 저장소 안에서 실행하면 로컬 파일을, 아니면 raw에서 받아 설치합니다.
put() {  # put <src-상대경로> <dest> [mode]
    local src="$1" dest="$2" mode="${3:-644}"
    if [ -n "$HERE" ] && [ -f "$HERE/$src" ]; then install -m "$mode" "$HERE/$src" "$dest"
    else fetch "$dest" "$BASE_URL/$src"; chmod "$mode" "$dest"; fi
}

# pawns/earnfm 바이너리가 없으면 Release에서 받습니다 (arm64).
ensure_runtime() {  # ensure_runtime <pawns|earnfm>
    local app="$1"; [ -x "$BIN/$app" ] && return 0
    local tb; tb="$(mktemp)"
    fetch "$tb" "$REL_URL/$app-runtime-arm64.tar.gz"
    tar -C "$BIN" -xzf "$tb"; rm -f "$tb"; chmod +x "$BIN/$app"
}

# 공통 토대: 스크립트/유닛/워치독 + NM 영구화. 멱등이라 여러 번 호출해도 안전합니다.
ensure_base() {  # ensure_base <parent-nic>
    local parent="$1"
    mkdir -p "$PROX_DIR" "$SBIN"
    put net/proxyns-up        "$SBIN/proxyns-up"            755
    put net/proxyns-down      "$SBIN/proxyns-down"          755
    put net/udhcpc.script     "$PROX_DIR/udhcpc.script"     755
    put net/resolv.conf       "$PROX_DIR/resolv.conf"       644
    for u in worker-net@ worker-dhcp@ pawns-worker@ earnfm-worker@; do
        put "systemd/$u.service" "$UNIT/$u.service"
    done
    put systemd/proxyware.slice              "$UNIT/proxyware.slice"
    put systemd/proxyware-watchdog.service   "$UNIT/proxyware-watchdog.service"
    put systemd/proxyware-watchdog.timer     "$UNIT/proxyware-watchdog.timer"
    put bin/proxyware-watchdog.sh            "$BIN/proxyware-watchdog.sh"  755

    # 부모 NIC을 NetworkManager에서 영구 unmanaged로 (macvlan 부모로 쓰기 위해).
    if [ -d /etc/NetworkManager ]; then
        printf '[keyfile]\nunmanaged-devices=interface-name:%s\n' "$parent" \
            > /etc/NetworkManager/conf.d/99-proxyware.conf
    fi
    systemctl daemon-reload
    systemctl enable --now proxyware-watchdog.timer
}

# Kuma 모니터를 보장하고 push URL을 돌려줍니다. (--kuma-* 없으면 빈 문자열)
kuma_hb() {  # kuma_hb <monitor-name>
    [ -n "$KUMA_URL" ] || { echo ""; return 0; }
    put bin/kuma-ensure.py "$BIN/kuma-ensure.py" 755
    "$BIN/kuma-ensure.py" --url "$KUMA_URL" --user "$KUMA_USER" \
        --password "$KUMA_PASS" --name "$1" 2>/dev/null || echo ""
}

# ---- 인자 파싱 ----
[ $# -ge 1 ] || { echo "사용법: install.sh <worker|host> [옵션...]" >&2; exit 1; }
CMD="$1"; shift
ID=""; MAC=""; PARENT="eth0"
P_EMAIL=""; P_PASS=""; P_DEVID=""; P_DEVNAME=""; E_TOKEN=""
P_HB=""; E_HB=""; KUMA_URL=""; KUMA_USER=""; KUMA_PASS=""
while [ $# -gt 0 ]; do case "$1" in
    --id)           ID="$2"; shift 2 ;;
    --mac)          MAC="$2"; shift 2 ;;
    --parent)       PARENT="$2"; shift 2 ;;
    --pawns-email)  P_EMAIL="$2"; shift 2 ;;
    --pawns-pass)   P_PASS="$2"; shift 2 ;;
    --device-id)    P_DEVID="$2"; shift 2 ;;
    --device-name)  P_DEVNAME="$2"; shift 2 ;;
    --earnfm-token) E_TOKEN="$2"; shift 2 ;;
    --pawns-hb)     P_HB="$2"; shift 2 ;;
    --earnfm-hb)    E_HB="$2"; shift 2 ;;
    --kuma-url)     KUMA_URL="$2"; shift 2 ;;
    --kuma-user)    KUMA_USER="$2"; shift 2 ;;
    --kuma-pass)    KUMA_PASS="$2"; shift 2 ;;
    *) echo "모르는 옵션: $1" >&2; exit 1 ;;
esac; done

need_root
ensure_runtime pawns
ensure_runtime earnfm
ensure_base "$PARENT"

case "$CMD" in
worker)
    [ -n "$ID" ] && [ -n "$MAC" ] || { echo "--id 와 --mac 이 필요합니다." >&2; exit 1; }
    : "${P_DEVNAME:=$P_DEVID}"

    # netns 설정 (MAC + 부모 NIC)
    printf 'MAC=%s\nPARENT=%s\n' "$MAC" "$PARENT" > "$PROX_DIR/w$ID.netconf"

    # heartbeat URL: 직접 준 게 없으면 Kuma에서 보장
    [ -n "$P_HB" ] || P_HB="$(kuma_hb "side-worker$ID-pawns")"
    [ -n "$E_HB" ] || E_HB="$(kuma_hb "side-worker$ID-earnfm")"

    write_env "/etc/default/pawns-worker$ID" "EMAIL=$P_EMAIL
PASSWORD=$P_PASS
DEVICE_NAME=$P_DEVNAME
DEVICE_ID=$P_DEVID
HEARTBEAT_URL=$P_HB"
    write_env "/etc/default/earnfm-worker$ID" "EARNFM_TOKEN=$E_TOKEN
HEARTBEAT_URL=$E_HB"

    systemctl enable --now "worker-net@$ID" "worker-dhcp@$ID"
    systemctl enable --now "pawns-worker@$ID" "earnfm-worker@$ID"
    echo "완료: worker$ID — systemctl status pawns-worker@$ID earnfm-worker@$ID"
    ;;
host)
    # 호스트 자신을 워커로 (netns 없이 호스트 기본 네트워크로 나감).
    [ -n "$P_HB" ] || P_HB="$(kuma_hb "$(hostname)-pawns")"
    [ -n "$E_HB" ] || E_HB="$(kuma_hb "$(hostname)-earnfm")"
    : "${P_DEVNAME:=$(hostname)}"
    write_env "/etc/default/pawns-host" "EMAIL=$P_EMAIL
PASSWORD=$P_PASS
DEVICE_NAME=$P_DEVNAME
DEVICE_ID=${P_DEVID:-$(hostname)}
HEARTBEAT_URL=$P_HB"
    write_env "/etc/default/earnfm-host" "EARNFM_TOKEN=$E_TOKEN
HEARTBEAT_URL=$E_HB"
    put systemd/pawns-host.service  "$UNIT/pawns-host.service"
    put systemd/earnfm-host.service "$UNIT/earnfm-host.service"
    systemctl daemon-reload
    systemctl enable --now pawns-host.service earnfm-host.service
    echo "완료: host — systemctl status pawns-host earnfm-host"
    ;;
*) echo "모르는 서브커맨드: $CMD (worker|host)" >&2; exit 1 ;;
esac
