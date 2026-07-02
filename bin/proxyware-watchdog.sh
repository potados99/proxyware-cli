#!/bin/sh
# 호스트+워커 통합 워치독: 헬스 판정 후 Kuma heartbeat를 push하고, unhealthy면 점진적 백오프로 재시작한다.
# 워커는 netns 안에서 push하여 그 공인 IP의 실제 연결까지 검증한다.
# 워커 목록은 /etc/default/pawns-worker* 에서 자동 발견한다(수량 하드코딩 없음).
#
# 구조: 벤더별 룰은 "healthy 판정"만 선언하고(아래 *_health 함수), 복구는 공통 엔진(handle)이 담당한다.
#   판정값: healthy(정상) | unhealthy(재시작 대상) | grace(유예 — 재시작도 push도 보류) | skip(워치독 관여 안 함)
#
# 점진적 백오프(2026-06-29 도입): 재시작해도 안 살아나는 워커를 1분마다 영원히 때리면 오히려 벤더 서버측
#   등록을 꼬이게 만든다(실측: pawns 워커를 천천히/간격을 두고 재시작해야 running 복귀). 그래서 unhealthy가
#   지속되면 재시작 간격을 1→2→5→10→30분으로 늘린다. healthy 도달 즉시 백오프를 리셋한다.
#   상태는 /run(tmpfs)에 워커별로 저장 — 재부팅 시 깨끗.
set -u

STATE_DIR=/run/proxyware-wd
mkdir -p "$STATE_DIR" 2>/dev/null

EARNFM_RSS_MAX_KB=204800   # 200 MiB. earnfm(dart) 힙 폭주 회수 기준. 실측 plateau 60~155MB라 128은 아침
                           # 피크에 정상 워커를 자주 침 → 재시작 유발 → earnfm이 재시작마다 harvester(deviceName)를
                           # 재생성해 유령 기기 양산 + 잦은 재등록 rate limit(user is limited) 위험. 200으로 올려
                           # 재시작을 최소화한다. SidePi(1GB) OOM은 디스크 스왑 2GB가 완충(2026-07-02).

# push <ns|host> <url>: netns(또는 호스트)에서 heartbeat GET. 성공 시 0. 간헐 실패 대비 2회 재시도.
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

# 서비스가 active 된 지 몇 초 지났는지(monotonic 기준 — 시계/타임존 무관).
active_secs() {
  mono=$(systemctl show "$1" -p ActiveEnterTimestampMonotonic --value 2>/dev/null)
  up=$(awk '{print int($1)}' /proc/uptime)
  echo $(( up - ${mono:-0} / 1000000 ))
}

# 백오프 단계(초): fail_count -> 다음 재시작까지 대기. 재시작 간격 1,2,5,10,30분, 상한 30분 반복.
backoff_step() { case "$1" in 0) echo 60 ;; 1) echo 120 ;; 2) echo 300 ;; 3) echo 600 ;; *) echo 1800 ;; esac; }

# ── 벤더별 healthy 판정 ────────────────────────────────────────────────────────
# pawns: 진짜 online 신호는 running 이벤트다(balance_ready는 잔액조회라 online 아님).
#   - 최근 30분 마지막이 not_running  → unhealthy(터널 끊김).
#   - 부팅 이후 running 이력 있음       → healthy.
#   - running 미도달 & age<300s         → grace(재시작 직후, 도달 대기).
#   - running 미도달 & 300~1800s        → unhealthy(좀비/미도달).
#   - running 미도달 & age>1800s        → healthy로 본다. 장수 워커는 초기 running 로그가 journald에서
#       vacuum돼 false negative가 나기 때문(이 오판으로 전 워커 오재시작한 사고가 있었다). 진짜 끊기면
#       not_running이 찍혀 위에서 잡힌다.
pawns_health() {
  unit="$1"
  systemctl is-active --quiet "$unit" || { echo skip; return; }
  last30=$(journalctl -u "$unit" --since "-30min" -o cat 2>/dev/null | grep -oE '"name":"(running|not_running)"' | tail -1)
  case "$last30" in *not_running*) echo unhealthy; return ;; esac
  if [ "$(journalctl -u "$unit" -b -o cat 2>/dev/null | grep -c '"name":"running"')" -gt 0 ]; then
    echo healthy; return
  fi
  age=$(active_secs "$unit")
  if   [ "$age" -lt 300 ];  then echo grace
  elif [ "$age" -le 1800 ]; then echo unhealthy
  else echo healthy
  fi
}

