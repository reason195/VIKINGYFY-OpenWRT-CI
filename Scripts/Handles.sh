#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -d "$GITHUB_WORKSPACE/wrt/package" ]; then
	PKG_PATH="$GITHUB_WORKSPACE/wrt/package"
else
	PKG_PATH="$(pwd)"
fi

#预置HomeProxy数据
HP_DIR="$(find "$PKG_PATH" -maxdepth 1 -type d -name '*homeproxy*' -print -quit)"
if [ -n "$HP_DIR" ]; then
	echo " "

	HP_RESOURCES="$HP_DIR/root/etc/homeproxy/resources"
	HP_DASHBOARD="$HP_DIR/root/etc/homeproxy/dashboard"
	HP_IP_SOURCE="https://cdn.jsdelivr.net/gh/Loyalsoldier/surge-rules@release/cncidr.txt"
	HP_GEOSITE_SOURCE="https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set-unstable/geosite-cn.srs"
	HP_IP_VERSION_URL="https://github.com/Loyalsoldier/surge-rules/releases/latest"
	HP_GEOSITE_VERSION_URL="https://github.com/SagerNet/sing-geosite/releases/latest"
	HP_DASHBOARD_SOURCE="https://codeload.github.com/SagerNet/sing-box-dashboard/zip/refs/heads/gh-pages"
	HP_DASHBOARD_VERSION_URL="https://github.com/SagerNet/sing-box-dashboard/commits/gh-pages.atom"
	HP_USER_AGENT="HomeProxy resource preset"

	HP_PREREQUISITES_MISSING=0
	for HP_COMMAND in curl awk; do
		command -v "$HP_COMMAND" > /dev/null 2>&1 || {
			echo "homeproxy resource preset requires $HP_COMMAND!"
			HP_PREREQUISITES_MISSING=1
		}
	done
	HP_PRESET_FAILED=0
	if [ "${HP_PREREQUISITES_MISSING:-0}" -eq 1 ]; then
		HP_PRESET_FAILED=1
	else
		HP_TMP="$(mktemp -d)"
		if [ -z "$HP_TMP" ]; then
			echo "failed to prepare homeproxy resource preset directory!"
			HP_PRESET_FAILED=1
		fi
	fi
	HP_DASHBOARD_STAGE="${HP_DASHBOARD}.new.$$"
	if [ "$HP_PRESET_FAILED" -eq 0 ]; then
		trap 'rm -rf "$HP_TMP" "$HP_DASHBOARD_STAGE"' EXIT INT TERM
	fi

	hp_fetch_release_version() {
		local effective_url version

		effective_url="$(curl -fsSL --compressed --retry 3 --retry-all-errors \
			--retry-delay 1 \
			--connect-timeout 10 --max-time 30 -A "$HP_USER_AGENT" \
			-o /dev/null -w '%{url_effective}' "$1")" || return 1
		version="${effective_url##*/}"
		case "$version" in
		''|*[!0-9]*) return 1 ;;
		esac
		printf '%s\n' "$version"
	}

	hp_download() {
		curl -fsSL --compressed --retry 3 --retry-all-errors --retry-delay 1 \
			--connect-timeout 10 \
			--max-time 60 -A "$HP_USER_AGENT" -o "$2" "$1" && [ -s "$2" ]
	}

	hp_fetch_dashboard_version() {
		local feed version

		feed="$(curl -fsSL --compressed --retry 3 --retry-all-errors \
			--retry-delay 1 --connect-timeout 10 --max-time 30 \
			-A "$HP_USER_AGENT" "$HP_DASHBOARD_VERSION_URL")" || return 1
		version="$(printf '%s\n' "$feed" | awk -F '[<>]' '
			/<updated>/ {
				version = $3
				gsub(/[-:TZ]/, "", version)
				print version
				exit
			}
		')"
		case "$version" in
		??????????????) case "$version" in *[!0-9]*) return 1 ;; esac ;;
		*) return 1 ;;
		esac
		printf '%s\n' "$version"
	}

	hp_replace_file() {
		local source_file="$1" target_file="$2" temporary_file

		temporary_file="${target_file}.tmp.$$"
		cp "$source_file" "$temporary_file" || return 1
		chmod 0644 "$temporary_file" || return 1
		mv -f "$temporary_file" "$target_file"
	}

	hp_update_ip() {
		local version file

		version="$(hp_fetch_release_version "$HP_IP_VERSION_URL")" || return 1
		hp_download "$HP_IP_SOURCE?v=$version" "$HP_TMP/cncidr.txt" || return 1
		awk -F, -v ipv4="$HP_TMP/china_ip4.txt" -v ipv6="$HP_TMP/china_ip6.txt" '
			$1 == "IP-CIDR" { print $2 > ipv4 }
			$1 == "IP-CIDR6" { print $2 > ipv6 }
		' "$HP_TMP/cncidr.txt" || return 1
		[ -s "$HP_TMP/china_ip4.txt" ] && [ -s "$HP_TMP/china_ip6.txt" ] || return 1
		awk '
			BEGIN {
				print "{\"version\":5,\"rules\":[{\"ip_cidr\":["
				first = 1
			}
			NF {
				printf "%s\"%s\"", first ? "" : ",", $0
				first = 0
			}
			END { print "]}]}" }
		' "$HP_TMP/china_ip4.txt" "$HP_TMP/china_ip6.txt" > "$HP_TMP/geoip_cn.json" || return 1
		[ -s "$HP_TMP/geoip_cn.json" ] || return 1
		printf '%s\n' "$version" > "$HP_TMP/china_ip4.ver"
		printf '%s\n' "$version" > "$HP_TMP/china_ip6.ver"
		for file in china_ip4.txt china_ip4.ver china_ip6.txt china_ip6.ver geoip_cn.json; do
			hp_replace_file "$HP_TMP/$file" "$HP_RESOURCES/$file" || return 1
		done
		echo "homeproxy resources: china_ip $version"
	}

	hp_update_geosite() {
		local version

		version="$(hp_fetch_release_version "$HP_GEOSITE_VERSION_URL")" || return 1
		hp_download "$HP_GEOSITE_SOURCE?v=$version" "$HP_TMP/geosite_cn.srs" || return 1
		printf '%s\n' "$version" > "$HP_TMP/geosite_cn.ver"
		hp_replace_file "$HP_TMP/geosite_cn.srs" "$HP_RESOURCES/geosite_cn.srs" || return 1
		hp_replace_file "$HP_TMP/geosite_cn.ver" "$HP_RESOURCES/geosite_cn.ver" || return 1
		echo "homeproxy resources: geosite_cn $version"
	}

	hp_update_dashboard() {
		local version source_dir old_dir

		command -v unzip > /dev/null 2>&1 || return 1
		command -v find > /dev/null 2>&1 || return 1
		version="$(hp_fetch_dashboard_version)" || return 1
		hp_download "$HP_DASHBOARD_SOURCE?v=$version" "$HP_TMP/dashboard.zip" || return 1
		unzip -q "$HP_TMP/dashboard.zip" -d "$HP_TMP/dashboard" || return 1
		source_dir="$(find "$HP_TMP/dashboard" -mindepth 1 -maxdepth 1 -type d -print -quit)"
		[ -n "$source_dir" ] && [ -f "$source_dir/index.html" ] || return 1

		rm -rf "$HP_DASHBOARD_STAGE"
		mkdir -p "$HP_DASHBOARD_STAGE" &&
			cp -a "$source_dir/." "$HP_DASHBOARD_STAGE/" &&
			printf '%s\n' "$version" > "$HP_DASHBOARD_STAGE/dashboard.ver" || return 1
		rm -f "$HP_DASHBOARD_STAGE/.etag"
		chmod -R a+rX "$HP_DASHBOARD_STAGE" || return 1

		old_dir="${HP_DASHBOARD}.old.$$"
		rm -rf "$old_dir"
		{ [ ! -d "$HP_DASHBOARD" ] || mv "$HP_DASHBOARD" "$old_dir"; } || return 1
		if mv "$HP_DASHBOARD_STAGE" "$HP_DASHBOARD"; then
			rm -rf "$old_dir"
			echo "homeproxy dashboard: $version"
			return 0
		fi
		rm -rf "$HP_DASHBOARD"
		[ ! -d "$old_dir" ] || mv "$old_dir" "$HP_DASHBOARD"
		return 1
	}

	if [ "$HP_PRESET_FAILED" -eq 0 ] && ! mkdir -p "$HP_RESOURCES" "$HP_DASHBOARD"; then
		echo "failed to prepare homeproxy resource directories!"
		HP_PRESET_FAILED=1
	fi

	if [ "$HP_PRESET_FAILED" -eq 0 ]; then
		if ! hp_update_ip; then
			echo "failed to update homeproxy IP resources; continuing!"
			HP_PRESET_FAILED=1
		fi

		if ! hp_update_geosite; then
			echo "failed to update homeproxy geosite; continuing!"
			HP_PRESET_FAILED=1
		fi

		if ! hp_update_dashboard; then
			echo "failed to update homeproxy dashboard; continuing!"
			HP_PRESET_FAILED=1
		fi

		rm -rf "$HP_TMP" "$HP_DASHBOARD_STAGE"
		trap - EXIT INT TERM
	fi

	if [ "$HP_PRESET_FAILED" -eq 0 ]; then
		echo "homeproxy data has been updated!"
	else
		echo "homeproxy resource preset completed with errors; continuing other handlers!"
	fi
