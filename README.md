# proxyware-cli

대역폭 공유 앱(pawns, earnfm, earnapp, honeygain, repocket)을 컨테이너 없이 systemd로 돌리는 스크립트입니다.

각 인스턴스를 네트워크 네임스페이스 + macvlan으로 격리해, 한 호스트에서 인스턴스마다 별도 네트워크로 내보냅니다. 컨테이너 런타임을 띄우지 않아 자원이 빠듯한 ARM 환경에서 가볍습니다.

## 구조

```
install.sh           # 설치 진입점 (worker | host)
net/                 # 네임스페이스 네트워크 (macvlan + DHCP + DNS)
systemd/             # 템플릿 유닛 + 통합 워치독 + slice
bin/                 # 통합 워치독, Kuma 모니터 헬퍼, earnapp 등록·FD 감시
lib/common.sh        # 공통 함수
apps/                # (레거시) 컨테이너/호스트 직접 실행용 — 이전 방식
```

## 쓰는 법

인스턴스 하나:

```sh
sudo install.sh worker --id <ID> --mac <MAC> \
  --pawns-email <E> --pawns-pass <P> --device-id <NAME> --earnfm-token <T> \
  [--earnapp] [--kuma-url <U> --kuma-user <U> --kuma-pass <P>]
```

호스트 자신도 한 인스턴스로 쓰려면:

```sh
sudo install.sh host [자격증명...]
```

- 공통 토대(스크립트·유닛·워치독)는 첫 호출 때 자동으로 깔립니다. 멱등이라 여러 번 호출해도 안전합니다.
- 바이너리(arm64)는 GitHub Release에서 자동으로 받습니다.
- `--kuma-*`를 주면 모니터를 자동으로 보장하고(있으면 재사용) heartbeat URL을 넣습니다. 직접 주려면 `--pawns-hb`/`--earnfm-hb`/`--earnapp-hb`.

### earnapp

`--earnapp`만 붙이면 됩니다. 자격증명이 없습니다 — 기기 식별자가 `/etc/earnapp/uuid` 파일 하나입니다.
설치 후 **등록은 따로** 해야 합니다(계정 연결은 브라우저로만 가능):

```sh
sudo earnapp-register.sh            # 전체
sudo earnapp-register.sh 01 03 host # 지정
```

기기를 서버에 등록(`POST client.earnapp.com/install_device`)하고 **계정 연결 링크를 표로** 출력합니다.
그 링크를 로그인 상태에서 하나씩 열면 계정에 붙습니다. 이 등록을 건너뛰면 링크가 "device not found"입니다.
기기 이름은 CLI로 못 정하니 대시보드에서 rename하세요.

알아둘 것:

- 워커마다 `/etc/proxyware/earnapp/w<ID>`를 `/etc/earnapp`으로 바인드마운트합니다. 안 하면 모든 워커가 uuid 하나를 공유해 **기기 1대가 IP N개를 오가는 꼴**이 됩니다.
- `consent`/`status`/`ver` 시드 파일을 install.sh가 만들어 줍니다. 없으면 `earnapp run`이 즉사해 무한 재시작만 돕니다.
- `NODE_EXTRA_CA_CERTS`를 유닛에 박아 둡니다. earnapp 번들 Node의 CA 스토어가 낡아 등록 API TLS 검증이 실패하는 벤더 버그 우회입니다.
- 벤더 자동 업그레이더(`earnapp_upgrader`)는 mask합니다. 버전은 `apps/earnapp/extract.sh`로 관리하고, 업그레이더 자체가 1대당 약 59MB를 씁니다.
- FD 누수 감시(`earnapp-fd-monitor.timer`)가 함께 켜집니다. earnapp은 릴레이라 평시 FD가 26~62(스파이크 110~127)이므로 임계는 **500**입니다. 낮추면 건강한 워커를 죽입니다.
- 특정 IP가 터널 협상을 못 끝내 무한 크래시루프에 빠지는 경우가 있습니다. 워치독이 `perr_tun_init_err`와 `NRestarts`로 감지해 `EARNAPP_TUNNEL_ALERT`를 냅니다. **처방은 MAC 교체(IP 교체)** 이며, 재시작이나 uuid 재발급으로는 낫지 않습니다.

## 메모

- 같은 MAC을 쓰면 DHCP에서 같은 IP를 그대로 받습니다(인스턴스 이전 시 IP 보존).
- 자격증명은 `/etc/default/*` 에만 둡니다.
- 워치독은 호스트+인스턴스를 하나로 점검하며, 각 인스턴스의 실제 연결까지 검증한 뒤 heartbeat를 보냅니다.
- 메모리 cgroup 상한은 커널에서 memory cgroup이 켜진 호스트에서만 적용됩니다.
