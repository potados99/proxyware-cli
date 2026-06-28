# proxyware-cli

대역폭 공유 앱(pawns, earnfm, honeygain, repocket)을 컨테이너 없이 systemd로 돌리는 스크립트입니다.

각 인스턴스를 네트워크 네임스페이스 + macvlan으로 격리해, 한 호스트에서 인스턴스마다 별도 네트워크로 내보냅니다. 컨테이너 런타임을 띄우지 않아 자원이 빠듯한 ARM 환경에서 가볍습니다.

## 구조

```
install.sh           # 설치 진입점 (worker | host)
net/                 # 네임스페이스 네트워크 (macvlan + DHCP + DNS)
systemd/             # 템플릿 유닛 + 통합 워치독 + slice
bin/                 # 통합 워치독, Kuma 모니터 헬퍼
lib/common.sh        # 공통 함수
apps/                # (레거시) 컨테이너/호스트 직접 실행용 — 이전 방식
```

## 쓰는 법

인스턴스 하나:

```sh
sudo install.sh worker --id <ID> --mac <MAC> \
  --pawns-email <E> --pawns-pass <P> --device-id <NAME> --earnfm-token <T> \
  [--kuma-url <U> --kuma-user <U> --kuma-pass <P>]
```

호스트 자신도 한 인스턴스로 쓰려면:

```sh
sudo install.sh host [자격증명...]
```

- 공통 토대(스크립트·유닛·워치독)는 첫 호출 때 자동으로 깔립니다. 멱등이라 여러 번 호출해도 안전합니다.
- 바이너리(arm64)는 GitHub Release에서 자동으로 받습니다.
- `--kuma-*`를 주면 모니터를 자동으로 보장하고(있으면 재사용) heartbeat URL을 넣습니다. 직접 주려면 `--pawns-hb`/`--earnfm-hb`.

## 메모

- 같은 MAC을 쓰면 DHCP에서 같은 IP를 그대로 받습니다(인스턴스 이전 시 IP 보존).
- 자격증명은 `/etc/default/*` 에만 둡니다.
- 워치독은 호스트+인스턴스를 하나로 점검하며, 각 인스턴스의 실제 연결까지 검증한 뒤 heartbeat를 보냅니다.
- 메모리 cgroup 상한은 커널에서 memory cgroup이 켜진 호스트에서만 적용됩니다.