fi

#预置OpenClash Meta核心和配置（仅高通平台，核心为linux-arm64架构）
if [[ "${WRT_TARGET,,}" == *"qualcommax"* ]]; then
	OC_DIR="$(find "$PKG_PATH" -maxdepth 3 -type d -iname '*openclash*' -print -quit)"
	if [ -n "$OC_DIR" ]; then
		echo " "

		# 核心必须烤到 /etc/openclash/core/clash_meta（OpenClash 规范路径，openclash_core.sh 的 meta_core_path）。
		# 注意：不能放 /usr/share/openclash/core —— 启动时 init 只检测 /etc/openclash/core，
		# 核心缺失会触发联网下载，失败后 enable 被重置为 0（曾导致刷机后首次开机 OpenClash 无法启动）。
		CORE_PATH="$OC_DIR/root/etc/openclash/core"
		CONF_PATH="$OC_DIR/root/etc/openclash/config"
		mkdir -p "$CORE_PATH" "$CONF_PATH"

		#下载Meta核心(linux-arm64)，压缩包内文件名为 clash
		echo "Downloading Clash Meta..."
		if curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 300 \
			"https://raw.githubusercontent.com/vernesong/OpenClash/refs/heads/core/master/meta/clash-linux-arm64.tar.gz" \
			| tar xz -C "$CORE_PATH" clash; then
			mv -f "$CORE_PATH/clash" "$CORE_PATH/clash_meta"
			chmod +x "$CORE_PATH/clash_meta"
			# 校验（构建机为 x86_64，不能执行 arm64 二进制，用 file 判断 ELF 架构 + 大小下限防损坏）
			CORE_SIZE=$(stat -c%s "$CORE_PATH/clash_meta" 2>/dev/null || echo 0)
			if [ "$CORE_SIZE" -gt 5000000 ] && file "$CORE_PATH/clash_meta" | grep -q "ARM aarch64"; then
				echo "clash_meta has been downloaded! ($CORE_SIZE bytes, aarch64 ELF)"
			else
				echo "ERROR: clash_meta 下载成功但校验失败（损坏或架构不符），无法产出可用固件，终止构建！"
				rm -f "$CORE_PATH/clash_meta"
				exit 1
			fi
		else
			echo "ERROR: clash_meta 下载失败，无法产出可用固件，终止构建！"
			exit 1
		fi

		#下载配置文件
		echo "Downloading MihomoPro.yaml..."
		if curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 60 \
			"https://raw.githubusercontent.com/666OS/YYDS/refs/heads/main/mihomo/config/legacy/MihomoPro.yaml" \
			-o "$CONF_PATH/MihomoPro.yaml"; then
			#替换订阅地址（主订阅 MAIN_AIRPORT_SUB / 备用 BACKUP_AIRPORT_SUB，来自 GitHub Secrets）
			[ -n "$MAIN_AIRPORT_SUB" ] || { echo "ERROR: 缺少必需的 GitHub Secret: MAIN_AIRPORT_SUB（请在仓库 Settings → Secrets 中配置）"; exit 1; }
			[ -n "$BACKUP_AIRPORT_SUB" ] || { echo "ERROR: 缺少必需的 GitHub Secret: BACKUP_AIRPORT_SUB（请在仓库 Settings → Secrets 中配置）"; exit 1; }
			# 用 python 做字面替换（订阅 URL 常含 & 等查询参数，sed 会将其当作特殊字符损坏地址）
			MAIN_AIRPORT_SUB="$MAIN_AIRPORT_SUB" BACKUP_AIRPORT_SUB="$BACKUP_AIRPORT_SUB" python3 - "$CONF_PATH/MihomoPro.yaml" <<'PYEOF'
