#!/bin/sh
# SPDX-License-Identifier: MIT
# auto_upgrade.sh - 每日检查 GitHub 新固件，发现新版本自动下载校验并 sysupgrade 升级（cron 触发）
# 开关：/etc/config/auto_upgrade 的 enabled（默认 0）；keep_config=1（默认）保留配置升级，0 则 sysupgrade -n 重置。
# 基线：/etc/config/auto_upgrade 的 last_tag 选项记录当前运行的 release tag（/etc/config 为
# sysupgrade 默认保留目录，普通 /etc 文件升级会被清掉）；为空视为首次运行，仅记录基线不刷机。
# 版本发现走 releases.atom（免认证、无匿名限流，api.github.com 按出口 IP 60次/小时不可靠）；
# 资产文件名可由 tag 确定性推导；sha256 校验读 release 附带的 SHA256SUMS.txt（WRT-CORE.yml 构建期生成，
# 旧版 release 无此文件时不刷机、等下一个带校验清单的版本）。下载直连失败回退镜像。
# 安全：board 校验；flock 防重入；失败推 ntfy/Telegram（成功升级后由 boot_selfcheck 兜底验证）。
# 调试：AUTO_UPGRADE_DRYRUN=1 走完整流程但不真正刷写。日志：/tmp/auto_upgrade.log

. /usr/share/buffy/lib-buffy.sh

LOG="/tmp/auto_upgrade.log"

REPO="reason195/VIKINGYFY-OpenWRT-CI"
TAG_PREFIX="IPQ60XX-WIFI-NO-VIKINGYFY-main-"
DEVICE="jdcloud_re-cs-07"
BOARD="jdcloud,re-cs-07"
FW="/tmp/fw-upgrade-auto.bin"

if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 204800 ]; then : > "$LOG"; fi

fail() { # $1=原因：记日志、告警、清理半包后退出
	log "FAIL: $1"
	notify "路由器自动升级失败" "$1（详见 $LOG）"
	rm -f "$FW" "$FW.part" "/tmp/SHA256SUMS-auto.txt.part"
	exit 1
}

log "=== auto_upgrade: start ==="
exec 9>>/tmp/.auto_upgrade.lock
flock -n 9 || { log "已有实例运行，退出"; exit 0; }

[ "$(uci -q get 'auto_upgrade.@auto_upgrade[0].enabled')" = "1" ] || { log "未启用（enabled≠1），退出"; exit 0; }

BOARD_NOW=$(cat /tmp/sysinfo/board_name 2>/dev/null)
[ "$BOARD_NOW" = "$BOARD" ] || fail "设备不匹配（$BOARD_NOW），拒绝自动刷机"

FLAG=""
[ "$(uci -q get 'auto_upgrade.@auto_upgrade[0].keep_config')" = "0" ] && FLAG="-n "

AVAIL=$(df -m /tmp | awk 'NR==2{print $4}')
# 固件约 80–100MB，留足余量防下载中途 /tmp（tmpfs）耗尽；与 upgrade_firmware.py 的空间检查口径一致
[ "${AVAIL:-0}" -ge 150 ] 2>/dev/null || fail "/tmp 可用空间不足（${AVAIL:-?}MB < 150MB）"

# --- 1. 从 releases.atom 发现最新匹配前缀的 tag ---
FEED=$(curl -fsS -m 30 -A "auto_upgrade.sh" "https://github.com/$REPO/releases.atom" 2>/dev/null) \
	|| fail "拉取 releases.atom 失败"
TAG=$(printf '%s' "$FEED" \
	| sed -n 's#.*<id>tag:github.com,2008:Repository/[0-9]*/\([^<]*\)</id>#\1#p' \
	| grep "^$TAG_PREFIX" | head -n1)
[ -n "$TAG" ] || fail "atom 中未找到前缀 $TAG_PREFIX 的 release"

