#!/bin/sh
# 启用 /etc/init.d/buffy-credentials —— 每次开机刷新 OpenClash 凭据快照
# （/etc/openclash-credentials.txt；密钥本体由 luci-app-openclash 自带
#   /etc/uci-defaults/luci-openclash 首启随机生成，本仓库不自造，见 93-buffy-openclash.sh）。
#
# 为什么需要本文件（2026-09-29 定位）：
#   /etc/init.d/ 不在 /lib/upgrade/keep.d 内 → 新增的 init 脚本必然随固件投放（好）；
#   但 /etc/rc.d/ 同样不在 keep.d 内 → sysupgrade 后 overlay 重建，镜像里没有预置的
#   enable 软链会丢失，必须由 uci-defaults 重新建立。
#   而 uci-defaults 本身（/etc/uci-defaults/）也不在 keep.d 内：脚本首启被消费删除，
#   升级后 overlay 重建 → 整套脚本重新投放并再执行一次。这正是 90/91/92/93-buffy-*.sh
#   的配置改动在升级后的实机上仍然生效的机制。
#
# 为什么这里还立即执行一次快照：
#   升级路径（auto_upgrade 的 keep_config=1）下 /etc/config/openclash 被保留，密钥早已存在
#   → 升级后首次开机即产出快照，不必等下一次重启（这是本方案相对「挂在 boot_selfcheck.sh
#   里」的优势：后者带 sleep 120 前置延迟）。
#
# 全新刷机路径的说明（因此 rc.local 里的调用予以保留）：
#   本文件以数字开头，按 uci-defaults 的 `ls` 字典序排在 luci-openclash 之前（'9' < 'l'），
#   此时上游尚未生成密钥 → export_credentials.sh 返回 1、不产出半截快照（属预期）。
#   Files/etc/rc.local 由 /etc/init.d/done（START=95）执行，晚于全部 uci-defaults，
#   此时密钥已就绪 → 由它兜底首启快照。
#
# 恒 exit 0：enable 是这里唯一必须成功的动作（已先行执行）；快照失败在全新刷机路径上由
# rc.local 兜底，且若因未装 OpenClash 而长期失败，非 0 退出会让本脚本被 uci-defaults
# 判定为「未应用」而每次开机重试、反复刷日志，得不偿失。

/etc/init.d/buffy-credentials enable >/dev/null 2>&1
/usr/share/buffy/export_credentials.sh >/dev/null 2>&1

exit 0