import os, sys
p = sys.argv[1]
main = os.environ["MAIN_AIRPORT_SUB"]
back = os.environ["BACKUP_AIRPORT_SUB"]
s = open(p, encoding="utf-8").read()
# YYDS 模板中的占位符为纯文本「优质订阅源地址」「备用订阅源地址」（见 proxy-providers 段）
s = s.replace("优质订阅源地址", main)
s = s.replace("备用订阅源地址", back)
open(p, "w", encoding="utf-8").write(s)
print("sub URLs injected")
PYEOF
			echo "MihomoPro.yaml has been updated!"
		else
			echo "ERROR: MihomoPro.yaml 下载失败，无法产出可用固件，终止构建！"
			exit 1
		fi

		#预置规则集（rule-providers）：刷机首启死锁修复
		#首启时规则集无本地缓存 → 需联网下载 → 依赖 DNS（fake-ip-filter 域名经 nameserver DoH 解析）→
		#DoH 连接按 respect-rules 路由 → 规则未加载 → 落 MATCH 空代理组 → EOF → 全链路断（曾导致刷机后全屋 DNS 挂）。
		#把模板的全部规则集按 yaml 的 path 字段烤进固件，启动即从本地加载，规则立即生效（已验证：烤入的
		#oc-cn-domain.mrs 首启直接加载 114954 条规则）。
		RULE_DIR="$OC_DIR/root/etc/openclash/rule_provider"
		mkdir -p "$RULE_DIR"
		while read -r RULE_PATH RULE_URL; do
			[ -n "$RULE_URL" ] || continue
			RULE_TARGET="$RULE_DIR/${RULE_PATH#./rule_provider/}"
			echo "Downloading rule-set: $RULE_PATH"
			if curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 120 \
				-o "$RULE_TARGET" "$RULE_URL" && [ -s "$RULE_TARGET" ]; then
				echo "rule-set $RULE_PATH has been downloaded! ($(stat -c%s "$RULE_TARGET") bytes)"
			else
				echo "ERROR: rule-set $RULE_PATH 下载失败，无法产出可用固件，终止构建！"
				rm -f "$RULE_TARGET"
				exit 1
			fi
		done < <(python3 - "$CONF_PATH/MihomoPro.yaml" <<'PYEOF'
import re, sys
p = sys.argv[1]
in_rules = False
cur = None
for line in open(p, encoding="utf-8"):
    line = line.rstrip("\r\n")
    if line.startswith("rule-providers:"):
        in_rules = True
        continue
    if in_rules:
        if line and not line[0].isspace():
            break
        # 内联格式：NAME: {<<: *BehaviorDN, url: https://...}（YYDS 原始模板，无 path，OpenClash 按 ./rule_provider/<NAME> 约定生成）
        m = re.match(r"^  (\S+):\s*(\{.*\})\s*$", line)
        if m:
            um = re.search(r"url:\s*(\S+)", m.group(2))
            if um:
                print(m.group(1) + "\t" + um.group(1).rstrip(" ,}\r"))
            cur = None
            continue
        # 多行格式（展开/处理后）：NAME: 换行 url:/path:
        m = re.match(r"^  ([^:]+):$", line)
        if m:
            cur = {}
            continue
        if cur is not None:
            m = re.match(r"^    (url|path):\s*\"?([^\"]+?)\"?\s*$", line)
            if m:
                cur[m.group(1)] = m.group(2).rstrip()
                if "url" in cur and "path" in cur:
                    print(cur["path"] + "\t" + cur["url"])
                    cur = None
PYEOF
)
		RULE_COUNT=$(ls "$RULE_DIR" | wc -l)
		# 质检：规则集数量下限。若上游 666OS 模板格式变化，上面的解析可能一条都匹配不到，
		# 但下载循环体不执行、也不报错，会静默产出"规则集为空"的固件 → 刷机首启 DNS 死锁（曾实发断网）。
		# 正常约 40 个（39 个 666OS 规则 + 包自带 oc-cn-domain.mrs），低于 30 视为解析失败，终止构建。
		if [ "$RULE_COUNT" -lt 30 ]; then
			echo "ERROR: rule-set 解析/下载数量异常（仅 $RULE_COUNT 个），疑似上游模板格式变化，终止构建！"
			exit 1
		fi
		echo "All rule-sets have been preloaded! ($RULE_COUNT files)"

		#预置 GEO 数据库（GeoIP/GeoSite/ASN/Country）：首启即用，不依赖首启联网下载。
		#下载源与 openclash_geo.sh 一致（Loyalsoldier/v2ray-rules-dat、xishang0128/geoip、alecthw/mmdb_china_ip_list），
		#文件名/路径与 OpenClash 运行期一致（/etc/openclash/GeoIP.dat 等），校验：>10KB 且非 HTML 响应。
		GEO_DIR="$OC_DIR/root/etc/openclash"
		mkdir -p "$GEO_DIR"
		download_geo() {
			local NAME="$1" URL="$2" TARGET="$3" URL_FALLBACK="$4"
			if curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 300 -o "$TARGET" "$URL" && \
				[ -s "$TARGET" ] && [ "$(stat -c%s "$TARGET")" -gt 10240 ] && \
				! head -c 512 "$TARGET" | grep -qiE '<!doctype|<html|<head|<body'; then
				echo "geo $NAME has been downloaded! ($(stat -c%s "$TARGET") bytes)"
				return 0
			fi
			if [ -n "$URL_FALLBACK" ]; then
				echo "retry geo $NAME via fallback URL..."
				if curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 300 -o "$TARGET" "$URL_FALLBACK" && \
					[ -s "$TARGET" ] && [ "$(stat -c%s "$TARGET")" -gt 10240 ] && \
					! head -c 512 "$TARGET" | grep -qiE '<!doctype|<html|<head|<body'; then
					echo "geo $NAME has been downloaded via fallback! ($(stat -c%s "$TARGET") bytes)"
					return 0
				fi
			fi
			echo "ERROR: geo $NAME 下载失败，无法产出可用固件，终止构建！"
			rm -f "$TARGET"
			exit 1
		}
		download_geo "GeoIP.dat" \
			"https://testingcf.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat" \
			"$GEO_DIR/GeoIP.dat" \
			"https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
		download_geo "GeoSite.dat" \
			"https://testingcf.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat" \
			"$GEO_DIR/GeoSite.dat" \
			"https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
		download_geo "ASN.mmdb" \
			"https://testingcf.jsdelivr.net/gh/xishang0128/geoip@release/GeoLite2-ASN.mmdb" \
			"$GEO_DIR/ASN.mmdb" \
			"https://github.com/xishang0128/geoip/releases/latest/download/GeoLite2-ASN.mmdb"
		download_geo "Country.mmdb" \
			"https://testingcf.jsdelivr.net/gh/alecthw/mmdb_china_ip_list@release/lite/Country.mmdb" \
			"$GEO_DIR/Country.mmdb" \
			"https://raw.githubusercontent.com/alecthw/mmdb_china_ip_list/release/lite/Country.mmdb"

		#预置大陆白名单 chnroute（v4/v6 ipset）：与 openclash_chnroute.sh 的 fw4 分支生成格式逐字节一致
		#（ImmortalWRT 使用 firewall4，见 93-buffy-openclash.sh china_ip_route=1），首启即加载中国 IP 直连。
		echo "Downloading chnroute cidr list..."
		CHNR_TMP="$(mktemp -d)"
		if curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 120 \
			-o "$CHNR_TMP/all_cn.txt" "https://ispip.clang.cn/all_cn.txt" && [ -s "$CHNR_TMP/all_cn.txt" ] && \
		   curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 120 \
			-o "$CHNR_TMP/all_cn_ipv6.txt" "https://ispip.clang.cn/all_cn_ipv6.txt" && [ -s "$CHNR_TMP/all_cn_ipv6.txt" ]; then
			{
				echo "define china_ip_route = {"
				awk '!/^$/&&!/^#/{printf("    %s,\n",$0)}' "$CHNR_TMP/all_cn.txt"
				echo "}"
				echo "add set inet fw4 china_ip_route { type ipv4_addr; flags interval; auto-merge; }"
				echo 'add element inet fw4 china_ip_route $china_ip_route'
			} > "$GEO_DIR/china_ip_route.ipset"
			{
				echo "define china_ip6_route = {"
				awk '!/^$/&&!/^#/{printf("    %s,\n",$0)}' "$CHNR_TMP/all_cn_ipv6.txt"
				echo "}"
				echo "add set inet fw4 china_ip6_route { type ipv6_addr; flags interval; auto-merge; }"
				echo 'add element inet fw4 china_ip6_route $china_ip6_route'
			} > "$GEO_DIR/china_ip6_route.ipset"
			echo "chnroute has been preloaded! ($(stat -c%s "$GEO_DIR/china_ip_route.ipset") bytes v4, $(stat -c%s "$GEO_DIR/china_ip6_route.ipset") bytes v6)"
			rm -rf "$CHNR_TMP"
		else
			echo "ERROR: chnroute 下载失败，无法产出可用固件，终止构建！"
			rm -rf "$CHNR_TMP"
			exit 1
		fi

		#预置最新面板版本（Zashboard / Metacubexd）：覆盖 openclash 包自带的旧版，刷机即用最新版。
		#下载源与 openclash_download_dashboard.sh 一致（gh-pages 分支 zip，含 index.html 校验）。
		UI_DIR="$OC_DIR/root/usr/share/openclash/ui"
		mkdir -p "$UI_DIR"
		download_dashboard() {
			local NAME="$1" URL="$2" INCLUDE_DIR="$3" TARGET_DIR="$4"
			local TMP
			TMP="$(mktemp -d)"
			echo "Downloading dashboard: $NAME"
			if curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 300 \
				-o "$TMP/dash.zip" "$URL" && unzip -q "$TMP/dash.zip" -d "$TMP/extract" && \
				[ -d "$TMP/extract/$INCLUDE_DIR" ] && [ -f "$TMP/extract/$INCLUDE_DIR/index.html" ]; then
				rm -rf "$TARGET_DIR"
				cp -rf "$TMP/extract/$INCLUDE_DIR" "$TARGET_DIR"
				rm -rf "$TMP"
				echo "dashboard $NAME has been updated! ($(ls "$TARGET_DIR" | wc -l) files)"
				return 0
			fi
			echo "ERROR: dashboard $NAME 下载失败，无法产出可用固件，终止构建！"
			rm -rf "$TMP"
			exit 1
		}
		download_dashboard "Zashboard" \
			"https://codeload.github.com/Zephyruso/zashboard/zip/refs/heads/gh-pages-cdn-fonts" \
			"zashboard-gh-pages-cdn-fonts" \
			"$UI_DIR/zashboard"
		download_dashboard "Metacubexd" \
			"https://codeload.github.com/MetaCubeX/metacubexd/zip/refs/heads/gh-pages" \
			"metacubexd-gh-pages" \
			"$UI_DIR/metacubexd"
	fi
