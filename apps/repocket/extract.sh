#!/usr/bin/env bash
# repocket 런타임을 추출합니다. Docker가 있는 기기에서 한 번만 실행하면 됩니다.
# repocket은 Node.js 앱이라 node 실행 파일과 /app(dist + node_modules)을 함께 뽑습니다.
# node_modules에 아키텍처별 native 모듈이 있어 이미지의 node를 그대로 써야 합니다.
#
# 대상 기기와 아키텍처가 다르면 첫 인자로 플랫폼을 주세요 (예: linux/arm64).
# 비우면 현재 기기 기준으로 뽑습니다.
#   ./extract.sh [linux/arm64]
set -euo pipefail

IMAGE="repocket/repocket:latest"
PLAT="${1:-}"
PA=""; ARCH="$(uname -m)"
if [ -n "$PLAT" ]; then PA="--platform $PLAT"; ARCH="${PLAT##*/}"; fi
OUT="repocket-runtime-${ARCH}.tar.gz"

command -v docker >/dev/null || { echo "docker가 필요합니다 (Docker 있는 기기에서 실행하세요)." >&2; exit 1; }

docker pull $PA "$IMAGE" >/dev/null
cid="$(docker create $PA "$IMAGE")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT

tmp="$(mktemp -d)"
docker cp "$cid:/usr/local/bin/node" "$tmp/node"
docker cp "$cid:/app" "$tmp/app"
tar -C "$tmp" -czf "$OUT" node app
rm -rf "$tmp"

echo "생성: $OUT ($(du -h "$OUT" | cut -f1), arch=$ARCH)"
