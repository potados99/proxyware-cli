#!/usr/bin/env bash
# honeygain을 실행 파일 + 의존 라이브러리 + systemd 서비스로 설치합니다. Docker 없이 동작합니다.
# honeygain은 동적 링크라 extract.sh가 바이너리(honeygain)와 함께
# libhg.so.2.0.0, libmsquic.so.2 를 같이 뽑아둡니다. tarball을 받아서 통째로 깝니다.
#
# 사용법 (root):
#   install.sh --runtime <tarball-경로-or-URL> \
#     --email <EMAIL> --password <PASSWORD> --device-name <NAME>
set -euo pipefail

REPO="potados99/proxyware-cli"
BASE_URL="https://raw.githubusercontent.com/$REPO/main"
ENV_FILE="/etc/default/honeygain"
PREFIX="/opt/honeygain"   # 바이너리와 .so를 한 폴더에 모아 둡니다 (ldconfig를 건드리지 않습니다).
SYSTEMD_DIR="/etc/systemd/system"

# 공통 함수를 불러옵니다. 저장소 안에서 실행하면 로컬 파일을, 아니면 내려받아서 씁니다.
HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -n "$HERE" ] && [ -f "$HERE/../../lib/common.sh" ]; then
    . "$HERE/../../lib/common.sh"
else
    if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "$BASE_URL/lib/common.sh"); else . <(wget -qO- "$BASE_URL/lib/common.sh"); fi
fi

ARG_RUNTIME=""; ARG_EMAIL=""; ARG_PASSWORD=""; ARG_DEVICE=""
while [ $# -gt 0 ]; do case "$1" in
    --runtime)     ARG_RUNTIME="$2";  shift 2 ;;
    --email)       ARG_EMAIL="$2";    shift 2 ;;
    --password)    ARG_PASSWORD="$2"; shift 2 ;;
    --device-name) ARG_DEVICE="$2";   shift 2 ;;
    *) echo "모르는 옵션: $1" >&2; exit 1 ;;
esac; done

need_root

# 런타임 설치 — tarball 안에 honeygain 실행 파일과 .so 두 개가 들어 있습니다.
# 한 폴더(/opt/honeygain)에 같이 풀고, 서비스에서 LD_LIBRARY_PATH로 잡습니다.
[ -n "$ARG_RUNTIME" ] || { echo "--runtime 이 필요합니다 (extract.sh 산출물)." >&2; exit 1; }
mkdir -p "$PREFIX"
tb="$(mktemp)"
case "$ARG_RUNTIME" in
    http://*|https://*) fetch "$tb" "$ARG_RUNTIME" ;;
    *) [ -f "$ARG_RUNTIME" ] || { echo "런타임 파일이 없습니다: $ARG_RUNTIME" >&2; exit 1; }; cp "$ARG_RUNTIME" "$tb" ;;
esac
tar -C "$PREFIX" -xzf "$tb"
rm -f "$tb"
chmod +x "$PREFIX/honeygain"
[ -f "$PREFIX/libhg.so.2.0.0" ] || { echo "런타임 구성이 이상합니다 (libhg.so.2.0.0 없음)." >&2; exit 1; }

# 자격증명 — 3개를 모두 주면 새로 쓰고, 안 주면 기존 파일이 있어야 합니다.
if [ -n "$ARG_EMAIL" ] && [ -n "$ARG_PASSWORD" ] && [ -n "$ARG_DEVICE" ]; then
    write_env "$ENV_FILE" "EMAIL=$ARG_EMAIL
PASSWORD=$ARG_PASSWORD
DEVICE_NAME=$ARG_DEVICE"
elif [ ! -f "$ENV_FILE" ]; then
    echo "--email --password --device-name 이 필요합니다 (https://dashboard.honeygain.com)." >&2; exit 1
fi

# 서비스 + watchdog 유닛 설치
for u in honeygain.service honeygain-watchdog.service honeygain-watchdog.timer; do
    fetch "$SYSTEMD_DIR/$u" "$BASE_URL/apps/honeygain/systemd/$u"
done
fetch /usr/local/bin/honeygain-watchdog.sh "$BASE_URL/apps/honeygain/watchdog.sh"
chmod +x /usr/local/bin/honeygain-watchdog.sh

enable_now honeygain.service honeygain-watchdog.timer

echo "완료. 상태: systemctl status honeygain --no-pager"
echo "      로그: journalctl -u honeygain -f"
