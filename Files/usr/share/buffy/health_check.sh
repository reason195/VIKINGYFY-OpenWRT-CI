#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

# health_check.sh - 路由器全面体检（非 OpenClash 项）
# 检查：WAN 连通性(IPv4/IPv6) / DNS 解析 / DDNS 域名 / Let's Encrypt 证书 /
#       dnsmasq 备用上游 / 防火墙 IPv6 放行 + wan forward=DROP / 硬件流量卸载。
# 用法：手动 /usr/share/buffy/health_check.sh，或每日 cron（见 /etc/crontabs/root）。
# 任一 FAIL：退出码非 0 并推 Telegram 告警；日志：/tmp/health_check.log

LOG="/tmp/health_check.log"
DOMAIN="reason195.duckdns.org"
LEAF="/etc/acme/${DOMAIN}_ecc/${DOMAIN}.cer"

PASS=0
FAIL=0
REPORT=""

# 公共函数（log/notify/resolve/cert_expires_within 等）
. /usr/share/buffy/lib-buffy.sh

ok()  { PASS=$((PASS + 1)); REPORT="${REPORT}[OK]   $1\n"; log "[OK]   $1"; echo "[OK]   $1"; }
bad() { FAIL=$((FAIL + 1)); REPORT="${REPORT}[FAIL] $1\n"; log "[FAIL] $1"; echo "[FAIL] $1"; }
warn(){ REPORT="${REPORT}[WARN] $1\n"; log "[WARN] $1"; echo "[WARN] $1"; }

log "=== health_check: start ==="

# ---- 1. WAN 连通性 ----
if ip -4 route show default 2>/dev/null | grep -q 'default'; then
	ok "IPv4 默认路由存在"
	GW=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $3; exit}')
	if [ -n "$GW" ] && ping -4 -c 1 -W 2 "$GW" >/dev/null 2>&1; then
		ok "IPv4 网关可达 ($GW)"
	else
		bad "IPv4 网关不可达"
	fi
else
	bad "IPv4 默认路由缺失"
fi

if ping -4 -c 2 -W 3 223.5.5.5 >/dev/null 2>&1; then
	ok "公网 IPv4 可达 (223.5.5.5)"
else
	bad "公网 IPv4 不可达"
fi

if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
	ok "已获取公网 IPv6 地址"
else
	warn "未获取公网 IPv6 地址（wan6 可能未拨上）"
fi

# IPv6 可达性必须显式指定全局源地址：本机 IPv6 默认路由全是 "default from <prefix>" 源路由
# （无裸 default），不指定源会被判 Network unreachable，产生假阳性。先取 WAN 全局地址做源。
WAN6=""
for _dev in pppoe-wan wan6 wan; do
	WAN6=$(ip -6 addr show dev "$_dev" scope global 2>/dev/null | awk '/inet6/{print $2; exit}' | cut -d/ -f1)
	[ -n "$WAN6" ] && break
done
if [ -n "$WAN6" ] && ping -6 -c 2 -W 3 -I "$WAN6" 2400:3200::1 >/dev/null 2>&1; then
	ok "公网 IPv6 可达 (2400:3200::1, 源 ${WAN6%%:*})"
elif [ -n "$WAN6" ] && ping -6 -c 2 -W 3 -I "$WAN6" 2001:4860:4860::8888 >/dev/null 2>&1; then
	ok "公网 IPv6 可达 (2001:4860:4860::8888, 源 ${WAN6%%:*})"
else
	warn "公网 IPv6 不可达（源:${WAN6:-无全局地址}）"
fi

# LAN 客户端 IPv6 出网：用 br-lan 全局地址做源 ping 外部目标。局域网设备走的是
# "default from <委托前缀>" 源路由，与路由器自身 WAN 源路由不同——单独验证避免漏报。
LAN6=""
for _dev in br-lan lan; do
	LAN6=$(ip -6 addr show dev "$_dev" scope global 2>/dev/null | awk '/inet6/{print $2; exit}' | cut -d/ -f1)
	[ -n "$LAN6" ] && break
done
if [ -z "$LAN6" ]; then
	warn "无 LAN 全局 IPv6 地址，跳过客户端出网检测"
elif ping -6 -c 2 -W 3 -I "$LAN6" 2400:3200::1 >/dev/null 2>&1; then
	ok "LAN 客户端 IPv6 出网可达 (2400:3200::1, 源 ${LAN6%%:*})"
elif ping -6 -c 2 -W 3 -I "$LAN6" 2001:4860:4860::8888 >/dev/null 2>&1; then
	ok "LAN 客户端 IPv6 出网可达 (2001:4860:4860::8888, 源 ${LAN6%%:*})"
