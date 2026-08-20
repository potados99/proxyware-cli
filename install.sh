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
#     --earnapp \
#     --kuma-url https://status.example.com --kuma-user u --kuma-pass p
#   (Kuma 대신 직접 줄 수도: --pawns-hb <URL> --earnfm-hb <URL> --earnapp-hb <URL>)
#
# earnapp은 계정 자격증명이 필요 없습니다(기기 식별자가 uuid 파일 하나). --earnapp만 주면
# 설치되고, 설치 후 sudo earnapp-register.sh 로 등록하고 계정 연결 링크를 받으세요.
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

# 바이너리가 없으면 Release에서 받습니다 (arm64).
# honeygain은 동적 링크(.so 동봉)라 /opt/honeygain에 통째로 풉니다.
ensure_runtime() {  # ensure_runtime <pawns|earnfm|honeygain>
    local app="$1" tb
    case "$app" in
    honeygain)
        [ -x /opt/honeygain/honeygain ] && return 0
        mkdir -p /opt/honeygain
        tb="$(mktemp)"; fetch "$tb" "$REL_URL/honeygain-runtime-arm64.tar.gz"
        tar -C /opt/honeygain -xzf "$tb"; rm -f "$tb"; chmod +x /opt/honeygain/honeygain
        ;;
    *)
        [ -x "$BIN/$app" ] && return 0
        tb="$(mktemp)"; fetch "$tb" "$REL_URL/$app-runtime-arm64.tar.gz"
        tar -C "$BIN" -xzf "$tb"; rm -f "$tb"; chmod +x "$BIN/$app"
        ;;
    esac
}

# 공통 토대: 스크립트/유닛/워치독 + NM 영구화. 멱등이라 여러 번 호출해도 안전합니다.
ensure_base() {  # ensure_base <parent-nic>
    local parent="$1"
    mkdir -p "$PROX_DIR" "$SBIN"
    put net/proxyns-up        "$SBIN/proxyns-up"            755
    put net/proxyns-down      "$SBIN/proxyns-down"          755
    put net/udhcpc.script     "$PROX_DIR/udhcpc.script"     755
    put net/resolv.conf       "$PROX_DIR/resolv.conf"       644
    for u in worker-net@ worker-dhcp@ pawns-worker@ earnfm-worker@ honeygain-worker@ earnapp-worker@; do
        put "systemd/$u.service" "$UNIT/$u.service"
    done
    put systemd/proxyware.slice              "$UNIT/proxyware.slice"
    put systemd/proxyware-watchdog.service   "$UNIT/proxyware-watchdog.service"
    put systemd/proxyware-watchdog.timer     "$UNIT/proxyware-watchdog.timer"
    put bin/proxyware-watchdog.sh            "$BIN/proxyware-watchdog.sh"  755

    # earnapp FD 누수 감시 (earnapp을 안 쓰는 호스트에서도 유닛만 깔려 있고 유휴다)
    put bin/earnapp-fd-monitor.sh            "$BIN/earnapp-fd-monitor.sh"   755
    put bin/earnapp-register.sh              "$BIN/earnapp-register.sh"     755
    put systemd/earnapp-fd-monitor.service   "$UNIT/earnapp-fd-monitor.service"
    put systemd/earnapp-fd-monitor.timer     "$UNIT/earnapp-fd-monitor.timer"

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

# earnapp 기기 디렉토리를 준비합니다.
# ⚠️ consent/status/ver 세 파일이 없으면 `earnapp run`이 exit 1로 즉사해 무한 재시작만 돕니다
#    (uuid는 스스로 만들지만 consent가 없으면 시작 자체를 거부한다 — 2026-08-20 실측).
# ver은 바이너리에서 읽어 어긋나지 않게 합니다. uuid는 첫 기동 때 자동 생성됩니다.
earnapp_seed() {  # earnapp_seed <dir>
    local d="$1" ver
    ver="$("$BIN/earnapp" --version 2>/dev/null | awk '{print $NF}')"
    mkdir -p "$d"
    [ -f "$d/consent" ] || printf '1:%s\n' "$(date +%s%3N)" > "$d/consent"
    [ -f "$d/status" ]  || echo enabled > "$d/status"
    printf '%s\n' "${ver:-unknown}" > "$d/ver"
}

# 벤더 자동 업그레이더는 끕니다. 버전 관리 주체는 proxyware-cli이고,
# 업그레이더 자체가 1대당 약 59MB를 더 씁니다. (공식 install.sh를 돌린 흔적이 있으면 존재)
earnapp_mask_vendor() {
    systemctl disable --now earnapp.service earnapp_upgrader.service >/dev/null 2>&1 || true
    systemctl mask earnapp.service earnapp_upgrader.service >/dev/null 2>&1 || true
}

# ---- 인자 파싱 ----
[ $# -ge 1 ] || { echo "사용법: install.sh <worker|host> [옵션...]" >&2; exit 1; }
CMD="$1"; shift
ID=""; MAC=""; PARENT="eth0"
P_EMAIL=""; P_PASS=""; P_DEVID=""; P_DEVNAME=""; E_TOKEN=""
P_HB=""; E_HB=""; KUMA_URL=""; KUMA_USER=""; KUMA_PASS=""
HG_EMAIL=""; HG_PASS=""; HG_DEV=""; HG_HB=""
EARNAPP=0; EA_HB=""
while [ $# -gt 0 ]; do case "$1" in
    --id)              ID="$2"; shift 2 ;;
    --mac)             MAC="$2"; shift 2 ;;
    --parent)          PARENT="$2"; shift 2 ;;
    --pawns-email)     P_EMAIL="$2"; shift 2 ;;
    --pawns-pass)      P_PASS="$2"; shift 2 ;;
    --device-id)       P_DEVID="$2"; shift 2 ;;
    --device-name)     P_DEVNAME="$2"; shift 2 ;;
    --earnfm-token)    E_TOKEN="$2"; shift 2 ;;
    --honeygain-email) HG_EMAIL="$2"; shift 2 ;;
    --honeygain-pass)  HG_PASS="$2"; shift 2 ;;
    --honeygain-device) HG_DEV="$2"; shift 2 ;;
    --pawns-hb)        P_HB="$2"; shift 2 ;;
    --earnfm-hb)       E_HB="$2"; shift 2 ;;
    --honeygain-hb)    HG_HB="$2"; shift 2 ;;
    --earnapp)         EARNAPP=1; shift ;;
    --earnapp-hb)      EA_HB="$2"; EARNAPP=1; shift 2 ;;
    --kuma-url)        KUMA_URL="$2"; shift 2 ;;
    --kuma-user)       KUMA_USER="$2"; shift 2 ;;
    --kuma-pass)       KUMA_PASS="$2"; shift 2 ;;
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

    # honeygain (선택): --honeygain-email 을 주면 같은 IP에 함께 띄웁니다.
    if [ -n "$HG_EMAIL" ]; then
        ensure_runtime honeygain
        : "${HG_DEV:=$P_DEVID}"
        write_env "/etc/default/honeygain-worker$ID" "EMAIL=$HG_EMAIL
