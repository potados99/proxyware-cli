#!/bin/sh
# 호스트+워커 통합 워치독입니다: 헬스 판정 후 Kuma heartbeat를 push합니다.
# 워커는 netns 안에서 push하여 그 공인 IP의 실제 연결까지 검증합니다.
# 워커 목록은 /etc/default/pawns-worker* 에서 자동으로 발견합니다(수량 하드코딩 없음).
set -u

# push <ns|host> <url> : netns(또는 호스트)에서 heartbeat GET을 보냅니다. 성공 시 0.
# netns curl 이 일시적으로 실패할 수 있어 2회 재시도합니다(간헐 실패로 인한 flapping 방지).
push() {
  ns="$1"; url="$2"
  [ -n "$url" ] || return 1
  if [ "$ns" = "host" ]; then pre=""; else pre="ip netns exec $ns"; fi
  i=0
  while [ "$i" -lt 2 ]; do
    if command -v curl >/dev/null 2>&1; then
      $pre curl -fsS -m 10 "$url" >/dev/null 2>&1 && return 0
    else
      $pre busybox wget -q -T 10 -O /dev/null "$url" 2>/dev/null && return 0
    fi
    i=$((i+1)); sleep 1
  done
  return 1
}

hb_url() { sed -n "s/^HEARTBEAT_URL=//p" "$1" 2>/dev/null | tr -d "\""; }

# RSS 가드: proxyware 프로세스가 임계치를 넘으면 재시작해 메모리를 회수합니다.
# Pi 커널은 cgroup_disable=memory라 systemd MemoryMax가 무효 → MainPID의 VmRSS로 직접 판정합니다.
# earnfm(dart VM) 힙은 트래픽 처리 후에도 OS에 반환되지 않아 부푸는데(소켓 누수 아님), 재시작이 유일한 회수 수단입니다.
# 자가치유라 Kuma엔 보고하지 않고(정상 워커는 push 계속), journal에만 한 줄 남깁니다(플래핑 사후 추적용).
# 반환 0 = 재시작함(이번 사이클 push 스킵), 1 = 정상(이어서 check_* 수행).
# 임계 128MiB 근거: earnfm 정상 plateau는 60~97MB(home/nest 19h 안정 실측), 비정상 폭주는 150MB+(side 사망 직전).
# 그 사이 128MiB로 분리 → 정상은 안 건드리고 진짜 폭주만 회수. pawns(7~20MB)/honeygain(36~67MB)은 안 걸림.
MEM_LIMIT_KB=131072   # 128 MiB
mem_guard() {
  unit="$1"
  systemctl is-active --quiet "$unit" || return 1
  pid=$(systemctl show "$unit" -p MainPID --value 2>/dev/null)
  { [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null; } || return 1
  rss=$(awk '/^VmRSS:/{print $2}' /proc/"$pid"/status 2>/dev/null)
  [ -n "$rss" ] || return 1
  if [ "$rss" -gt "$MEM_LIMIT_KB" ]; then
    echo "MEM_RESTART $unit (RSS ${rss}KB > ${MEM_LIMIT_KB}KB)"
    systemctl restart "$unit"
    return 0
  fi
  return 1
}

# 서비스가 active 된 지 몇 초 지났는지 반환합니다(monotonic 기준이라 시계/타임존 무관).
active_secs() {
  mono=$(systemctl show "$1" -p ActiveEnterTimestampMonotonic --value 2>/dev/null)
  up=$(awk '{print int($1)}' /proc/uptime)
  echo $(( up - ${mono:-0} / 1000000 ))
}

# pawns 헬스: 최근 30분의 running / not_running 두 이벤트만 보고 판정합니다(balance_ready는 노이즈라 무시).
#  - 마지막이 running 이거나, 끊김(not_running)이 아예 없으면 → healthy(터널이 서 있거나 한 번도 안 끊김).
#    (정상 워커는 not_running이 없으니 항상 healthy → 오탐/flapping 없음.)
#  - 마지막이 not_running 이면 → 끊김 상태(또는 cant_open_port로 running 미도달). push 보류(→Kuma down)하고,
#    5분 넘게 그 상태면 재시작합니다.
# 이 방식은 InvocationID journalctl(부하 큼)을 안 써서 안정적입니다.
#
# online 미도달 감지(2026-06-29): pawns의 진짜 online 신호는 running 이벤트다(balance_ready는 잔액조회라
# online이 아니다 — pawns 대시보드 Active 여부는 running 도달로 갈린다). 두 장애가 여기 걸린다:
#   (1) 좀비: 크래시 후 재부팅 시 netns IP/경로 준비 전 헛스타트로 멈춰 이벤트가 전무한 상태.
#   (2) running 미도달: starting/balance_ready까지만 찍고 running에 못 가 대시보드에 안 뜨는 상태.
# 둘 다 not_running 이벤트가 없어 기존 판정은 healthy로 오판하고 push한다(Kuma 정상 → 대시보드만 진실).
# 정상 pawns는 재시작 후 ~30초 내 running에 도달하므로, "active 300초+ 인데 부팅 이후 running이 0개"면
# online 미도달로 확정해 재시작한다(running 도달 시간을 넉넉히 기다려 오탐 없음).
check_pawns() {
  unit="$1"; ns="$2"; url="$3"
  systemctl is-active --quiet "$unit" || return 0
  age=$(active_secs "$unit")
  if [ "$age" -ge 300 ] && [ "$(journalctl -u "$unit" -b -o cat 2>/dev/null | grep -c '"name":"running"')" -eq 0 ]; then
    echo "NO_RUNNING_RESTART $unit (active ${age}s, never reached running)"
    systemctl restart "$unit"
    return   # online 미도달 → push 보류(Kuma down)
  fi
  ev=$(journalctl -u "$unit" --since "-30min" -o cat 2>/dev/null | grep -oE '"name":"(running|not_running)"')
  case "$(printf '%s\n' "$ev" | tail -1)" in
    *not_running*)
      [ "$age" -ge 300 ] && systemctl restart "$unit"
      return ;;   # 끊김이 마지막 → push 보류(Kuma down)
  esac
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
  mem_guard "pawns-worker@$id"  || check_pawns  "pawns-worker@$id"  "w$id" "$(hb_url /etc/default/pawns-worker$id)"
  mem_guard "earnfm-worker@$id" || check_earnfm "earnfm-worker@$id" "w$id" "$(hb_url /etc/default/earnfm-worker$id)"
  [ -e /etc/default/honeygain-worker$id ] && { mem_guard "honeygain-worker@$id" || check_honeygain "honeygain-worker@$id" "w$id" "$(hb_url /etc/default/honeygain-worker$id)"; }
done

# 호스트 자신을 워커로 쓰는 경우(host)도 점검합니다.
[ -e /etc/default/pawns-host ]  && { mem_guard pawns-host  || check_pawns  pawns-host  host "$(hb_url /etc/default/pawns-host)"; }
[ -e /etc/default/earnfm-host ] && { mem_guard earnfm-host || check_earnfm earnfm-host host "$(hb_url /etc/default/earnfm-host)"; }
