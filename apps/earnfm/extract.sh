#!/usr/bin/env bash
# earnfm 런타임을 추출합니다. Docker가 있는 기기에서 한 번만 실행하면 됩니다.
# earnfm은 /app/earnfm_example 단일 실행 파일 하나면 되어서, 그것만 뽑아 tarball로 만듭니다.
#
# 대상 기기와 아키텍처가 다르면 첫 인자로 플랫폼을 주세요 (예: linux/arm64).
# 비우면 현재 기기 기준으로 뽑습니다.
#   ./extract.sh [linux/arm64]
set -euo pipefail

IMAGE="earnfm/earnfm-client:latest"
PLAT="${1:-}"
PA=""; ARCH="$(uname -m)"
if [ -n "$PLAT" ]; then PA="--platform $PLAT"; ARCH="${PLAT##*/}"; fi
OUT="earnfm-runtime-${ARCH}.tar.gz"

command -v docker >/dev/null || { echo "docker가 필요합니다 (Docker 있는 기기에서 실행하세요)." >&2; exit 1; }

docker pull $PA "$IMAGE" >/dev/null
cid="$(docker create $PA "$IMAGE")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT

tmp="$(mktemp -d)"
docker cp "$cid:/app/earnfm_example" "$tmp/earnfm"
tar -C "$tmp" -czf "$OUT" earnfm
rm -rf "$tmp"

echo "생성: $OUT ($(du -h "$OUT" | cut -f1), arch=$ARCH)"
