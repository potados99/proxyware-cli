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
EARNFM_LIMITED_GAP="${EARNFM_LIMITED_GAP:-600}"        # limited 재시작 사이 최소 간격(초)
EARNFM_LIMITED_WINDOW="${EARNFM_LIMITED_WINDOW:-7200}"  # 연속으로 셀 창(초). 2시간 넘게 조용하면 0부터
EARNFM_LIMITED_MAX="${EARNFM_LIMITED_MAX:-3}"           # 이 횟수째 limited면 포기하고 정지
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
# (established 기반 좀비 검출을 시도했다가 되돌림: pawns 단독 established는 정상 워커도 2개 수준이라
#  임계로 삼으면 오판한다. netns 전체(earnfm 포함) established가 진짜 지표이나 별도 재설계 필요.)
pawns_health() {
  unit="$1"
  systemctl is-active --quiet "$unit" || { echo skip; return; }
  age=$(active_secs "$unit")
  # 이번 기동 이후 로그만 본다. 예전엔 부팅 전체(-b)에서 running을 찾아서, 한 번이라도 running을 찍은
  # 유닛은 재시작 후 starting에서 멈춰도 영원히 healthy였다 → Kuma는 초록인데 수익 0.
  # (2026-09-24: 최신 CLI가 기동 시 가끔 starting에서 멈추는 걸 워치독이 못 잡아 발견.)
  win=$([ "$age" -lt 86400 ] && echo "$age" || echo 86400)
  # 수명주기 이벤트만 시간순으로 뽑아, "마지막 running 이후 처음 내려간 시각"을 구한다.
  # starting만 몇 분 간격으로 반복하는 재접속 루프도 있으니 마지막 starting 시각이 아니라
  # 내려간 시점부터 잰다.
  verdict=$(journalctl -u "$unit" --since "-${win}s" -o cat 2>/dev/null \
    | grep -oE '"happened_at":"[^"]+","name":"(starting|running|not_running)"' \
    | sed -E 's/"happened_at":"([^"]+)","name":"([a-z_]+)"/\1 \2/' \
    | awk '{ if ($2 == "running") down = ""; else if (down == "") down = $1; last = $2 }
           END { if (last == "") print "none"; else if (last == "running") print "up"; else print "down " down }')
  case "$verdict" in
    up)   echo healthy; return ;;
    down\ *)
      t=${verdict#down }
      downfor=$(( $(date +%s) - $(date -d "$t" +%s 2>/dev/null || date +%s) ))
      [ "$downfor" -lt 300 ] && echo grace || echo unhealthy
      return ;;
  esac
  # 이번 기동에 이벤트가 하나도 없다: 막 떴거나, 오래 돌아 초기 로그가 vacuum됐거나.
  # 장수 워커를 오판해 재시작하지 않도록 30분 넘게 산 유닛은 healthy로 본다.
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
  # limited 좀비: 반드시 "이번 세션(재시작 이후)" 로그만 본다. 옛 limited 로그가 저널에 남아 재시작 직후
  # 즉사시키는 버그를 막기 위해 --since를 active된 시점 이후로 한정하고, 재시작 후 30초는 연결 시도 시간을
  # 줘 판정을 보류(grace). 창은 부하 방지로 최대 1시간. (2026-07-02 즉사 버그 수정)
  age=$(active_secs "$unit")
  win=$([ "$age" -lt 3600 ] && echo "$age" || echo 3600)
  if [ "$age" -ge 30 ] && journalctl -u "$unit" --since "-${win}s" -o cat 2>/dev/null | grep -q "user is limited"; then
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

# earnapp: active면서 "실제로 트래픽이 흐르는가"까지 본다.
# ⚠️ systemd active ≠ 동작. 2026-09-05 nest에서 w03이 263시간 동안 active인 채 송신 0바이트였고
#   (제어서버 연결·외부통신 모두 정상, 마커에도 오류 없음) 재시작 한 번에 10분 36MB로 돌아왔다.
#   host도 4.2MB/h로 마비돼 있었다. earnapp은 안 죽고 조용히 일을 놓는다 — Restart=always도,
#   FD 감시(임계 500)도 이걸 못 잡는다. 관측된 좀비는 소켓 212~414개였고 정상은 43~82개였다.
#   그래서 소켓 수 대신 IPAccounting 누적 송신량의 증가를 지표로 삼는다(증상 자체를 재는 쪽).
# 창 안에 최소량도 못 보내면 unhealthy → 공통 엔진의 백오프가 재시작한다.
EARNAPP_IDLE_WINDOW="${EARNAPP_IDLE_WINDOW:-21600}"         # 관찰 창(초). 6시간.
EARNAPP_IDLE_MIN_BYTES="${EARNAPP_IDLE_MIN_BYTES:-1048576}" # 창 안에 이만큼도 못 보내면 정체(1MB)
# ⚠️ 트래픽 0만으로 재시작하면 안 된다. 정체에는 원인이 둘이고 처방이 반대다(2026-09-05 실측):
#   소켓 200~414 + 트래픽 0 → 좀비. 재시작이 듣는다(w03: 263시간 0바이트 → 재시작 후 85MB/12분).
#   소켓  3~6   + 트래픽 0 → 일 자체가 배정되지 않음(IP 밴/불량 IP). 재시작은 무의미한 churn이고
#                            처방은 MAC 교체다. 흔들지 말고 사람에게 알려야 한다.
# 그래서 소켓 수로 두 유형을 갈라, 좀비만 재시작하고 미배정은 grace로 둔다(재시작·push 모두 보류
# → Kuma down으로 사람이 본다).
EARNAPP_ZOMBIE_SOCKETS="${EARNAPP_ZOMBIE_SOCKETS:-150}"
# 관측된 소켓 수 분포: 유휴 2~6, 정상 44~102, 좀비 212~414.
# 아래 상수는 터널 경보(불량 IP 후보) 게이트에만 쓴다 — 헬스 판정에는 쓰지 않는다.
EARNAPP_IDLE_SOCKETS="${EARNAPP_IDLE_SOCKETS:-20}"
earnapp_sockets() {  # earnapp_sockets <unit> — cgroup에 프로세스는 1개다(실측)
  pid="$(systemctl show -p MainPID --value "$1" 2>/dev/null)"
  [ -n "$pid" ] && [ "$pid" != 0 ] || { echo 0; return; }
  ls -l "/proc/$pid/fd" 2>/dev/null | grep -c socket
}
earnapp_health() {
  unit="$1"
  systemctl is-active --quiet "$unit" || { echo skip; return; }

  egr="$(systemctl show -p IPEgressBytes --value "$unit" 2>/dev/null)"
  ent="$(systemctl show -p ActiveEnterTimestampMonotonic --value "$unit" 2>/dev/null)"
  # IPAccounting이 없거나 값을 못 읽으면 예전처럼 active만 보고 넘어간다(오판보다 무개입).
  case "${egr:-x}" in ''|*[!0-9]*) echo healthy; return ;; esac

  f="$STATE_DIR/ea_$(systemd-escape "$unit" 2>/dev/null || echo "$unit" | tr '/' '_')"
  p_ent=""; p_ts=""; p_egr=""
  [ -f "$f" ] && read -r p_ent p_ts p_egr < "$f" 2>/dev/null
  now=$(awk '{print int($1)}' /proc/uptime)

  # 유닛이 재기동되면 IPEgressBytes가 0으로 리셋된다 → 기준선을 새로 잡는다.
  if [ "$ent" != "$p_ent" ]; then
    printf '%s %s %s\n' "$ent" "$now" "$egr" > "$f"; echo healthy; return
  fi
  # 창 안에 최소량 이상 진전이 있었다 → 정상이고 창을 리셋한다.
  if [ "$egr" -ge $(( ${p_egr:-0} + EARNAPP_IDLE_MIN_BYTES )) ]; then
    printf '%s %s %s\n' "$ent" "$now" "$egr" > "$f"; echo healthy; return
  fi
  # 창을 다 쓰기 전에는 판단을 보류한다.
  [ $(( now - ${p_ts:-$now} )) -ge "$EARNAPP_IDLE_WINDOW" ] || { echo healthy; return; }

  # 정체 확정. 소켓 수로 좀비와 미배정을 가른다.
  # 창(기본 6시간)을 통째로 0에 가깝게 보냈다 → 좀비. 재시작한다.
  #
  # ⚠️ 소켓 수로 좀비를 가리려던 앞선 시도는 폐기했다. 판별이 안 된다(2026-09-19 실측):
  #   home w01 소켓 43 / 360시간 0바이트 → 좀비인데 임계(150) 아래라 놓쳤다
  #   home w05 소켓 22 / 356시간 0바이트 → 같은 이유로 놓쳤다
  #   nest w07 소켓 15 / 32MB/h          → 소켓이 적어도 멀쩡히 번다
  # 남는 지표는 "얼마나 오래 0이었나"뿐이다. 수요 기반이라 몇 시간 조용한 건 정상이므로
  # (w02가 1시간 침묵 후 자가 회복한 전례) 창을 넉넉히 잡아 오탐을 피한다.
  #
  # 크래시루프는 여기 걸리지 않는다 — 재기동마다 ActiveEnterTimestamp가 바뀌어 위에서
  # 기준선이 리셋되기 때문이다. 그건 재시작으로 안 낫는 불량 IP이고 아래 터널 경보가 맡는다.
  echo unhealthy
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
      # earnfm "user is limited". 예전(구 계정)엔 계정 단위라 재시작이 무의미해서 곧장 정지했는데,
      # supplier 전환 후엔 IP 단위이고 일시적인 경우가 많다(2026-09-26 nest w05: 재시작 한 번에 회복).
      # 그래서 재시작을 시도하되, 막힌 IP를 계속 두드리지 않게 차단기를 둔다.
      #   - 재시작 사이 최소 EARNFM_LIMITED_GAP초(클라이언트도 스스로 10분마다 재시도한다)
      #   - EARNFM_LIMITED_WINDOW초 안에 EARNFM_LIMITED_MAX번째 limited면 포기하고 정지 → Kuma down.
      #     이 IP는 막힌 것이니 MAC 교체(새 IP)가 처방이다. 사람이 다시 켜기 전엔 워치독이 건드리지 않는다.
      rm -f "$state"
      lim="$STATE_DIR/lim_$(systemd-escape "$unit" 2>/dev/null || echo "$unit" | tr '/' '_')"
      now=$(awk '{print int($1)}' /proc/uptime)
      n=0; t=0; [ -f "$lim" ] && read -r n t < "$lim"
      [ $(( now - ${t:-0} )) -gt "$EARNFM_LIMITED_WINDOW" ] && n=0   # 창 밖이면 새로 센다
      if [ "$n" -gt 0 ] && [ $(( now - t )) -lt "$EARNFM_LIMITED_GAP" ]; then
        echo "LIMITED_WAIT $unit (#$n, $((now - t))s < ${EARNFM_LIMITED_GAP}s)"
      elif [ $(( n + 1 )) -ge "$EARNFM_LIMITED_MAX" ]; then
        rm -f "$lim"
        systemctl stop "$unit"
        echo "LIMITED_GIVEUP $unit (${EARNFM_LIMITED_MAX}회 연속 limited — IP 밴 추정, MAC 교체 필요)"
      else
        echo "$(( n + 1 )) $now" > "$lim"
        systemctl restart "$unit"
        echo "LIMITED_RESTART $unit (#$(( n + 1 ))/${EARNFM_LIMITED_MAX})"
      fi ;;                                        # push 보류 → Kuma down으로 실측과 일치시킴
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
  [ -e /etc/default/earnapp-worker$id ] && handle "earnapp-worker@$id" "w$id" "$(hb_url /etc/default/earnapp-worker$id)" earnapp_health
done
[ -e /etc/default/pawns-host ]  && handle pawns-host  host "$(hb_url /etc/default/pawns-host)"  pawns_health
[ -e /etc/default/earnfm-host ] && handle earnfm-host host "$(hb_url /etc/default/earnfm-host)" earnfm_health
[ -e /etc/default/earnapp-host ] && handle earnapp-host host "$(hb_url /etc/default/earnapp-host)" earnapp_health

# ── earnfm 컨트롤 재연결 급증 = 밴 조기경보 ──────────────────────────────────────
# earnfm이 유럽 컨트롤 서버(websocket)를 반복 재연결하면(그 IP↔서버 국제경로 불안정), 수시간 뒤
# 'user is limited'로 밴당한다(실측: home04 재연결 63회·home06 47회 → 밴 / 정상 워커 0~1회). 재연결이
# 밴보다 선행하므로 조기경보로 쓴다. earnfm 자체 로그만 세어(서버에 아무 연결도 안 만듦) 무해하다 —
# 능동 TCP 폴링은 그 IP에서 연결을 자꾸 열어 서버가 불안정으로 오인, 오히려 밴을 유발할 수 있어 금지.
# 경보 채널: /etc/default/earnfm-reconn-alert 의 HEARTBEAT_URL(Kuma push). 급증 워커가 있으면 push를
# 보류해 Kuma가 down→알림. 없으면 push(up). URL 미설정이면 journal 로그로만 남긴다(Kuma 모니터 준비 전).
RECONN_THRESHOLD=5   # 최근 1h Reconnecting 횟수 임계. 정상 0~1, 밴 직전 수십.
reconn_alert=""
for f in /etc/default/earnfm-worker*; do
  [ -e "$f" ] || continue
  eid="${f##*/earnfm-worker}"
  eunit="earnfm-worker@$eid"
  systemctl is-active --quiet "$eunit" || continue
  rn=$(journalctl -u "$eunit" --since "-1h" -o cat 2>/dev/null | grep -c 'Reconnecting')
  [ "${rn:-0}" -ge "$RECONN_THRESHOLD" ] && reconn_alert="$reconn_alert $eunit=$rn"
done
alert_url="$(hb_url /etc/default/earnfm-reconn-alert)"
if [ -n "$reconn_alert" ]; then
  logger -t proxyware-watchdog "RECONN_ALERT 밴 조기경보(재연결 급증):$reconn_alert"
  echo "RECONN_ALERT$reconn_alert"          # push 보류 → Kuma down → 알림(URL 설정 시)
else
  [ -n "$alert_url" ] && push host "$alert_url"
  echo "RECONN_OK"
fi

# ── earnapp IP 터널 실패 경보 ───────────────────────────────────────────────────
# earnapp은 "특정 IP만 터널 협상을 못 끝내는" 실패가 있다(2026-08-20 nest w01: 재시작 264회,
# 수익 0). 증상은 무한 크래시루프이고, 판별 지표는 두 개다:
#   ① 상태 디렉토리에 perr_tun_init_err 가 상주 (성공하면 tun_start/tun_1b/udp_..._success가 뜬다)
#   ② NRestarts 급증
# 원인은 그 IP의 경로이므로 재시작·uuid 재발급으로는 안 낫는다 → MAC 교체(IP 교체)가 처방이다.
# 사람이 판단할 일이라 자동 조치는 하지 않고 경보만 띄운다.
# 채널: /etc/default/earnapp-tunnel-alert 의 HEARTBEAT_URL (없으면 로그만 남는다)
EARNAPP_RESTART_THRESHOLD="${EARNAPP_RESTART_THRESHOLD:-20}"
ea_alert=""
for f in /etc/default/earnapp-worker*; do
  [ -e "$f" ] || continue
  eid="${f##*/earnapp-worker}"; eunit="earnapp-worker@$eid"
  dir="/etc/proxyware/earnapp/w$eid"
  err=0
  [ -e "$dir" ] && ls "$dir" 2>/dev/null | grep -q 'perr_tun_init_err' && err=1
  nr=$(systemctl show "$eunit" -p NRestarts --value 2>/dev/null)
  # ⚠️ perr_* 마커는 한 번 생기면 지워지지 않는다(…sent 파일이 상주). 마커만 보면 이미 회복해
  # 잘 벌고 있는 노드까지 오탐한다(2026-09-05: w01이 12분 28MB인데 tun_err=1로 잡혔다).
  # 그래서 "지금 일을 못 받고 있는가"를 소켓 수로 함께 확인한다 — 정상 노드는 41~82개,
  # 불량 IP로 터널을 못 여는 노드는 3~6개였다.
  sk=$(earnapp_sockets "$eunit")
  if [ "$err" -eq 1 ] || [ "${nr:-0}" -ge "$EARNAPP_RESTART_THRESHOLD" ]; then
    if [ "${sk:-0}" -lt "$EARNAPP_IDLE_SOCKETS" ]; then
      ea_alert="$ea_alert $eunit(restarts=${nr:-0},tun_err=$err,sockets=${sk:-0})"
    fi
  fi
done
ea_url="$(hb_url /etc/default/earnapp-tunnel-alert)"
if [ -n "$ea_alert" ]; then
  logger -t proxyware-watchdog "EARNAPP_TUNNEL_ALERT IP 터널 실패 의심(MAC 교체 검토):$ea_alert"
  echo "EARNAPP_TUNNEL_ALERT$ea_alert"     # push 보류 → Kuma down → 알림
else
  [ -n "$ea_url" ] && push host "$ea_url"
  echo "EARNAPP_TUNNEL_OK"
fi
