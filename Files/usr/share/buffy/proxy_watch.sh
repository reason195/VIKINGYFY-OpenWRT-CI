#!/bin/sh
# SPDX-License-Identifier: MIT
# proxy_watch.sh - 运行中周期性代理健康检查（cron 每小时）
# 轻量：只做一次 204 探测，失败推 ntfy/Telegram（同一失败周期内去重，避免每小时刷屏）。
# 日志：/tmp/proxy_watch.log

. /usr/share/buffy/lib-buffy.sh

LOG="/tmp/proxy_watch.log"
NTFY="https://ntfy.sh/buffy-reason195-router"
MARK_FAIL="/tmp/.proxy-watch-fail"

log "=== proxy_watch: start ==="

if proxy_204; then
	rm -f "$MARK_FAIL"
	log "proxy 204 OK"
	exit 0
fi

# 首次失败才告警；恢复后自动清除标记（下次失败可再次告警）
if [ ! -f "$MARK_FAIL" ]; then
	touch "$MARK_FAIL"
	notify "路由器代理中断" "周期性 204 探测失败，代理链路可能已中断。详见 /tmp/proxy_watch.log（恢复后自动停止告警）。"
fi
log "proxy 204 FAIL"
exit 1
