#!/usr/bin/env bash
# repocket 런타임을 추출합니다. Docker가 있는 기기에서 한 번만 실행하면 됩니다.
# repocket은 Node.js 앱이라 node 실행 파일과 /app(dist + node_modules)을 함께 뽑습니다.
# node_modules에 아키텍처별 native 모듈이 있어 이미지의 node를 그대로 써야 합니다.
# 추출 기기와 대상 기기의 CPU 아키텍처가 같아야 합니다.
set -euo pipefail

IMAGE="repocket/repocket:latest"
ARCH="$(uname -m)"
OUT="repocket-runtime-${ARCH}.tar.gz"

command -v docker >/dev/null || { echo "docker가 필요합니다 (Docker 있는 기기에서 실행하세요)." >&2; exit 1; }

docker pull "$IMAGE" >/dev/null
cid="$(docker create "$IMAGE")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT

tmp="$(mktemp -d)"
docker cp "$cid:/usr/local/bin/node" "$tmp/node"
docker cp "$cid:/app" "$tmp/app"
tar -C "$tmp" -czf "$OUT" node app
rm -rf "$tmp"

echo "생성: $OUT ($(du -h "$OUT" | cut -f1), arch=$ARCH)"