PASSWORD=$HG_PASS
DEVICE_NAME=$HG_DEV
HEARTBEAT_URL=$HG_HB"
        systemctl enable --now "honeygain-worker@$ID"
        APPS="pawns + earnfm + honeygain"
    else
        APPS="pawns + earnfm"
    fi

    # earnapp (선택): --earnapp 을 주면 같은 IP에 함께 띄웁니다. 자격증명 불필요.
    if [ "$EARNAPP" -eq 1 ]; then
        ensure_runtime earnapp
        earnapp_mask_vendor
        earnapp_seed "$PROX_DIR/earnapp/w$ID"
        [ -n "$EA_HB" ] || EA_HB="$(kuma_hb "${P_DEVID:-worker$ID} earnapp")"
        write_env "/etc/default/earnapp-worker$ID" "HEARTBEAT_URL=$EA_HB"
        systemctl enable --now "earnapp-worker@$ID"
        systemctl enable --now earnapp-fd-monitor.timer
        APPS="$APPS + earnapp"
    fi

    echo "완료: worker$ID — $APPS"
    [ "$EARNAPP" -eq 1 ] && echo "  → earnapp 기기 등록: sudo $BIN/earnapp-register.sh $ID"
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

    if [ "$EARNAPP" -eq 1 ]; then
        ensure_runtime earnapp
        earnapp_mask_vendor
        earnapp_seed /etc/earnapp
        [ -n "$EA_HB" ] || EA_HB="$(kuma_hb "${P_DEVID:-$(hostname)} earnapp")"
        write_env "/etc/default/earnapp-host" "HEARTBEAT_URL=$EA_HB"
        put systemd/earnapp-host.service "$UNIT/earnapp-host.service"
        systemctl daemon-reload
        systemctl enable --now earnapp-host.service earnapp-fd-monitor.timer
        echo "완료: host — pawns + earnfm + earnapp"
        echo "  → earnapp 기기 등록: sudo $BIN/earnapp-register.sh host"
    else
        echo "완료: host — systemctl status pawns-host earnfm-host"
    fi
    ;;
*) echo "모르는 서브커맨드: $CMD (worker|host)" >&2; exit 1 ;;
esac
