#!/usr/bin/env bash
# earnapp 런타임을 공식 CDN에서 직접 받습니다. Docker 불필요.
# EarnApp(Bright Data)은 아키텍처별 단일 바이너리를 CDN으로 직접 배포합니다:
#   https://cdn-earnapp.b-cdn.net/static/earnapp[-ssl3]-<arch>-<ver>
#
# ⚠️ ssl3 변종을 써야 합니다. 공식 install.sh는 시스템 OpenSSL 버전으로 변종을 고릅니다:
#   OpenSSL 3.x  → earnapp-ssl3-<arch>-<ver>
#   그 외        → earnapp-<arch>-<ver>
# 우리 fleet은 Debian 13(trixie) + OpenSSL 3.5.1이라 기본값을 ssl3로 둡니다.
#
# 버전은 인자로 넘깁니다(자동 업그레이더를 mask했으므로 버전 관리 주체는 우리입니다).
# 최신 버전은 공식 설치 스크립트에서 확인:
#   curl -s https://brightdata.com/static/earnapp/install.sh | grep '^VERSION='
#
#   ./extract.sh [ver] [arch] [ssl-suffix]
#   ./extract.sh 1.651.510 aarch64 -ssl3
set -euo pipefail

VER="${1:-1.651.510}"
ARCH="${2:-aarch64}"
SSL="${3:--ssl3}"
case "$ARCH" in aarch64) OUTARCH="arm64" ;; *) OUTARCH="$ARCH" ;; esac

URL="https://cdn-earnapp.b-cdn.net/static/earnapp${SSL}-${ARCH}-${VER}"
OUT="earnapp-runtime-${OUTARCH}.tar.gz"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fSL "$URL" -o "$tmp/earnapp"
chmod +x "$tmp/earnapp"
# install.sh의 ensure_runtime이 tar 안의 'earnapp'을 $BIN에 풉니다.
tar -C "$tmp" -czf "$OUT" earnapp

echo "생성: $OUT ($(du -h "$OUT" | cut -f1), ver=$VER, arch=$ARCH$SSL)"
echo "src: $URL"