SUFFIX=${TAG#"$TAG_PREFIX"}
NAME="qualcommax-ipq60xx-${DEVICE}-squashfs-sysupgrade-${SUFFIX}.bin"
BASE="https://github.com/$REPO/releases/download/$TAG"

# --- 2. 与基线比对 ---
CUR=$(uci -q get 'auto_upgrade.@auto_upgrade[0].last_tag')
if [ -z "$CUR" ]; then
	uci set "auto_upgrade.@auto_upgrade[0].last_tag=$TAG"
	uci commit auto_upgrade
	log "首次运行：记录当前最新版本 $TAG 为基线（不刷机）"
	exit 0
fi
[ "$TAG" != "$CUR" ] || { log "已是最新（$TAG），退出"; exit 0; }

log "发现新固件：$CUR -> $TAG（$NAME）"

# --- 3. 校验清单（无此文件的旧 release 不刷机，等下一个带清单的版本） ---
SUMS="/tmp/SHA256SUMS-auto.txt"
rm -f "$SUMS" "$FW" "$FW.part"
OK=""
for U in "$BASE/SHA256SUMS.txt" "https://ghproxy.net/$BASE/SHA256SUMS.txt" "https://gh-proxy.com/$BASE/SHA256SUMS.txt"; do
	if curl -fsL --retry 2 -m 60 --connect-timeout 15 -A "auto_upgrade.sh" -o "$SUMS.part" "$U" 2>>"$LOG" \
		&& [ "$(wc -c < "$SUMS.part")" -lt 102400 ]; then OK=1; break; fi
	log "校验清单拉取失败，换下一源：$U"
done
[ -n "$OK" ] || fail "SHA256SUMS.txt 拉取失败（release $TAG 可能未附带校验文件，等待下一版）"
mv "$SUMS.part" "$SUMS"
# 兼容三种条目形态：裸名 / *name / ./name（首版 CI 用 sha256sum ./* 生成过带 ./ 前缀的清单）
EXPECT=$(awk -v n="$NAME" '{f=$2; sub(/^\*/,"",f); sub(/^\.\//,"",f)} f==n{print $1}' "$SUMS")
[ "${#EXPECT}" = "64" ] || fail "SHA256SUMS.txt 中未找到 $NAME 的条目"

# --- 4. 下载固件（直连优先，镜像回退；与 PC 端 upgrade_firmware.py 的 MIRROR_TEMPLATES 保持一致） ---
OK=""
for U in "$BASE/$NAME" "https://ghproxy.net/$BASE/$NAME" "https://gh-proxy.com/$BASE/$NAME"; do
	log "尝试下载：$U"
	if curl -fL --retry 2 -m 900 --connect-timeout 15 -A "auto_upgrade.sh" -o "$FW.part" "$U" 2>>"$LOG"; then
		GOT=$(wc -c < "$FW.part")
		if [ "$GOT" -ge 10485760 ]; then OK=1; break; fi
		log "文件过小（$GOT 字节），疑似错误页，换下一源"
	else
		log "下载失败，换下一源"
	fi
done
[ -n "$OK" ] || fail "全部下载源均失败：$NAME"
mv "$FW.part" "$FW"
GOT=$(sha256sum "$FW" | awk '{print $1}')
[ "$GOT" = "$EXPECT" ] || fail "sha256 不符（got=$GOT want=$EXPECT），拒绝刷入"
log "sha256 校验通过：$GOT"

MODE=保留配置升级
[ -n "$FLAG" ] && MODE=重置配置升级
if [ "${AUTO_UPGRADE_DRYRUN:-0}" = "1" ]; then
	log "[dryrun] 将执行：sysupgrade $FLAG$FW（$MODE）"
	exit 0
fi

notify "路由器自动升级开始" "$CUR -> $TAG（$MODE），即将重启，约 3 分钟恢复"
uci set "auto_upgrade.@auto_upgrade[0].last_tag=$TAG"
uci commit auto_upgrade
log "触发：sysupgrade $FLAG$FW"
sysupgrade $FLAG"$FW" >>"$LOG" 2>&1
RC=$?
sleep 5
if [ "$RC" -ne 0 ]; then
	uci set "auto_upgrade.@auto_upgrade[0].last_tag=$CUR"
	uci commit auto_upgrade  # 校验未过/写入失败，还原基线避免下次误判已升级
	fail "sysupgrade 返回 rc=$RC"
fi
log "sysupgrade 已下发（rc=0），路由器重启中"
