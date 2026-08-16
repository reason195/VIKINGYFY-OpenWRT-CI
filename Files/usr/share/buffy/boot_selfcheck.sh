#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

# boot_selfcheck.sh - 开机自检（每 boot 一次，rc.local 延迟拉起）
# 目的：确认 OpenClash 核心进程 + 代理链路(204) 真的可用，避免"看似启动、实际未接管流量"的静默故障。
# 成功：更新 /tmp/.boot-selfcheck-ok 时间戳，不打扰。
# 失败：写 /tmp/boot_selfcheck.log 并推 ntfy/Telegram 告警（同一次开机内去重，下次开机 /tmp 清空自动重置）。
# 日志：/tmp/boot_selfcheck.log

LOG="/tmp/boot_selfcheck.log"
NTFY="https://ntfy.sh/buffy-reason195-router"
MARK_OK="/tmp/.boot-selfcheck-ok"
MARK_FAIL="/tmp/.boot-selfcheck-fail"
LOCK="/tmp/.boot-selfcheck.lock"

# 公共函数（log/notify/openclash_ready/proxy_204 等）
. /usr/share/buffy/lib-buffy.sh

# 防并发（rc.local 可能重复拉起）
exec 9>"$LOCK"
flock -n 9 2>/dev/null || exit 0

log "=== boot_selfcheck: start ==="

# 是否"应跑"以配置是否就位为准，未配置（无 MihomoPro.yaml）才跳过。enable 标志需结合启动失败标记判读：
# - init 的 start_fail() 失败时会把 enable 清零并留下 /etc/.openclash-start-failed（构建期补丁），
#   该组合必须继续自检并告警——启动失败正是最需要告警的静默故障；
# - enable=0 且无标记 = 用户手动停止/停用（含停用后重启），跳过自检不打扰。
CONF=$(uci -q get openclash.config.config_path 2>/dev/null)
[ -z "$CONF" ] && CONF="/etc/openclash/config/MihomoPro.yaml"
if [ ! -f "$CONF" ]; then
	log "未检测到 OpenClash 配置 ($CONF)，跳过自检"
	exit 0
fi
if [ "$(uci -q get openclash.config.enable 2>/dev/null)" = "0" ] && [ ! -f /etc/.openclash-start-failed ]; then
	log "OpenClash 已手动停用（enable=0），跳过自检"
	exit 0
fi

CN_PORT=$(uci -q get openclash.config.cn_port 2>/dev/null)
[ -z "$CN_PORT" ] && CN_PORT=9090

FAIL=0

# ---- 1. 核心文件存在且可执行 ----
CORE="/etc/openclash/core/clash_meta"
if [ -f "$CORE" ] && [ -x "$CORE" ]; then
	log "core OK: $CORE"
else
	log "ERROR: clash 核心缺失或不可执行: $CORE"
	FAIL=1
fi

# ---- 2. 核心进程 + external-controller 就绪（最长 5 分钟） ----
WAIT=0
while [ "$WAIT" -lt 300 ] && ! openclash_ready "$CN_PORT"; do
	sleep 10
	WAIT=$((WAIT + 10))
done
if openclash_ready "$CN_PORT"; then
	log "controller ready (after ${WAIT}s)"
else
	log "ERROR: OpenClash 核心/控制器在 ${WAIT}s 内未就绪"
	FAIL=1
fi

# ---- 3. 代理链路 204（端到端：路由器自身流量经 clash；兜底显式代理端口） ----
if [ "$FAIL" -eq 0 ]; then
	WAIT=0
	while [ "$WAIT" -lt 300 ] && ! proxy_204; do
		sleep 15
		WAIT=$((WAIT + 15))
	done
	if proxy_204; then
		log "proxy 204 OK (after ${WAIT}s)"
	else
		log "ERROR: 代理链路 204 失败（${WAIT}s），流量可能未接管"
		FAIL=1
	fi
fi

# ---- 收尾 ----
if [ "$FAIL" -eq 0 ]; then
	date '+%F %T' > "$MARK_OK"
	rm -f "$MARK_FAIL"
	log "=== boot_selfcheck: PASS ==="
	exit 0
fi

if [ ! -f "$MARK_FAIL" ]; then
	touch "$MARK_FAIL"
	tail -n 40 "$LOG" > /tmp/boot_selfcheck.last 2>/dev/null
	notify "路由器代理自检失败" "OpenClash 核心或代理链路异常，流量可能未接管。详见 /tmp/boot_selfcheck.log（或 LuCI→OpenClash 日志）。"
fi
log "=== boot_selfcheck: FAIL ==="
exit 1
