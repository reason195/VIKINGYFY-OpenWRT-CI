#!/bin/sh
# SPDX-License-Identifier: MIT
# test_export_credentials.sh - 路由器端 export_credentials.sh 的沙箱回归测试（无需路由器/网络）
#
# 做法：把脚本中的绝对路径重写到沙箱，PATH 前置 mock uci（从 $UCI_STATE 读 key=value），
# 断言退出码与快照文件内容。
#
# 覆盖（对应 2026-09-27「凭据改由 luci-app-openclash 自己生成」的改动）：
#   1 首次生成：uci 有全部凭据 → 生成快照，三项与 uci 一致
#   2 幂等：紧接再跑一次 → 内容未变故不重写（mtime 保持被改成的过去时间戳）
#   3 值变更：uci 里 dashboard_password 变了 → 快照随之更新
#   4 凭据缺失：uci 读不到任何凭据 → rc=1，且不破坏已有快照
#   5 半截凭据：只有 dashboard_password → rc=0，api_password 行留空
#
# 用法：sh Tests/test_export_credentials.sh
# 退出码：0 = 全部通过；1 = 有失败

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
TARGET="$REPO_DIR/Files/usr/share/buffy/export_credentials.sh"

[ -f "$TARGET" ] || { echo "找不到 $TARGET"; exit 1; }

PASS=0
FAIL=0

# 沙箱路径必须是不含反斜杠的 POSIX 路径：Windows/Git Bash 下 TMPDIR 可能是 Windows 路径，
# 反斜杠会在下面的 sed 替换串里被当作转义字符，破坏路径重写。
SBX=$(mktemp -d /tmp/exportcreds-test.XXXXXX 2>/dev/null || true)
[ -n "${SBX:-}" ] || SBX=$(mktemp -d)
case "$SBX" in
*\\*)
	echo "沙箱路径含反斜杠（$SBX），请设置 POSIX 风格的 TMPDIR 后重试"
	exit 1
	;;
esac

# ---- 沙箱搭建 ----
mkdir -p "$SBX/bin" "$SBX/etc" "$SBX/tmp"

CRED="$SBX/etc/openclash-credentials.txt"
UCI_STATE="$SBX/uci.state"
: > "$UCI_STATE"
export UCI_STATE

# 路径重写用两段式哨兵替换：先统一替换为 @SBX@ 前缀，再展开为真实沙箱路径，
# 避免"先替换出的路径又被后一条规则二次替换"（$SBX 自身含 /tmp/ 时会踩到）。
rewrite() {
	sed -e 's|/etc/openclash-credentials.txt|@SBX@/etc/openclash-credentials.txt|g' \
		-e 's|/tmp/|@SBX@/tmp/|g' "$1" | sed "s|@SBX@|$SBX|g"
}
rewrite "$TARGET" > "$SBX/export_credentials.sh"

# mock uci：从 $UCI_STATE 读 key=value（每行一条），未命中输出空、rc=1
cat > "$SBX/bin/uci" <<'MOCK'
#!/bin/sh
# mock uci: uci [-q] get <key>
[ "${1:-}" = "-q" ] && shift
[ "${1:-}" = "get" ] && shift
key="${1:-}"
[ -n "$key" ] || exit 1
if [ -n "${UCI_STATE:-}" ] && [ -f "$UCI_STATE" ]; then
	while IFS='=' read -r k v; do
		if [ "$k" = "$key" ]; then
			printf '%s\n' "$v"
			exit 0
		fi
	done < "$UCI_STATE"
fi
exit 1
MOCK
chmod +x "$SBX/bin/uci"
PATH="$SBX/bin:$PATH"
export PATH

ok() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
check_eq() { # $1=描述 $2=期望 $3=实得
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$2] 实得 [$3]）"; fi
}
field() { # $1=文件 $2=字段名
	sed -n "s/^$2: //p" "$1" 2>/dev/null | head -1
}

# ---- 用例 1：首次生成 ----
echo "[1] 首次生成"
cat > "$UCI_STATE" <<'EOF'
openclash.config.dashboard_password=Ab3xY9kL
openclash.@authentication[0].username=Clash
openclash.@authentication[0].password=Qw8zR2mN
EOF
rm -f "$CRED"
sh "$SBX/export_credentials.sh"
check_eq "退出码 0" "0" "$?"
if [ -f "$CRED" ]; then ok "快照文件已创建"; else bad "快照文件缺失"; fi
check_eq "dashboard_password 一致" "Ab3xY9kL" "$(field "$CRED" dashboard_password)"
check_eq "api_username 一致" "Clash" "$(field "$CRED" api_username)"
check_eq "api_password 一致" "Qw8zR2mN" "$(field "$CRED" api_password)"

# ---- 用例 2：幂等（内容未变不重写）----
echo "[2] 幂等"
touch -t 200001010000 "$CRED"          # 目标文件 mtime 改到 2000-01-01
MARK="$SBX/mark"; touch -t 200101010000 "$MARK"   # 参照物 2001-01-01
sh "$SBX/export_credentials.sh"
check_eq "退出码 0" "0" "$?"
if [ "$CRED" -ot "$MARK" ]; then
	ok "内容未变时未重写（mtime 仍早于 2001-01-01）"
else
	bad "内容未变却被重写（mtime 已刷新）"
fi
check_eq "内容保持不变" "Ab3xY9kL" "$(field "$CRED" dashboard_password)"

# ---- 用例 3：值变更后同步 ----
echo "[3] 值变更"
cat > "$UCI_STATE" <<'EOF'
openclash.config.dashboard_password=NewPw1234
openclash.@authentication[0].username=Clash
openclash.@authentication[0].password=Zx7cV1b5
EOF
sh "$SBX/export_credentials.sh"
check_eq "退出码 0" "0" "$?"
check_eq "dashboard_password 已更新" "NewPw1234" "$(field "$CRED" dashboard_password)"
check_eq "api_password 已更新" "Zx7cV1b5" "$(field "$CRED" api_password)"
if [ "$CRED" -ot "$MARK" ]; then
	bad "值变更后应重写，但 mtime 未刷新"
else
	ok "值变更后已重写"
fi

# ---- 用例 4：凭据缺失（不破坏已有快照）----
echo "[4] 凭据缺失"
BEFORE=$(cat "$CRED")
: > "$UCI_STATE"
sh "$SBX/export_credentials.sh"
check_eq "退出码 1" "1" "$?"
check_eq "已有快照未被破坏" "$BEFORE" "$(cat "$CRED")"

# ---- 用例 5：半截凭据（只有 dashboard_password）----
echo "[5] 半截凭据"
cat > "$UCI_STATE" <<'EOF'
openclash.config.dashboard_password=OnlyDash1
EOF
rm -f "$CRED"
sh "$SBX/export_credentials.sh"
check_eq "退出码 0" "0" "$?"
check_eq "dashboard_password 写入" "OnlyDash1" "$(field "$CRED" dashboard_password)"
check_eq "api_username 留空" "" "$(field "$CRED" api_username)"
check_eq "api_password 留空" "" "$(field "$CRED" api_password)"

rm -rf "$SBX"

echo
echo "==== $PASS passed / $FAIL failed ===="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