# earnfm: active면 healthy(조용함은 정상). 두 예외:
#   1) limited 좀비 — active인데 earnfm 서버가 "user is limited"로 거부(트래픽 0인데 systemd는 active).
#      이걸 healthy로 오판하면 Kuma에 online으로 뜨나 실제론 죽음(업타임-실측 불일치). 재시작은 무의미
#      (서버측 판단 + 재시작마다 새 harvester 양산으로 악화)하므로 → zombie 판정 → handle이 stop시킨다.
#   2) RSS 임계 초과 → unhealthy(백오프 재시작). dart는 spike 후 자가회수하므로 60s 유예로 흡수.
earnfm_health() {
  unit="$1"
  systemctl is-active --quiet "$unit" || { echo skip; return; }
  if journalctl -u "$unit" -n 20 -o cat 2>/dev/null | grep -q "user is limited"; then
    echo zombie; return
  fi
  pid=$(systemctl show "$unit" -p MainPID --value 2>/dev/null)
  { [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null; } || { echo healthy; return; }
  rss=$(awk '/^VmRSS:/{print $2}' /proc/"$pid"/status 2>/dev/null)
  { [ -n "$rss" ] && [ "$rss" -gt "$EARNFM_RSS_MAX_KB" ]; } && echo unhealthy || echo healthy
}

# honeygain: active면 healthy. device_limit 등으로 멈추면 inactive(skip) → push 안 해 Kuma가 down 표시.
honeygain_health() {
  unit="$1"
  systemctl is-active --quiet "$unit" && echo healthy || echo skip
}

# ── 공통 엔진: 판정 → push/리셋 또는 백오프 재시작 ──────────────────────────────
handle() {
  unit="$1"; ns="$2"; url="$3"; health_fn="$4"
  state="$STATE_DIR/$(systemd-escape "$unit" 2>/dev/null || echo "$unit" | tr '/' '_')"
  case "$($health_fn "$unit")" in
    healthy)
      rm -f "$state"
      push "$ns" "$url" && echo "OK  $unit" || echo "PUSH_FAIL $unit" ;;
    grace)
      echo "GRACE $unit" ;;                       # 재시작·push 보류(도달 대기)
    unhealthy)
      now=$(awk '{print int($1)}' /proc/uptime)
      if [ ! -f "$state" ]; then                  # 첫 unhealthy → 백오프 시작(이번엔 재시작 안 함)
        echo "0 $now" > "$state"
        echo "WATCH $unit (1st unhealthy — backoff start)"
      else
        count=$(awk '{print $1}' "$state"); last=$(awk '{print $2}' "$state")
        step=$(backoff_step "${count:-0}")
        if [ $(( now - ${last:-0} )) -ge "$step" ]; then
          echo "RESTART $unit (fail #$((count+1)), backoff ${step}s elapsed)"
          systemctl restart "$unit"
          echo "$((count+1)) $now" > "$state"
        else
          echo "WAIT $unit (backoff ${step}s, $((now-last))s elapsed, fail #$count)"
        fi
      fi ;;                                        # unhealthy 동안 push 보류(Kuma down)
    zombie)
      rm -f "$state"
      systemctl stop "$unit"                       # earnfm limited: 재시작 무의미 → 정지(사람 개입 대기)
      echo "ZOMBIE_STOP $unit (user is limited)" ;;  # push 보류 → Kuma down으로 실측과 일치시킴
    skip) : ;;                                     # 워치독 관여 안 함(inactive 등 → systemd Restart 영역)
  esac
}

# ── 워커(자동 발견) + 호스트 ────────────────────────────────────────────────────
for f in /etc/default/pawns-worker*; do
  [ -e "$f" ] || continue
  id="${f##*/pawns-worker}"
  handle "pawns-worker@$id"  "w$id" "$(hb_url /etc/default/pawns-worker$id)"  pawns_health
  handle "earnfm-worker@$id" "w$id" "$(hb_url /etc/default/earnfm-worker$id)" earnfm_health
  [ -e /etc/default/honeygain-worker$id ] && handle "honeygain-worker@$id" "w$id" "$(hb_url /etc/default/honeygain-worker$id)" honeygain_health
done
[ -e /etc/default/pawns-host ]  && handle pawns-host  host "$(hb_url /etc/default/pawns-host)"  pawns_health
[ -e /etc/default/earnfm-host ] && handle earnfm-host host "$(hb_url /etc/default/earnfm-host)" earnfm_health
