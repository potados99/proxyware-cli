#!/usr/bin/env bash
# pawns 런타임을 공식 배포처(pawns.app S3)에서 직접 받습니다. Docker 불필요.
# pawns.app은 아키텍처별 정적 단일 바이너리를 직접 배포합니다:
#   https://pawns-app.s3.eu-central-1.amazonaws.com/cli/latest/linux_<arch>/pawns-cli
# (예전엔 iproyal/pawns-cli 이미지에서 /pawns-cli를 docker cp로 뽑았으나, 같은 바이너리를
#  공식 S3가 직접 주므로 docker 의존을 없앴다. cli-download 페이지 목록엔 aarch64가 안 보이지만
#  S3엔 실존한다 — 확인: HTTP 200, 정적 ELF.)
#
# 주의: S3 경로 arch명(aarch64)과 Release 산출물 파일명(arm64)은 다르다.
#   - S3 경로:      linux_aarch64
#   - 산출 tarball:  pawns-runtime-arm64.tar.gz  ← install.sh가 받는 이름과 일치시켜야 함
# 32비트 Pi를 섞게 되면 armv7l 등을 인자로 넘겨 확장한다(현재 fleet은 전부 aarch64).
#   ./extract.sh [aarch64]
set -euo pipefail

S3ARCH="${1:-aarch64}"                     # S3 다운로드 경로용 arch명
case "$S3ARCH" in aarch64) OUTARCH="arm64" ;; *) OUTARCH="$S3ARCH" ;; esac
URL="https://pawns-app.s3.eu-central-1.amazonaws.com/cli/latest/linux_${S3ARCH}/pawns-cli"
OUT="pawns-runtime-${OUTARCH}.tar.gz"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fSL "$URL" -o "$tmp/pawns"
chmod +x "$tmp/pawns"
tar -C "$tmp" -czf "$OUT" pawns

echo "생성: $OUT ($(du -h "$OUT" | cut -f1), arch=$S3ARCH, src=$URL)"
