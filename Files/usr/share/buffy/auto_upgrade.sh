#!/bin/sh
# SPDX-License-Identifier: MIT
# auto_upgrade.sh - 每日检查 GitHub 新固件，发现新版本自动下载校验并 sysupgrade 升级（cron 触发）
# 开关：/etc/config/auto_upgrade 的 enabled（默认 1，见 Files/etc/config/auto_upgrade）；
# 刷机默认不保留配置（keep_config=0 → sysupgrade -n），只有显式 keep_config=1 才保留。
# 开关位于 /etc/config —— 该目录会被 sysupgrade -n 清空，历史上一次"不保留配置"刷机曾让本功能
# 静默失效三天（2026-09-15~17 日志只有"未启用"，无任何告警）。对策：配置段缺失时自动重建；
# 未启用时退出行为不变，但每周一推一次告警（/tmp 标记节流，每 boot 最多一次）。
# 基线：/etc/config/auto_upgrade 的 last_tag 记录当前运行的 release tag（/etc/config 为 sysupgrade
# 默认保留目录，普通 /etc 文件升级会被清掉）。last_tag 为空时优先读固件内 /etc/buffy-version
# （构建期由 Scripts/Settings.sh 写入本固件 tag）作为"运行版本"基线，使配置被重置后仍能正确判断
# 运行版本 vs 最新版本并升级；无该文件（旧固件）时退回旧行为：仅记录最新版本为基线、不刷机。
# 版本发现走 releases.atom（免认证、无匿名限流，api.github.com 按出口 IP 60次/小时不可靠）；
# 资产文件名可由 tag 确定性推导；sha256 校验读 release 附带的 SHA256SUMS.txt（WRT-CORE.yml 构建期生成，
# 旧版 release 无此文件时不刷机、等下一个带校验清单的版本）。下载直连失败回退镜像。
# 安全：board 校验；flock 防重入；失败推 ntfy/Telegram（成功升级后由 boot_selfcheck 兜底验证）。
# 调试：AUTO_UPGRADE_DRYRUN=1 走完整流程但不真正刷写。日志：/tmp/auto_upgrade.log

. /usr/share/buffy/lib-buffy.sh

LOG="/tmp/auto_upgrade.log"

REPO="reason195/VIKINGYFY-OpenWRT-CI"
# TAG_PREFIX 不写死：由 /etc/buffy-version（本固件的 release tag）在运行时剥掉末尾日期推导，
# 见下方「分支前缀」一节。上游换分支（main→owrt）会让写死的前缀一夜之间失效，
# 表现为「atom 中未找到前缀 … 的 release」刷机停更，而没有版本文件时更隐蔽。
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

# 配置段缺失时重建：/etc/config 被清空后 uci set 会静默失败，脚本将永远停在基线写入分支而不升级
if ! uci -q get 'auto_upgrade.@auto_upgrade[0]' >/dev/null 2>&1; then
	uci -q add auto_upgrade auto_upgrade
	uci set 'auto_upgrade.@auto_upgrade[0].enabled=1'
	uci set 'auto_upgrade.@auto_upgrade[0].keep_config=0'
	uci commit auto_upgrade
	log "配置段缺失，已按默认值重建（enabled=1，keep_config=0）"
fi

if [ "$(uci -q get 'auto_upgrade.@auto_upgrade[0].enabled')" = "1" ]; then
	:
else
	# 未启用是历史故障的静默点：不告警时用户无从察觉（2026-09-15~17 连续三天无升级、无提示）。
	# 退出行为保持不变，仅每周一（date +%u = 1）首次运行时推一次告警，/tmp 标记节流。
	log "未启用（enabled≠1），退出"
	if [ "$(date +%u)" = "1" ] && [ ! -f /tmp/.auto_upgrade_off_notified ]; then
		touch /tmp/.auto_upgrade_off_notified
		notify "路由器自动升级未启用" "auto_upgrade enabled≠1，固件不会自动升级。启用：uci set auto_upgrade.@auto_upgrade[0].enabled=1 && uci commit auto_upgrade"
	fi
	exit 0
fi

BOARD_NOW=$(cat /tmp/sysinfo/board_name 2>/dev/null)
[ "$BOARD_NOW" = "$BOARD" ] || fail "设备不匹配（$BOARD_NOW），拒绝自动刷机"

# 默认走不保留配置刷机：仅 keep_config=1 才保留；缺失或其他值一律按 sysupgrade -n 处理
FLAG="-n "
MODE=重置配置升级
[ "$(uci -q get 'auto_upgrade.@auto_upgrade[0].keep_config')" = "1" ] && { FLAG=""; MODE=保留配置升级; }
log "刷机模式：$MODE"

# 保留配置升级时额外带上 Tailscale 节点身份（/etc/tailscale/tailscaled.state 不在
# sysupgrade 默认保留清单里）：不带它的后果是每次刷机都以同一 authkey 重新注册，
# tailnet 里出现 owrt-1/-2 之类新节点、旧节点残留，子网路由批准也要重来。
TS_BACKUP="/tmp/ts-state-backup.tar.gz"
rm -f "$TS_BACKUP"
if [ -z "$FLAG" ] && [ -s /etc/tailscale/tailscaled.state ]; then
	if tar -czf "$TS_BACKUP" /etc/tailscale/tailscaled.state 2>/dev/null && [ -s "$TS_BACKUP" ]; then
		FLAG="-f $TS_BACKUP "
		log "已打包 /etc/tailscale/tailscaled.state，升级时保留 Tailscale 节点身份"
	fi
