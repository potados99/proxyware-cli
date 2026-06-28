#!/usr/bin/env bash
# honeygain 런타임을 추출합니다. Docker가 있는 기기에서 한 번만 실행하면 됩니다.
# honeygain은 동적 링크라 실행 파일(/app/honeygain)과 의존 라이브러리 두 개를 함께 뽑습니다.
# honeygain은 libhg.so.2.0.0을 직접 링크하고, libhg는 다시 libmsquic.so.2를 필요로 합니다.
# 둘 다 이미지의 /usr/lib에 있습니다. 추출 기기와 대상 기기의 CPU 아키텍처가 같아야 합니다.
set -euo pipefail

IMAGE="honeygain/honeygain:latest"
ARCH="$(uname -m)"
OUT="honeygain-runtime-${ARCH}.tar.gz"

command -v docker >/dev/null || { echo "docker가 필요합니다 (Docker 있는 기기에서 실행하세요)." >&2; exit 1; }

docker pull "$IMAGE" >/dev/null
cid="$(docker create "$IMAGE")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT

tmp="$(mktemp -d)"
docker cp "$cid:/app/honeygain" "$tmp/honeygain"
docker cp "$cid:/usr/lib/libhg.so.2.0.0" "$tmp/libhg.so.2.0.0"
docker cp "$cid:/usr/lib/libmsquic.so.2" "$tmp/libmsquic.so.2"
tar -C "$tmp" -czf "$OUT" honeygain libhg.so.2.0.0 libmsquic.so.2
rm -rf "$tmp"

echo "생성: $OUT ($(du -h "$OUT" | cut -f1), arch=$ARCH)"
