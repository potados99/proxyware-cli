#!/usr/bin/env bash
# earnfm을 단일 실행 파일 + systemd 서비스로 설치합니다. Docker 없이 동작합니다.
# extract.sh로 뽑은 런타임(tarball)을 받아서 /usr/local/bin/earnfm 으로 깝니다.
#
# 사용법 (root):
#   install.sh --runtime <tarball-경로-or-URL> --token <EARNFM_TOKEN>
set -euo pipefail

REPO="potados99/proxyware-cli"
BASE_URL="https://raw.githubusercontent.com/$REPO/main"
ENV_FILE="/etc/default/earnfm"
BIN="/usr/local/bin/earnfm"
SYSTEMD_DIR="/etc/systemd/system"

# 공통 함수를 불러옵니다. 저장소 안에서 실행하면 로컬 파일을, 아니면 내려받아서 씁니다.
HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -n "$HERE" ] && [ -f "$HERE/../../lib/common.sh" ]; then
    . "$HERE/../../lib/common.sh"
else
    if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "$BASE_URL/lib/common.sh"); else . <(wget -qO- "$BASE_URL/lib/common.sh"); fi
fi

ARG_RUNTIME=""; ARG_TOKEN=""
while [ $# -gt 0 ]; do case "$1" in
    --runtime) ARG_RUNTIME="$2"; shift 2 ;;
    --token)   ARG_TOKEN="$2";   shift 2 ;;
    *) echo "모르는 옵션: $1" >&2; exit 1 ;;
esac; done

need_root

# 런타임 설치 — tarball 안에 earnfm 실행 파일이 들어 있습니다.
# --runtime 미지정 시 GitHub Release에서 자동으로 받습니다 (arm64).
[ -n "$ARG_RUNTIME" ] || ARG_RUNTIME="https://github.com/$REPO/releases/download/runtimes-arm64/earnfm-runtime-arm64.tar.gz"
tb="$(mktemp)"
case "$ARG_RUNTIME" in
    http://*|https://*) fetch "$tb" "$ARG_RUNTIME" ;;
    *) [ -f "$ARG_RUNTIME" ] || { echo "런타임 파일이 없습니다: $ARG_RUNTIME" >&2; exit 1; }; cp "$ARG_RUNTIME" "$tb" ;;
esac
tar -C /usr/local/bin -xzf "$tb"
rm -f "$tb"
chmod +x "$BIN"

# 자격증명 — 토큰을 주면 새로 쓰고, 안 주면 기존 파일이 있어야 합니다.
if [ -n "$ARG_TOKEN" ]; then
    write_env "$ENV_FILE" "EARNFM_TOKEN=$ARG_TOKEN"
elif [ ! -f "$ENV_FILE" ]; then
    echo "--token 이 필요합니다 (https://app.earn.fm 에서 발급)." >&2; exit 1
fi

# 서비스 + watchdog 유닛 설치
for u in earnfm.service earnfm-watchdog.service earnfm-watchdog.timer; do
    fetch "$SYSTEMD_DIR/$u" "$BASE_URL/apps/earnfm/systemd/$u"
done
fetch /usr/local/bin/earnfm-watchdog.sh "$BASE_URL/apps/earnfm/watchdog.sh"
chmod +x /usr/local/bin/earnfm-watchdog.sh

enable_now earnfm.service earnfm-watchdog.timer

echo "완료. 상태: systemctl status earnfm --no-pager"
echo "      로그: journalctl -u earnfm -f"