else
	bad "LAN 客户端 IPv6 出网不可达（源 ${LAN6%%:*}）"
fi

if resolve www.baidu.com 223.5.5.5; then
	ok "DNS 解析正常 (经 223.5.5.5)"
else
	bad "DNS 解析失败 (223.5.5.5)"
fi

# ---- 2. DDNS 域名 + Let's Encrypt 证书 ----
if resolve "$DOMAIN"; then
	ok "DDNS 域名可解析 ($DOMAIN)"
else
	bad "DDNS 域名解析失败 ($DOMAIN)"
fi

if [ -f "$LEAF" ]; then
	if cert_expires_within "$LEAF" 1209600; then
		bad "LE 证书临期/过期（剩余 <=14 天）"
	else
		ok "LE 证书有效（剩余 >14 天）"
	fi
else
	bad "LE 证书缺失 ($LEAF)"
fi

# ---- 3. dnsmasq 备用上游 ----
# rc.local 写到生成的 dnsmasq conf 里的 conf-dir（本机为 /tmp/dnsmasq.<cfgid>.d，非 /tmp/dnsmasq.d），
# 用 glob 兜底定位真实路径，避免按固定目录查漏报。
FALLBACK=""
for f in /tmp/dnsmasq.*.d/60-fallback.conf /tmp/dnsmasq.d/60-fallback.conf /tmp/etc/dnsmasq.d/60-fallback.conf; do
	[ -s "$f" ] && FALLBACK="$f" && break
done
if [ -n "$FALLBACK" ]; then
	if grep -q '223.5.5.5' "$FALLBACK"; then
		ok "dnsmasq 备用上游已部署 ($FALLBACK)"
	else
		bad "dnsmasq 备用上游内容异常"
	fi
else
	bad "dnsmasq 备用上游缺失 (conf-dir/60-fallback.conf)"
fi

if [ -n "$(pidof dnsmasq 2>/dev/null)" ]; then
	ok "dnsmasq 进程运行中"
else
	bad "dnsmasq 未运行"
fi

if resolve www.baidu.com 127.0.0.1; then
	ok "本地 DNS 解析正常 (127.0.0.1)"
else
	bad "本地 DNS 解析失败 (127.0.0.1)"
fi

# ---- 4. 防火墙 IPv6 放行 + wan forward ----
if nft list ruleset 2>/dev/null | grep -q 'Allow-WAN-SSH-v6'; then
	ok "IPv6 WAN SSH 放行规则存在"
else
	bad "IPv6 WAN SSH 放行规则缺失"
fi
if nft list ruleset 2>/dev/null | grep -q 'Allow-WAN-LuCI-v6'; then
	ok "IPv6 WAN LuCI 放行规则存在"
else
	bad "IPv6 WAN LuCI 放行规则缺失"
fi

FORWARD=""
i=0
while [ -n "$(uci -q get firewall.@zone[$i].name 2>/dev/null)" ]; do
	if [ "$(uci -q get firewall.@zone[$i].name)" = "wan" ]; then
		FORWARD=$(uci -q get firewall.@zone[$i].forward)
		break
	fi
	i=$((i + 1))
done
if [ "$FORWARD" = "DROP" ]; then
	ok "wan 区域 forward=DROP"
else
	warn "wan 区域 forward 非 DROP（当前: ${FORWARD:-未设置}）"
fi

if [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null)" = "1" ]; then
	ok "IPv6 转发已开启"
else
	bad "IPv6 转发未开启"
fi

# ---- 5. 硬件流量卸载 ----
SW=$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null)
HW=$(uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null)
if [ "$SW" = "1" ] && [ "$HW" = "1" ]; then
	ok "流量卸载开关已开启（软件+硬件）"
elif [ "$HW" = "1" ]; then
	warn "仅开硬件卸载、缺软件开关（fw4 不会生成 flowtable）"
else
	bad "流量卸载未开启（软件:${SW:-0} 硬件:${HW:-0}）"
fi

if nft list flowtables 2>/dev/null | grep -q 'flowtable'; then
	if nft list flowtable inet fw4 ft 2>/dev/null | grep -q 'flags offload'; then
		ok "nft flowtable 已创建（hardware offload）"
	else
		warn "nft flowtable 已创建（软件卸载，无 offload 标志）"
	fi
else
	warn "nft flowtable 未创建"
fi

# ---- 汇总 ----
log "=== health_check: done (PASS=$PASS FAIL=$FAIL) ==="
if [ "$FAIL" -gt 0 ]; then
	notify "路由器体检异常" "$(printf '%b' "$REPORT" | head -c 2000)"
	exit 1
fi
exit 0
