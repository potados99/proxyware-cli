# proxyware-cli

대역폭 공유 앱(pawns, repocket, earnfm, honeygain)을 단일 실행 파일 + systemd로 돌리는 스크립트입니다.

이 앱들은 보통 Docker 이미지로 배포됩니다. 자원이 빠듯한 ARM 환경에서는 Docker 데몬이 부담스럽기 때문에, 이미지에서 실행 파일만 뽑아 systemd 서비스로 직접 돌립니다.

## 구조

```
apps/<앱>/install.sh        # 설치
apps/<앱>/watchdog.sh       # 헬스체크
apps/<앱>/extract.sh        # Docker 있는 곳에서 런타임 추출
apps/<앱>/systemd/          # 서비스 + watchdog 유닛
lib/common.sh              # install 공통 함수
```

## 쓰는 법

pawns·earnfm·honeygain은 arm64 런타임이 GitHub Release에 올라가 있어, 설치할 때 자동으로 받습니다.

```sh
sudo apps/<앱>/install.sh [자격증명...]
```

런타임을 직접 지정하거나(다른 아키텍처 등) 새로 뽑으려면:

```sh
./apps/<앱>/extract.sh [linux/arm64]      # Docker 있는 기기에서 추출
sudo apps/<앱>/install.sh --runtime <경로-or-URL> [자격증명...]
```

(repocket은 크기·구조상 Release에 없어 `--runtime`을 직접 줘야 합니다.)

서비스는 앱별로 독립이고, watchdog도 서비스마다 따로 돕니다.

## 메모

- 추출 기기와 대상 기기의 CPU 아키텍처가 같아야 합니다.
- 자격증명은 `/etc/default/<앱>`에만 둡니다.
