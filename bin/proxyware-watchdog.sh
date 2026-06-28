#!/bin/sh
# 호스트+워커 통합 워치독입니다: 헬스 판정 후 Kuma heartbeat를 push합니다.
# 워커는 netns 안에서 push하여 그 공인 IP의 실제 연결까지 검증합니다.
# 워커 목록은 /etc/default/pawns-worker* 에서 자동으로 발견합니다(수량 하드코딩 없음).
set -u

# push <ns|host> <url> : netns(또는 호스트)에서 heartbeat GET을 보냅니다. 성공 시 0.
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

# 서비스가 active 된 지 몇 초 지났는지 반환합니다(monotonic 기준이라 시계/타임존 무관).
active_secs() {
  mono=$(systemctl show "$1" -p ActiveEnterTimestampMonotonic --value 2>/dev/null)
  up=$(awk '{print int($1)}' /proc/uptime)
  echo $(( up - ${mono:-0} / 1000000 ))
}

# pawns 헬스: "이번 기동(InvocationID)에서 터널이 실제로 섰는가(running)"로 판정합니다.
#  - balance_ready 는 "서버 연결됨"일 뿐입니다. cant_open_port 로 터널을 못 열어도 계속 나오므로
#    이것만으로 healthy 로 보면 스테일(running 미도달) 워커를 놓칩니다.
#  - 이번 기동의 마지막 이벤트가 not_running 이면 재시작합니다.
#  - 이번 기동에서 running 을 한 번도 못 봤고 3분이 넘었으면 불건강으로 보고 재시작합니다(push 안 함
#    → heartbeat 가 끊겨 Kuma 가 down 으로 잡습니다). 3분 미만이면 기동 유예로 두되 push 는 보류합니다.
#  - 이번 기동에서 running 을 봤으면 이후 조용해도 healthy 입니다.
check_pawns() {
  unit="$1"; ns="$2"; url="$3"
  systemctl is-active --quiet "$unit" || return 0
  inv=$(systemctl show "$unit" -p InvocationID --value 2>/dev/null)
  ev=$(journalctl -u "$unit" _SYSTEMD_INVOCATION_ID="$inv" -o cat 2>/dev/null | grep -oE "\"name\":\"[a-z_]+\"")
  case "$(printf '%s\n' "$ev" | tail -1)" in
    *not_running*) systemctl restart "$unit"; return ;;
  esac
  if ! printf '%s\n' "$ev" | grep -q '"name":"running"'; then
    [ "$(active_secs "$unit")" -ge 180 ] && systemctl restart "$unit"
    return   # running 미도달 → push 보류 → Kuma down
  fi
  push "$ns" "$url" && echo "OK  $unit" || echo "PUSH_FAIL $unit"
}

# earnfm: active 면 healthy 입니다(조용함은 정상이고, 죽으면 Restart=always 가 살립니다).
check_earnfm() {
  unit="$1"; ns="$2"; url="$3"
  systemctl is-active --quiet "$unit" && { push "$ns" "$url" && echo "OK  $unit" || echo "PUSH_FAIL $unit"; }
}

# honeygain: active 면 healthy 입니다. device_limit 등으로 멈추면 inactive 가 되어
# push 하지 않으므로 Kuma 가 down 으로 표시합니다.
check_honeygain() {
  unit="$1"; ns="$2"; url="$3"
  systemctl is-active --quiet "$unit" && { push "$ns" "$url" && echo "OK  $unit" || echo "PUSH_FAIL $unit"; }
}

# 워커: /etc/default/pawns-worker<id> 가 있는 모든 id 를 발견해 점검합니다.
for f in /etc/default/pawns-worker*; do
  [ -e "$f" ] || continue
  id="${f##*/pawns-worker}"
  check_pawns  "pawns-worker@$id"  "w$id" "$(hb_url /etc/default/pawns-worker$id)"
  check_earnfm "earnfm-worker@$id" "w$id" "$(hb_url /etc/default/earnfm-worker$id)"
  [ -e /etc/default/honeygain-worker$id ] && check_honeygain "honeygain-worker@$id" "w$id" "$(hb_url /etc/default/honeygain-worker$id)"
done

# 호스트 자신을 워커로 쓰는 경우(host)도 점검합니다.
[ -e /etc/default/pawns-host ]  && check_pawns  pawns-host  host "$(hb_url /etc/default/pawns-host)"
[ -e /etc/default/earnfm-host ] && check_earnfm earnfm-host host "$(hb_url /etc/default/earnfm-host)"
