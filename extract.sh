#!/usr/bin/env bash
# Docker 이미지에서 실행 런타임만 뽑아 tarball로 만듭니다.
# Docker가 있는 기기에서 한 번만 실행하면 됩니다. 뽑은 tarball은 대상 기기에서 install.sh로 씁니다.
#   ./extract.sh <앱>        (pawns|repocket|earnfm|honeygain)
set -euo pipefail

APP="${1:?앱 이름을 주세요: pawns | repocket | earnfm | honeygain}"
ARCH="$(uname -m)"
OUT="${APP}-runtime-${ARCH}.tar.gz"

command -v docker >/dev/null || { echo "docker가 필요합니다 (Docker 있는 기기에서 실행하세요)." >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

case "$APP" in
    earnfm)
        # earnfm은 /app/earnfm_example 단일 실행 파일 하나면 됩니다.
        IMAGE="earnfm/earnfm-client:latest"
        docker pull "$IMAGE" >/dev/null
        cid="$(docker create "$IMAGE")"
        docker cp "$cid:/app/earnfm_example" "$tmp/earnfm"
        docker rm "$cid" >/dev/null
        tar -C "$tmp" -czf "$OUT" earnfm
        ;;
    repocket)
        # repocket은 Node.js 앱이라 node 실행 파일과 /app(dist+node_modules)을 같이 뽑습니다.
        # node_modules에 아키텍처별 native 모듈이 있어 이미지의 node를 그대로 써야 합니다.
        IMAGE="repocket/repocket:latest"
        docker pull "$IMAGE" >/dev/null
        cid="$(docker create "$IMAGE")"
        docker cp "$cid:/usr/local/bin/node" "$tmp/node"
        docker cp "$cid:/app" "$tmp/app"
        docker rm "$cid" >/dev/null
        tar -C "$tmp" -czf "$OUT" node app
        ;;
    pawns|honeygain)
        echo "TODO: $APP 추출 경로는 이미지 구조 확인 후 채웁니다." >&2
        exit 1
        ;;
    *)
        echo "모르는 앱: $APP" >&2; exit 1
        ;;
esac

echo "생성: $OUT ($(du -h "$OUT" | cut -f1), arch=$ARCH)"
