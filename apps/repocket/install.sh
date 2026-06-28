#!/usr/bin/env bash
# repocket을 node 런타임 + systemd 서비스로 설치합니다. Docker 없이 동작합니다.
# repocket은 Node.js 앱이라 extract.sh가 node 실행 파일과 /app을 함께 뽑아둡니다.
#
# 사용법 (root):
#   install.sh --runtime <tarball-경로-or-URL> --email <RP_EMAIL> --api-key <RP_API_KEY>
set -euo pipefail

REPO="potados99/proxyware-cli"
BASE_URL="https://raw.githubusercontent.com/$REPO/main"
ENV_FILE="/etc/default/repocket"
PREFIX="/opt/repocket"
SYSTEMD_DIR="/etc/systemd/system"

# 공통 함수를 불러옵니다. 저장소 안에서 실행하면 로컬 파일을, 아니면 내려받아서 씁니다.
HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -n "$HERE" ] && [ -f "$HERE/../../lib/common.sh" ]; then
    . "$HERE/../../lib/common.sh"
else
    if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "$BASE_URL/lib/common.sh"); else . <(wget -qO- "$BASE_URL/lib/common.sh"); fi
fi

ARG_RUNTIME=""; ARG_EMAIL=""; ARG_KEY=""
while [ $# -gt 0 ]; do case "$1" in
    --runtime) ARG_RUNTIME="$2"; shift 2 ;;
    --email)   ARG_EMAIL="$2";   shift 2 ;;
    --api-key) ARG_KEY="$2";     shift 2 ;;
    *) echo "모르는 옵션: $1" >&2; exit 1 ;;
esac; done

need_root

# 런타임 설치 — tarball 안에 node 실행 파일과 app 폴더가 들어 있습니다.
[ -n "$ARG_RUNTIME" ] || { echo "--runtime 이 필요합니다 (extract.sh 산출물)." >&2; exit 1; }
mkdir -p "$PREFIX"
tb="$(mktemp)"
case "$ARG_RUNTIME" in
    http://*|https://*) fetch "$tb" "$ARG_RUNTIME" ;;
    *) [ -f "$ARG_RUNTIME" ] || { echo "런타임 파일이 없습니다: $ARG_RUNTIME" >&2; exit 1; }; cp "$ARG_RUNTIME" "$tb" ;;
esac
tar -C "$PREFIX" -xzf "$tb"
rm -f "$tb"
chmod +x "$PREFIX/node"
[ -f "$PREFIX/app/dist/index.js" ] || { echo "런타임 구성이 이상합니다 (app/dist/index.js 없음)." >&2; exit 1; }

# 자격증명 — 둘 다 주면 새로 쓰고, 안 주면 기존 파일이 있어야 합니다.
if [ -n "$ARG_EMAIL" ] && [ -n "$ARG_KEY" ]; then
    write_env "$ENV_FILE" "RP_EMAIL=$ARG_EMAIL
RP_API_KEY=$ARG_KEY"
elif [ ! -f "$ENV_FILE" ]; then
    echo "--email 과 --api-key 가 필요합니다 (https://app.repocket.co)." >&2; exit 1
fi

# 서비스 + watchdog 유닛 설치
for u in repocket.service repocket-watchdog.service repocket-watchdog.timer; do
    fetch "$SYSTEMD_DIR/$u" "$BASE_URL/apps/repocket/systemd/$u"
done
fetch /usr/local/bin/repocket-watchdog.sh "$BASE_URL/apps/repocket/watchdog.sh"
chmod +x /usr/local/bin/repocket-watchdog.sh

enable_now repocket.service repocket-watchdog.timer

echo "완료. 상태: systemctl status repocket --no-pager"
echo "      로그: journalctl -u repocket -f"
