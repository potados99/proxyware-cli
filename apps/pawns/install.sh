#!/usr/bin/env bash
# pawns(IPRoyal Pawns)를 단일 실행 파일 + systemd 서비스로 설치합니다. Docker 없이 동작합니다.
# extract.sh로 뽑은 런타임(tarball)을 받아서 /usr/local/bin/pawns 로 깝니다.
#
# 사용법 (root):
#   install.sh --runtime <tarball-경로-or-URL> \
#     --email <EMAIL> --password <PASSWORD> --device-name <NAME> --device-id <ID>
set -euo pipefail

REPO="potados99/proxyware-cli"
BASE_URL="https://raw.githubusercontent.com/$REPO/main"
ENV_FILE="/etc/default/pawns"
BIN="/usr/local/bin/pawns"
SYSTEMD_DIR="/etc/systemd/system"

# 공통 함수를 불러옵니다. 저장소 안에서 실행하면 로컬 파일을, 아니면 내려받아서 씁니다.
HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -n "$HERE" ] && [ -f "$HERE/../../lib/common.sh" ]; then
    . "$HERE/../../lib/common.sh"
else
    if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "$BASE_URL/lib/common.sh"); else . <(wget -qO- "$BASE_URL/lib/common.sh"); fi
fi

ARG_RUNTIME=""; ARG_EMAIL=""; ARG_PASSWORD=""; ARG_DEVICE=""; ARG_DEVICE_ID=""
while [ $# -gt 0 ]; do case "$1" in
    --runtime)     ARG_RUNTIME="$2";   shift 2 ;;
    --email)       ARG_EMAIL="$2";     shift 2 ;;
    --password)    ARG_PASSWORD="$2";  shift 2 ;;
    --device-name) ARG_DEVICE="$2";    shift 2 ;;
    --device-id)   ARG_DEVICE_ID="$2"; shift 2 ;;
    *) echo "모르는 옵션: $1" >&2; exit 1 ;;
esac; done

need_root

# 런타임 설치 — tarball 안에 pawns 실행 파일이 들어 있습니다.
[ -n "$ARG_RUNTIME" ] || { echo "--runtime 이 필요합니다 (extract.sh 산출물)." >&2; exit 1; }
tb="$(mktemp)"
case "$ARG_RUNTIME" in
    http://*|https://*) fetch "$tb" "$ARG_RUNTIME" ;;
    *) [ -f "$ARG_RUNTIME" ] || { echo "런타임 파일이 없습니다: $ARG_RUNTIME" >&2; exit 1; }; cp "$ARG_RUNTIME" "$tb" ;;
esac
tar -C /usr/local/bin -xzf "$tb"
rm -f "$tb"
chmod +x "$BIN"

# 자격증명 — 4개를 모두 주면 새로 쓰고, 안 주면 기존 파일이 있어야 합니다.
if [ -n "$ARG_EMAIL" ] && [ -n "$ARG_PASSWORD" ] && [ -n "$ARG_DEVICE" ] && [ -n "$ARG_DEVICE_ID" ]; then
    write_env "$ENV_FILE" "EMAIL=$ARG_EMAIL
PASSWORD=$ARG_PASSWORD
DEVICE_NAME=$ARG_DEVICE
DEVICE_ID=$ARG_DEVICE_ID"
elif [ ! -f "$ENV_FILE" ]; then
    echo "--email --password --device-name --device-id 가 필요합니다 (https://pawns.app)." >&2; exit 1
fi

# 서비스 + watchdog 유닛 설치
for u in pawns.service pawns-watchdog.service pawns-watchdog.timer; do
    fetch "$SYSTEMD_DIR/$u" "$BASE_URL/apps/pawns/systemd/$u"
done
fetch /usr/local/bin/pawns-watchdog.sh "$BASE_URL/apps/pawns/watchdog.sh"
chmod +x /usr/local/bin/pawns-watchdog.sh

enable_now pawns.service pawns-watchdog.timer

echo "완료. 상태: systemctl status pawns --no-pager"
echo "      로그: journalctl -u pawns -f"
