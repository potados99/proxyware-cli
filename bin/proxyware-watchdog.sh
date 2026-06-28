#!/bin/sh
# 호스트+워커 통합 워치독: 헬스 판정 → Kuma heartbeat push.
# 워커는 netns 안에서 push하여 그 공인 IP의 실제 연결까지 검증한다.
# 워커 목록은 /etc/default/pawns-w* 에서 자동으로 발견한다 (수량 하드코딩 없음).
set -u

# push <ns|host> <url> : netns(또는 호스트)에서 heartbeat GET. 성공 시 0.
push() {
  ns="$1"; url="$2"
  [ -n "$url" ] || return 1
  if [ "$ns" = "host" ]; then pre=""; else pre="ip netns exec $ns"; fi
  if command -v curl >/dev/null 2>&1; then
    $pre curl -fsS -m 10 "$url" >/dev/null 2>&1
  else
    $pre busybox wget -q -T 10 -O /dev/null "$url" 2>/dev/null
  fi
}

hb_url() { sed -n "s/^HEARTBEAT_URL=//p" "$1" 2>/dev/null | tr -d "\""; }

# pawns: active + 최근 6분 내 마지막 lifecycle event가 not_running이 아니면 healthy.
# not_running으로 끝나면(터널 끊김 지속) 재시작하고 이번엔 push 안 함.
check_pawns() {
  unit="$1"; ns="$2"; url="$3"
  systemctl is-active --quiet "$unit" || return 0
  last=$(journalctl -u "$unit" --since "-6min" -o cat 2>/dev/null | grep -oE "\"name\":\"[a-z_]+\"" | tail -1)
  case "$last" in
    *not_running*) systemctl restart "$unit" ;;
    *) push "$ns" "$url" && echo "OK  $unit" || echo "PUSH_FAIL $unit" ;;
  esac
}

# earnfm: active면 healthy (조용함은 정상, Restart=always가 죽으면 살림).
check_earnfm() {
  unit="$1"; ns="$2"; url="$3"
  systemctl is-active --quiet "$unit" && { push "$ns" "$url" && echo "OK  $unit" || echo "PUSH_FAIL $unit"; }
}

# honeygain: active면 healthy. device_limit(exit 1)면 inactive로 멈춰있고
# RestartPreventExitStatus=1 이라 다시 안 살린다 → push 안 함(Kuma가 down 표시).
check_honeygain() {
  unit="$1"; ns="$2"; url="$3"
  systemctl is-active --quiet "$unit" && { push "$ns" "$url" && echo "OK  $unit" || echo "PUSH_FAIL $unit"; }
}

# 워커: /etc/default/pawns-worker<id> 가 있는 모든 id를 발견해서 점검
for f in /etc/default/pawns-worker*; do
  [ -e "$f" ] || continue
  id="${f##*/pawns-worker}"
  check_pawns  "pawns-worker@$id"  "w$id" "$(hb_url /etc/default/pawns-worker$id)"
  check_earnfm "earnfm-worker@$id" "w$id" "$(hb_url /etc/default/earnfm-worker$id)"
  [ -e /etc/default/honeygain-worker$id ] && check_honeygain "honeygain-worker@$id" "w$id" "$(hb_url /etc/default/honeygain-worker$id)"
done

# 호스트 자신을 워커로 쓰는 경우 (host)
[ -e /etc/default/pawns-host ]  && check_pawns  pawns-host  host "$(hb_url /etc/default/pawns-host)"
[ -e /etc/default/earnfm-host ] && check_earnfm earnfm-host host "$(hb_url /etc/default/earnfm-host)"