fi

AVAIL=$(df -m /tmp | awk 'NR==2{print $4}')
# 固件约 80–100MB，留足余量防下载中途 /tmp（tmpfs）耗尽；与 upgrade_firmware.py 的空间检查口径一致
[ "${AVAIL:-0}" -ge 150 ] 2>/dev/null || fail "/tmp 可用空间不足（${AVAIL:-?}MB < 150MB）"

# --- 0. 分支前缀：只刷与本机构建同 CI 分支的新版 ---
# tag 形如 IPQ60XX-WIFI-NO-VIKINGYFY-<CI分支>-<YY.MM.DD-HH.MM.SS>。CI 分支名自身可能含 '-'
# （如 feat/xxx → feat-xxx），不能按「第几段」截取，只能按末尾日期格式剥离。
# 推导不出来就停更：宁可一直不升级，也不能拿别的分支/别的项目的镜像覆盖本机
# —— 主路由与旁路由两种角色的 network/dhcp/防火墙是整套互换的。
RUNNING=$(cat /etc/buffy-version 2>/dev/null)
TAG_PREFIX=""
case "$RUNNING" in
	*[0-9][0-9].[0-9][0-9].[0-9][0-9]-[0-9][0-9].[0-9][0-9].[0-9][0-9])
		# 只剥日期本体、保留它前面那个横杠：前缀必须以 '-' 结尾，
		# 否则 SUFFIX=${TAG#"$TAG_PREFIX"} 会剩一个多余的横杠，资产名拼不出来。
		TAG_PREFIX=$(printf '%s\n' "$RUNNING" | sed 's/[0-9][0-9]\.[0-9][0-9]\.[0-9][0-9]-[0-9][0-9]\.[0-9][0-9]\.[0-9][0-9]$//')
		;;
esac
if [ -z "$TAG_PREFIX" ] || [ "$TAG_PREFIX" = "$RUNNING" ]; then
	log "无法从 /etc/buffy-version 推导 release 前缀（内容：${RUNNING:-文件缺失}），跳过自动刷机"
	# 每 boot 只推一次（/tmp 重启即清），避免 cron 每天重复告警刷屏
	if [ ! -f /tmp/.auto_upgrade_noprefix ]; then
		touch /tmp/.auto_upgrade_noprefix
		notify "路由器自动升级已跳过" "本机缺少可用的构建标识 /etc/buffy-version，判断不出属于哪个 CI 分支。为避免刷到别的分支/别的项目的固件，自动刷机已跳过。手动升级请显式指定标签：python3 Scripts/upgrade_firmware.py --tag <release 标签>；刷入带构建标识的镜像后本功能自动恢复。"
	fi
	exit 0
fi
log "本机 release 前缀：$TAG_PREFIX"

# --- 1. 从 releases.atom 发现最新匹配前缀的 tag ---
FEED=$(curl -fsS -m 30 -A "auto_upgrade.sh" "https://github.com/$REPO/releases.atom" 2>/dev/null) \
	|| fail "拉取 releases.atom 失败"
TAG=$(printf '%s' "$FEED" \
	| sed -n 's#.*<id>tag:github.com,2008:Repository/[0-9]*/\([^<]*\)</id>#\1#p' \
	| grep "^$TAG_PREFIX" | head -n1)
if [ -z "$TAG" ]; then
	# 不算故障：本分支可能一次都还没构建过（换分支首日必然如此）。走 fail() 会每天推一条告警，
	# 与真正的下载/校验失败混在一起，反而掩盖真正出问题的那一类。
	log "atom 中没有属于本分支（$TAG_PREFIX）的 release，等待下次构建"
	exit 0
fi

SUFFIX=${TAG#"$TAG_PREFIX"}
NAME="qualcommax-ipq60xx-${DEVICE}-squashfs-sysupgrade-${SUFFIX}.bin"
BASE="https://github.com/$REPO/releases/download/$TAG"

# --- 2. 与基线比对 ---
CUR=$(uci -q get 'auto_upgrade.@auto_upgrade[0].last_tag')
if [ -z "$CUR" ]; then
	# 基线自愈：/etc/buffy-version 由构建期 Settings.sh 写入，内容就是本固件的 release tag。
	# 必须以"运行版本"为基线才能判断是否需要升级；否则会把最新版本记为基线，
	# 造成配置被重置后永远落后一版且此后再不升级（2026-09-17 排障定位到的第二个缺陷）。
	# 能走到这里 RUNNING 必然非空——第 0 节已用推导出的前缀并在缺失时提前退出。
	CUR="$RUNNING"
	uci set "auto_upgrade.@auto_upgrade[0].last_tag=$CUR"
	uci commit auto_upgrade
	log "基线缺失，已按固件内构建版本初始化：$CUR"
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
