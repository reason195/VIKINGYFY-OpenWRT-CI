#!/bin/sh
# export_credentials.sh - 把 OpenClash 当前生效的控制台/API 凭据快照到文本文件，便于查询
#
# 背景：dashboard_password（Dashboard 登录密钥）与 @authentication（clash API 认证）
#   由 luci-app-openclash 包自带的 /etc/uci-defaults/luci-openclash 首启随机生成，
#   本仓库不再自造（见 Files/etc/uci-defaults/93-buffy-openclash.sh）。
#   上游生成后只存在于 uci 里，没有人类可读的落盘形式，本脚本补这个快照。
#
# 调用：/etc/rc.local 每次开机执行（此时 uci-defaults 早已跑完，能读到已生成的密钥）。
#       也可手动执行以刷新快照（例如刚在 LuCI 里改过密钥）。
#
# 幂等：内容与目标文件一致时不写，保持 mtime 稳定，避免无谓的 flash 写入。
#
# 退出码：0 = 快照已就绪（含「内容未变无需重写」）；1 = uci 里读不到任何凭据
#         （OpenClash 未安装，或包的 uci-defaults 尚未执行）。

CRED_FILE="/etc/openclash-credentials.txt"
TMP_FILE="/tmp/.openclash-credentials.$$"

DASH_PW=$(uci -q get openclash.config.dashboard_password)
API_USER=$(uci -q get openclash.@authentication[0].username)
API_PW=$(uci -q get openclash.@authentication[0].password)

# 两个密钥都读不到 = OpenClash 尚未初始化：不产出半截快照，避免误导排障
if [ -z "$DASH_PW" ] && [ -z "$API_PW" ]; then
	exit 1
fi

cat > "$TMP_FILE" <<EOF
# OpenClash 控制台/API 凭据快照（只读，请勿手改；密钥本体在 uci openclash 里）
# 来源：luci-app-openclash 首启随机生成（不保留配置刷机会重新生成）
# 修改：LuCI → OpenClash → 覆写设置；本文件由 /usr/share/buffy/export_credentials.sh 刷新
dashboard_password: $DASH_PW
api_username: $API_USER
api_password: $API_PW
EOF

# 幂等：内容一致就不动目标文件
if [ -f "$CRED_FILE" ] && [ "$(cat "$CRED_FILE" 2>/dev/null)" = "$(cat "$TMP_FILE" 2>/dev/null)" ]; then
	rm -f "$TMP_FILE"
	exit 0
fi

chmod 600 "$TMP_FILE" 2>/dev/null
if mv -f "$TMP_FILE" "$CRED_FILE" 2>/dev/null; then
	chmod 600 "$CRED_FILE" 2>/dev/null
	exit 0
fi

rm -f "$TMP_FILE"
exit 1