fi

#修复 OpenClash init 脚本开机噪音（logread 里的 '1: not found' / '0: not found' / 'sh: out of range'）
#根因（设备实测 + 上游 issue #4822/#5084 确认）：boot() -> restart() -> stop_service/start_service
#整条启动链路未重定向输出，start_service 的 do_run_file() 里那行 opkg/apk 检测
#（[ "$small_flash_memory" == "1" ] || ... || $(opkg status libc ...) || $(apk list libc ...) && ...）
#的 &&/|| 优先级与命令替换在 busybox ash 下触发 '1/0: not found' + 'sh: out of range' 噪音，被 procd
#打进开机日志（报错行号落在 /etc/rc.common 的 enable() 函数体 line 42~48）。纯噪音：核心随后照常 Start Successful。
#最小修复：boot() 末尾的 restart 改为重定向到 OpenClash 日志并丢弃 stderr。
#（LOG_* 本就写 /tmp/openclash*.log 不受影响；重定向会传导到函数内所有子调用，含后台 check_core_status。）
#适用于所有平台（openclash 由 GENERAL.txt 全平台构建）；upstream 结构变化时告警跳过，不阻断构建。
OC_INIT_DIR="$(find "$PKG_PATH" -maxdepth 3 -type d -iname '*openclash*' -print -quit)"
if [ -n "$OC_INIT_DIR" ]; then
	OC_INIT="$OC_INIT_DIR/root/etc/init.d/openclash"
	if [ -f "$OC_INIT" ]; then
		echo " "
		python3 - "$OC_INIT" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
