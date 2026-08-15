#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

# first_boot_download.sh - 刷机后首次开机引导
# 流程：等待 OpenClash 启动完成 → 确认科学上网可用 → 自动更新：
#   1. GEO 数据库（GeoIP.dat / GeoSite.dat / ASN.mmdb / Country.mmdb，走 openclash_geo.sh all）
#   2. 大陆白名单（chnroute IPv4 + IPv6 CIDR，走 openclash_chnroute.sh，源 ispip.clang.cn）
#   3. 面板版本（Zashboard / Metacubexd 最新版，走 openclash_download_dashboard.sh）
# 幂等：全部成功后写标记 /etc/.openclash-bootstrap-done，仅首次执行；
#       任一步失败不写标记，下次开机自动重试。周更由 crontabs/root 的
#       openclash_geo.sh / openclash_chnroute.sh 负责，本脚本只做首启补齐。
# 日志：/tmp/first_boot_download.log

LOG="/tmp/first_boot_download.log"
DONE="/etc/.openclash-bootstrap-done"
LOCK="/tmp/.openclash-bootstrap.lock"

# 公共函数（log/openclash_ready/proxy_204 等）
. /usr/share/buffy/lib-buffy.sh

# 幂等 + 防并发（同一时刻只跑一个实例）
[ -f "$DONE" ] && exit 0
exec 9>"$LOCK"
flock -n 9 2>/dev/null || exit 0
[ -f "$DONE" ] && exit 0

log "=== first_boot_download: start ==="

# ---- 1. 等待 OpenClash 启动完成（核心进程 + 控制端口就绪），最长 10 分钟 ----
WAIT=0
while [ "$WAIT" -lt 600 ]; do
	if openclash_ready; then
		log "OpenClash is ready (after ${WAIT}s)"
		break
	fi
	sleep 10
	WAIT=$((WAIT + 10))
done
if [ "$WAIT" -ge 600 ]; then
	log "ERROR: OpenClash not ready within 600s, give up and retry on next boot"
	exit 1
fi

# ---- 2. 等待科学上网可用（端到端：直连经 clash 分流 + 兜底显式代理端口），最长 15 分钟 ----
WAIT=0
while [ "$WAIT" -lt 900 ]; do
	if proxy_204; then
		log "Proxy is working (after ${WAIT}s)"
		break
	fi
	sleep 15
	WAIT=$((WAIT + 15))
done
if [ "$WAIT" -ge 900 ]; then
	# GEO 走 jsdelivr 镜像、白名单走 ispip.clang.cn，大陆直连可达；
	# 面板走 codeload.github.com（需代理）。代理超时仍尝试全部下载（失败下次开机重试）
	log "WARN: proxy not reachable within 900s, still trying downloads"
fi

# ---- 3. 更新 GEO 数据库（GeoIP / GeoSite / ASN / Country） ----
GEO_OK=1
/usr/share/openclash/openclash_geo.sh all >> "$LOG" 2>&1
# openclash_geo.sh 不返回失败码，按产物文件校验（脚本内置 >=10KB 与 HTML 内容校验）
for f in /etc/openclash/GeoIP.dat /etc/openclash/GeoSite.dat /etc/openclash/ASN.mmdb /etc/openclash/Country.mmdb; do
	if [ -s "$f" ]; then
		log "geo OK: $f"
	else
		GEO_OK=0
		log "geo MISSING: $f"
	fi
done

# ---- 4. 更新大陆白名单（chnroute IPv4 + IPv6） ----
CHNR_OK=1
/usr/share/openclash/openclash_chnroute.sh >> "$LOG" 2>&1
for f in /etc/openclash/china_ip_route.ipset /etc/openclash/china_ip6_route.ipset; do
	if [ -s "$f" ]; then
		log "chnroute OK: $f"
	else
		CHNR_OK=0
		log "chnroute MISSING: $f"
	fi
done

# ---- 5. 更新面板版本（Zashboard / Metacubexd，走 openclash_download_dashboard.sh） ----
DASH_OK=1
/usr/share/openclash/openclash_download_dashboard.sh Zashboard >> "$LOG" 2>&1 || DASH_OK=0
[ -s /usr/share/openclash/ui/zashboard/index.html ] || DASH_OK=0
/usr/share/openclash/openclash_download_dashboard.sh Metacubexd >> "$LOG" 2>&1 || DASH_OK=0
[ -s /usr/share/openclash/ui/metacubexd/index.html ] || DASH_OK=0
if [ "$DASH_OK" = "1" ]; then
	log "dashboards OK (zashboard + metacubexd)"
else
	log "WARN: dashboard update incomplete"
fi

# ---- 6. 收尾：全部成功才写标记，否则下次开机重试 ----
if [ "$GEO_OK" = "1" ] && [ "$CHNR_OK" = "1" ] && [ "$DASH_OK" = "1" ]; then
	touch "$DONE"
	log "=== first_boot_download: done, marker written ==="
	exit 0
fi
log "=== first_boot_download: finished with warnings, retry on next boot ==="
exit 1
