#!/usr/bin/env bash
# proxyware-cli 공통 함수입니다. 각 앱의 install.sh에서 source해서 씁니다.
# root 확인, 다운로드, env 파일 쓰기, systemd 등록처럼 앱마다 똑같이 반복되는 일만 모았습니다.

# root 권한으로 실행 중인지 확인합니다.
need_root() { [ "$(id -u)" -eq 0 ] || { echo "root로 실행하세요 (sudo)." >&2; exit 1; }; }

# 파일을 내려받습니다. curl이 있으면 curl, 없으면 wget을 씁니다.
#   fetch <저장경로> <URL>
fetch() {
    if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$1" "$2"
    elif command -v wget >/dev/null 2>&1; then wget -qO "$1" "$2"
    else echo "curl 또는 wget이 필요합니다." >&2; exit 1; fi
}

# 자격증명 같은 값을 env 파일로 저장합니다. 권한은 600으로 잠급니다.
#   write_env <파일경로> <내용>
write_env() {
    printf '%s\n' "$2" > "$1"
    chmod 600 "$1"
}

# 유닛을 등록하고 바로 켭니다. (daemon-reload 후 enable --now)
#   enable_now <유닛...>
enable_now() {
    systemctl daemon-reload
    systemctl enable --now "$@"
}
