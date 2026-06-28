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
    pawns)
        # pawns는 정적 링크 단일 바이너리라 entrypoint(/pawns-cli) 하나만 뽑으면 됩니다.
        IMAGE="iproyal/pawns-cli:latest"
        docker pull "$IMAGE" >/dev/null
        cid="$(docker create "$IMAGE")"
        docker cp "$cid:/pawns-cli" "$tmp/pawns"
        docker rm "$cid" >/dev/null
        tar -C "$tmp" -czf "$OUT" pawns
        ;;
    honeygain)
        # honeygain은 동적 링크라 실행 파일(/app/honeygain)과 의존 라이브러리 두 개를
        # 함께 뽑습니다. honeygain은 libhg.so.2.0.0을 직접 링크하고, libhg는 다시
        # libmsquic.so.2를 필요로 합니다. 둘 다 이미지의 /usr/lib에 있습니다.
        IMAGE="honeygain/honeygain:latest"
        docker pull "$IMAGE" >/dev/null
        cid="$(docker create "$IMAGE")"
        docker cp "$cid:/app/honeygain" "$tmp/honeygain"
        docker cp "$cid:/usr/lib/libhg.so.2.0.0" "$tmp/libhg.so.2.0.0"
        docker cp "$cid:/usr/lib/libmsquic.so.2" "$tmp/libmsquic.so.2"
        docker rm "$cid" >/dev/null
        tar -C "$tmp" -czf "$OUT" honeygain libhg.so.2.0.0 libmsquic.so.2
        ;;
    *)
        echo "모르는 앱: $APP" >&2; exit 1
        ;;
esac

echo "생성: $OUT ($(du -h "$OUT" | cut -f1), arch=$ARCH)"