# boot() 结尾是 "   restart\n}"（restart() 结尾是 "   start\n}"），该两行序列全文件唯一
old = "   restart\n}"
new = "   restart >> \"$LOG_FILE\" 2>/dev/null\n}"
n = s.count(old)
if n == 1:
    open(p, "w", encoding="utf-8").write(s.replace(old, new))
    print("openclash init boot noise patched!")
else:
    print("WARN: openclash init boot() 结构变化（匹配 %d 处），跳过去噪补丁" % n)
PYEOF
	else
		echo "WARN: 未找到 openclash init 脚本，跳过去噪补丁"
	fi
else
	echo "WARN: 未找到 openclash 目录，跳过去噪补丁"
fi

#修改argon主题字体和颜色
if [ -d "$PKG_PATH/luci-theme-argon" ]; then
	echo " "
	if sed -i "s/primary '.*'/primary '#31a1a1'/; s/'0.2'/'0.5'/; s/'none'/'bing'/; s/'600'/'normal'/" \
		"$PKG_PATH/luci-theme-argon/luci-app-argon-config/root/etc/config/argon"; then
		echo "theme-argon has been fixed!"
	else
		echo "theme-argon fix failed; continuing!"
	fi
fi

#修改aurora菜单式样
if [ -d "$PKG_PATH/luci-app-aurora-config" ]; then
	echo " "
	if find "$PKG_PATH/luci-app-aurora-config/root/usr/share/aurora/" -type f -name '*.template' -exec \
		sed -i "s/nav_type '.*'/nav_type 'dropdown'/g; s/struct_radius_base '.*'/struct_radius_base '0.125rem'/g" {} +; then
		echo "theme-aurora has been fixed!"
	else
		echo "theme-aurora fix failed; continuing!"
	fi
