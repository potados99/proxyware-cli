#!/usr/bin/env bash
# pawns 런타임을 추출합니다. Docker가 있는 기기에서 한 번만 실행하면 됩니다.
# pawns는 정적 링크 단일 바이너리(이미지 entrypoint /pawns-cli)라 그것만 뽑아 tarball로 만듭니다.
#
# 대상 기기와 아키텍처가 다르면 첫 인자로 플랫폼을 주세요 (예: linux/arm64).
# 비우면 현재 기기 기준으로 뽑습니다.
#   ./extract.sh [linux/arm64]
set -euo pipefail

IMAGE="iproyal/pawns-cli:latest"
PLAT="${1:-}"
PA=""; ARCH="$(uname -m)"
if [ -n "$PLAT" ]; then PA="--platform $PLAT"; ARCH="${PLAT##*/}"; fi
OUT="pawns-runtime-${ARCH}.tar.gz"

command -v docker >/dev/null || { echo "docker가 필요합니다 (Docker 있는 기기에서 실행하세요)." >&2; exit 1; }

docker pull $PA "$IMAGE" >/dev/null
cid="$(docker create $PA "$IMAGE")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT

tmp="$(mktemp -d)"
docker cp "$cid:/pawns-cli" "$tmp/pawns"
tar -C "$tmp" -czf "$OUT" pawns
rm -rf "$tmp"

echo "생성: $OUT ($(du -h "$OUT" | cut -f1), arch=$ARCH)"
