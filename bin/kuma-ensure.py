#!/usr/bin/env python3
# Kuma 푸시 모니터를 "있으면 재사용, 없으면 생성"하고 push URL을 stdout으로 출력합니다.
# install.sh가 호출해서 받은 URL을 HEARTBEAT_URL로 env에 넣습니다.
#   kuma-ensure.py --url <kuma> --user <u> --password <p> --name <모니터이름> [--interval 600]
import argparse, sys
from uptime_kuma_api import UptimeKumaApi, MonitorType

ap = argparse.ArgumentParser()
ap.add_argument("--url", required=True)
ap.add_argument("--user", required=True)
ap.add_argument("--password", required=True)
ap.add_argument("--name", required=True)
ap.add_argument("--interval", type=int, default=600)
a = ap.parse_args()

api = UptimeKumaApi(a.url)
api.login(a.user, a.password)
try:
    mon = next((m for m in api.get_monitors() if m["name"] == a.name), None)
    if mon is None:
        # v2는 conditions=[] 를 요구한다 (스킬 기록 참조).
        r = api.add_monitor(type=MonitorType.PUSH, name=a.name,
                            interval=a.interval, conditions=[])
        mon = api.get_monitor(r["monitorID"])
    token = mon["pushToken"]
    print(f"{a.url}/api/push/{token}?status=up&msg=OK&ping=")
finally:
    api.disconnect()
