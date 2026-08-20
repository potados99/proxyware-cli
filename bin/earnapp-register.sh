#!/usr/bin/env bash
# earnapp 기기를 서버에 등록하고 "계정 연결용 링크"를 표로 출력합니다.
#
# EarnApp 기기 등록은 2단계다:
#   1) 기기를 서버에 등록  → 이 스크립트가 한다 (POST /install_device)
#   2) 계정에 연결         → 사람이 브라우저로 링크를 열어야 한다 (자동화 불가)
# 그래서 이 스크립트는 1단계를 끝내고 2단계용 링크 목록만 뽑아준다.
#
# ⚠️ 1단계를 건너뛰면 링크를 열어도 "device not found"가 뜬다.
# ⚠️ 워커는 반드시 자기 netns 안에서 등록해야 한다(서버가 출처 IP를 기기에 묶는다).
# ⚠️ 반드시 POST. GET은 404다.
#
# 사용법:
#   earnapp-register.sh                 # 워커 전체 + 호스트 (설정된 것 자동 발견)
#   earnapp-register.sh 01 03 host      # 지정한 것만
set -uo pipefail

[ "$(id -u)" -eq 0 ] || { echo "root로 실행하세요 (sudo)." >&2; exit 1; }

BIN=/usr/local/bin/earnapp
API="https://client.earnapp.com/install_device"
RETRIES="${RETRIES:-4}"        # http=000(연결 실패)이 종종 난다. 재시도 필수.
SLEEP_BETWEEN="${SLEEP_BETWEEN:-4}"

[ -x "$BIN" ] || { echo "$BIN 이 없습니다." >&2; exit 1; }

# 버전은 바이너리에서 읽는다("earnapp-ssl3 1.651.510" → 1.651.510). 하드코딩하면 어긋난다.
VER="$("$BIN" --version 2>/dev/null | awk '{print $NF}')"
[ -n "$VER" ] || { echo "버전을 읽지 못했습니다." >&2; exit 1; }

# 라즈베리파이 하드웨어 시리얼의 sha1. 공식 install.sh와 같은 방식.
# (같은 Pi의 기기들은 값이 같다 — LXC 시절에도 그랬고 문제된 적 없다. 위조하지 말 것.)
SERIAL="unknown"
SFILE=/sys/firmware/devicetree/base/serial-number
[ -f "$SFILE" ] && SERIAL="$(shasum < "$SFILE" 2>/dev/null | awk '{print $1}')"

# "Debian GNU/Linux 13 (trixie)" → 공백은 +, 슬래시는 %2F (관측된 인코딩과 동일)
OS_RAW="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Linux}")"
OS_ENC="$(printf '%s' "$OS_RAW" | sed 's|/|%2F|g; s| |+|g')"

ARCH="$(uname -m)"
case "$ARCH" in aarch64|arm64) ARCH=arm64 ;; x86_64|amd64) ARCH=x64 ;; esac

QUERY="version=$VER&arch=$ARCH&appid=node_earnapp.com&os=$OS_ENC"

# 등록 대상 결정
targets=()
if [ $# -gt 0 ]; then
    targets=("$@")
else
    for f in /etc/proxyware/earnapp/w*/uuid; do
        [ -e "$f" ] || continue
        d="${f%/uuid}"; b="${d##*/w}"
        targets+=("$b")
    done
    [ -f /etc/earnapp/uuid ] && targets+=("host")
fi
[ ${#targets[@]} -gt 0 ] || { echo "등록할 기기가 없습니다(먼저 install.sh로 워커를 세우세요)." >&2; exit 1; }

results=()
for t in "${targets[@]}"; do
    if [ "$t" = "host" ]; then
        dir=/etc/earnapp; ns=""; label="host"
    else
        dir="/etc/proxyware/earnapp/w$t"; ns="w$t"; label="worker$t"
    fi

    uuid="$(cat "$dir/uuid" 2>/dev/null)"
    if [ -z "$uuid" ]; then
        results+=("$label|-|-|uuid 없음(서비스를 먼저 켜세요)")
        continue
    fi

    if [ -n "$ns" ]; then
        run() { ip netns exec "$ns" "$@"; }
    else
        run() { "$@"; }
    fi

    ip_addr="$(run curl -s --max-time 10 https://ifconfig.me 2>/dev/null)"

    status="등록 실패"
    for i in $(seq 1 "$RETRIES"); do
        body="$(run curl -s --max-time 25 -X POST \
            -H 'Content-Type: application/json' \
            -d "{\"serial\":\"$SERIAL\"}" \
            "$API?uuid=$uuid&$QUERY" 2>/dev/null)"
        case "$body" in
            *'"ok"'*) status="등록 완료"; break ;;
        esac
        sleep 2
    done

    results+=("$label|${ip_addr:-?}|$uuid|$status")
    sleep "$SLEEP_BETWEEN"
done

echo
printf '%-10s %-17s %-9s %s\n' "노드" "공인 IP" "상태" "계정 연결 링크"
printf '%s\n' "------------------------------------------------------------------------------------------"
fail=0
for r in "${results[@]}"; do
    IFS='|' read -r label ip uuid status <<< "$r"
    if [ "$status" = "등록 완료" ]; then
        printf '%-10s %-17s %-9s https://earnapp.com/r/%s\n' "$label" "$ip" "$status" "$uuid"
    else
        printf '%-10s %-17s %-9s %s\n' "$label" "$ip" "$status" "-"
        fail=1
    fi
done
echo
echo "위 링크를 EarnApp 로그인 상태에서 하나씩 여세요(한 번에 몰아 열지 마세요)."
echo "기기 이름은 CLI로 못 정합니다 — 대시보드에서 위 노드명 기준으로 rename하세요."
[ "$fail" -eq 0 ] || echo "※ 실패한 항목은 잠시 후 다시 실행하세요(RETRIES 환경변수로 재시도 횟수 조절)."