fi

#修改mini-diskmanager菜单位置
if [ -d "$PKG_PATH/luci-app-mini-diskmanager" ]; then
	echo " "
	if sed -i "s/services/system/g" \
		"$PKG_PATH/luci-app-mini-diskmanager/luci-app-mini-diskmanager/root/usr/share/luci/menu.d/luci-app-mini-diskmanager.json"; then
		echo "mini-diskmanager has been fixed!"
	else
		echo "mini-diskmanager fix failed; continuing!"
	fi
fi

#修复TailScale配置文件冲突
FEEDS_PACKAGES="$PKG_PATH/../feeds/packages"
TS_FILE="$(find "$FEEDS_PACKAGES" -maxdepth 3 -type f -wholename '*/tailscale/Makefile' -print -quit 2>/dev/null)"
if [ -f "$TS_FILE" ]; then
	echo " "

	if sed -i '/\/files/d' "$TS_FILE"; then
		echo "tailscale has been fixed!"
	else
		echo "tailscale fix failed; continuing!"
	fi
fi

#修复Rust编译失败
RUST_FILE="$(find "$FEEDS_PACKAGES" -maxdepth 3 -type f -wholename '*/rust/Makefile' -print -quit 2>/dev/null)"
if [ -f "$RUST_FILE" ]; then
	echo " "

	if sed -i 's/ci-llvm=true/ci-llvm=false/g' "$RUST_FILE"; then
		echo "rust has been fixed!"
	else
		echo "rust fix failed; continuing!"
	fi
fi
