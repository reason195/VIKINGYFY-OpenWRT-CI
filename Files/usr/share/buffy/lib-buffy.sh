#!/bin/sh
# SPDX-License-Identifier: MIT
# lib-buffy.sh - buffy 各脚本公共函数库（source 引入，勿直接执行）
# 提供：log / notify / resolve / cert_expires_within / openclash_ready / proxy_204
# 约定：调用方需先定义 LOG（log 用）、NTFY（ntfy 告警，可选）。notify 同时走 ntfy 与 Telegram。

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

notify() { # $1=标题 $2=正文；ntfy 与 Telegram 双通道，均未配置则静默跳过
	# ntfy 通道（调用方设置 NTFY 时启用）
	if [ -n "$NTFY" ]; then
		curl -fsS -m 10 -H "Title: $1" -H "Priority: high" -d "$2" "$NTFY" >/dev/null 2>&1
	fi
	# Telegram 通道（凭据由构建 Secret 注入 /etc/buffy-notify.conf）
	[ -f /etc/buffy-notify.conf ] && . /etc/buffy-notify.conf
	if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
		curl -fsS -m 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
			-d "chat_id=${TELEGRAM_CHAT_ID}" \
			--data-urlencode "text=【$1】$2" >/dev/null 2>&1
	fi
}

# 解析域名：解析出至少一个地址才算成功（busybox nslookup 失败也可能返回 0，故按输出判断）
resolve() { # $1=域名 [$2=DNS 服务器]
	if command -v nslookup >/dev/null 2>&1; then
		if [ -n "$2" ]; then
			nslookup "$1" "$2" 2>/dev/null | grep -qE 'Address( [0-9]+)?: [0-9a-fA-F]'
		else
			nslookup "$1" 2>/dev/null | grep -qE 'Address( [0-9]+)?: [0-9a-fA-F]'
		fi
	else
		ping -c 1 -W 3 "$1" >/dev/null 2>&1
	fi
}

# 证书是否将在 $2 秒内过期（含已过期）：是返回 0，否返回非 0。
# 用 openssl -checkend 判断，跨 busybox 版本稳定（替代解析 enddate 字符串的 days_left）。
cert_expires_within() { # $1=cert 路径 $2=秒数
	openssl x509 -checkend "$2" -noout -in "$1" >/dev/null 2>&1
	[ $? -ne 0 ]
}

# OpenClash 核心进程 + external-controller 就绪
openclash_ready() { # $1=控制端口（默认 9090）
	local port="${1:-9090}" code
	{ [ -n "$(pidof clash 2>/dev/null)" ] || [ -n "$(pgrep -f '[c]lash_meta' 2>/dev/null)" ]; } || return 1
	code=$(curl -m 3 -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/version" 2>/dev/null)
	[ -n "$code" ] && [ "$code" != "000" ]
}

# 端到端代理 204（路由器自身经 clash 分流 + 显式代理端口兜底）
proxy_204() {
	[ "$(curl -m 10 -s -o /dev/null -w '%{http_code}' 'https://www.google.com/generate_204' 2>/dev/null)" = "204" ] && return 0
	[ "$(curl -m 10 -s -o /dev/null -w '%{http_code}' 'https://www.gstatic.com/generate_204' 2>/dev/null)" = "204" ] && return 0
	local p
	for p in 7890 7891 7893; do
		[ "$(curl -m 8 -s -o /dev/null -w '%{http_code}' -x "http://127.0.0.1:$p" 'https://www.google.com/generate_204' 2>/dev/null)" = "204" ] && return 0
	done
	return 1
}
