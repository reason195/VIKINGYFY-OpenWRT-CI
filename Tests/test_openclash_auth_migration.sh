#!/bin/sh
# SPDX-License-Identifier: MIT
# test_openclash_auth_migration.sh - 93-buffy-openclash.sh 凭据迁移的沙箱回归测试
#
# 做法：PATH 前置 mock uci（状态存 $UCI_STATE，每行 key=value，支持
# get/set/delete/commit 与 @section[N] 索引删除后的前移），直接运行真实的
# Files/etc/uci-defaults/93-buffy-openclash.sh（该脚本无绝对文件路径，无需重写）。
#
# 覆盖（对应 2026-10-27「SOCKS5/HTTP(S) 认证恢复由 OpenClash 自己生成」的改动）：
#   1 旧版认证段（clash + 24 位 hex）→ 删除，其余配置原样保留
#   2 上游默认认证段（Clash + 8 位字母数字）→ 保留不动
#   3 用户名 clash 但口令已自定义 → 视为用户值，保留
#   4 旧版段在 [0]、用户段在 [1] → 只删旧版，用户段前移且内容完整
#   5 无认证段 → 不凭空生成（生成由上游 luci-openclash 负责）
#   6 幂等：连续执行两次结果一致
#   7 Dashboard 旧密钥迁移（24 位 hex 删、8 位留）回归
#
# 用法：sh Tests/test_openclash_auth_migration.sh
# 退出码：0 = 全部通过；1 = 有失败

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
TARGET="$REPO_DIR/Files/etc/uci-defaults/93-buffy-openclash.sh"

[ -f "$TARGET" ] || { echo "找不到 $TARGET"; exit 1; }

PASS=0
FAIL=0

SBX=$(mktemp -d /tmp/oc-auth-migrate.XXXXXX 2>/dev/null || true)
[ -n "${SBX:-}" ] || SBX=$(mktemp -d)
case "$SBX" in
*\\*)
	echo "沙箱路径含反斜杠（$SBX），请设置 POSIX 风格的 TMPDIR 后重试"
	exit 1
	;;
esac

mkdir -p "$SBX/bin"
UCI_STATE="$SBX/uci.state"
: > "$UCI_STATE"
export UCI_STATE

# mock uci：只实现本脚本用到的子集。@section[N] 的 get 返回合成段名并在删除时前移高位下标。
cat > "$SBX/bin/uci" <<'MOCK'
#!/bin/sh
[ "${1:-}" = "-q" ] && shift
cmd="${1:-}"
[ $# -gt 0 ] && shift
st="${UCI_STATE:?}"
[ -f "$st" ] || : > "$st"

get_val() { # $1=key → 打印值，未命中 rc=1
	awk -v k="$1" 'BEGIN{FS="="}
		{ if (substr($0, 1, length(k) + 1) == k "=") { print substr($0, length(k) + 2); f=1; exit } }
		END { exit(f ? 0 : 1) }' "$st"
}

case "$cmd" in
get)
	key="${1:-}"; [ -n "$key" ] || exit 1
	case "$key" in
	*'@'*'['*']')
		base="${key%%\[*}"; idx="${key#*\[}"; idx="${idx%%\]*}"
		if awk -v p="$base[$idx]." 'substr($0, 1, length(p)) == p { f=1; exit } END { exit(f ? 0 : 1) }' "$st"; then
			printf 'cfg%s\n' "$idx"; exit 0
		fi
		exit 1
		;;
	esac
	get_val "$key"
	;;
set)
	kv="${1:-}"
	case "$kv" in
	*=*) k="${kv%%=*}"; v="${kv#*=}" ;;
	*) k="$kv"; v="" ;;
	esac
	[ -n "$k" ] || exit 1
	awk -v k="$k" -v v="$v" 'BEGIN{FS="="}
		substr($0, 1, length(k) + 1) != k "="' "$st" > "$st.new" && printf '%s=%s\n' "$k" "$v" >> "$st.new" && mv "$st.new" "$st"
	;;
delete)
	key="${1:-}"; [ -n "$key" ] || exit 1
	case "$key" in
	*'@'*'['*']')
		base="${key%%\[*}"; idx="${key#*\[}"; idx="${idx%%\]*}"
		awk -v base="$base" -v idx="$idx" '
			{
				pfx = base "["
				if (substr($0, 1, length(pfx)) == pfx) {
					rest = substr($0, length(pfx) + 1)   # "0].username=clash"
					n = rest; sub(/\].*$/, "", n)
					if (n ~ /^[0-9]+$/) {
						if (n + 0 == idx + 0) next
						if (n + 0 > idx + 0) { print base "[" (n - 1) "]" substr(rest, length(n) + 2); next }
					}
				}
				print
			}' "$st" > "$st.new" && mv "$st.new" "$st"
		;;
	*)
		awk -v k="$key" 'substr($0, 1, length(k) + 1) != k "="' "$st" > "$st.new" && mv "$st.new" "$st"
		;;
	esac
	;;
commit) exit 0 ;;
*) exit 1 ;;
esac
exit 0
MOCK
chmod +x "$SBX/bin/uci"
PATH="$SBX/bin:$PATH"
export PATH

ok() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
check_eq() { # $1=描述 $2=期望 $3=实得
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$2] 实得 [$3]）"; fi
}
val() { # 用 awk 精确匹配前缀：key 里的 [0] 在 sed BRE 中是字符类，不能用 sed
	awk -v k="$1" 'BEGIN{FS="="}
		substr($0, 1, length(k) + 1) == k "=" { print substr($0, length(k) + 2); exit }' "$UCI_STATE"
}
has() { grep -q "^$1=" "$UCI_STATE" 2>/dev/null; }
auth_count() { grep -c '^openclash\.@authentication\[' "$UCI_STATE" 2>/dev/null || true; }
run93() { sh "$TARGET"; }

# ---- 用例 1：旧版认证段 + 旧版 Dashboard 密钥 ----
echo "[1] 旧版自造值被清除"
cat > "$UCI_STATE" <<'EOF'
openclash.config.dashboard_password=0123456789abcdef01234567
openclash.@authentication[0].enabled=1
openclash.@authentication[0].username=clash
openclash.@authentication[0].password=fedcba9876543210fedcba98
openclash.config.keep_me=untouched
EOF
run93
check_eq "退出码 0" "0" "$?"
check_eq "认证段已删除" "0" "$(auth_count)"
if has openclash.config.dashboard_password; then bad "旧版 Dashboard 密钥未清除"; else ok "旧版 Dashboard 密钥已清除"; fi
check_eq "无关配置保留" "untouched" "$(val openclash.config.keep_me)"
check_eq "脚本自身选项仍生效" "fake-ip" "$(val openclash.config.en_mode)"

# ---- 用例 2：上游默认值不受影响 ----
echo "[2] 上游默认认证段保留"
cat > "$UCI_STATE" <<'EOF'
openclash.config.dashboard_password=Ab3xY9kL
openclash.@authentication[0].enabled=1
openclash.@authentication[0].username=Clash
openclash.@authentication[0].password=Zx9Qw2Er
EOF
run93
check_eq "退出码 0" "0" "$?"
check_eq "用户名保留" "Clash" "$(val 'openclash.@authentication[0].username')"
check_eq "口令保留" "Zx9Qw2Er" "$(val 'openclash.@authentication[0].password')"
check_eq "Dashboard 8 位密钥保留" "Ab3xY9kL" "$(val openclash.config.dashboard_password)"

# ---- 用例 3：用户名 clash 但口令已自定义 → 保留 ----
echo "[3] 用户自定义口令保留"
cat > "$UCI_STATE" <<'EOF'
openclash.@authentication[0].enabled=1
openclash.@authentication[0].username=clash
openclash.@authentication[0].password=my-own-secret
EOF
run93
check_eq "退出码 0" "0" "$?"
check_eq "认证段保留" "3" "$(auth_count)"
check_eq "自定义口令保留" "my-own-secret" "$(val 'openclash.@authentication[0].password')"

# ---- 用例 4：旧版段与用户段共存 → 只删旧版，用户段前移 ----
echo "[4] 多段：只删旧版并前移"
cat > "$UCI_STATE" <<'EOF'
openclash.@authentication[0].enabled=1
openclash.@authentication[0].username=clash
openclash.@authentication[0].password=00112233445566778899aabb
openclash.@authentication[1].enabled=1
openclash.@authentication[1].username=me
openclash.@authentication[1].password=pw1
EOF
run93
check_eq "退出码 0" "0" "$?"
check_eq "只剩用户段" "3" "$(auth_count)"
check_eq "用户段前移到 [0]" "me" "$(val 'openclash.@authentication[0].username')"
check_eq "用户口令完整" "pw1" "$(val 'openclash.@authentication[0].password')"
check_eq "enabled 一并前移" "1" "$(val 'openclash.@authentication[0].enabled')"

# ---- 用例 5：无认证段 → 不凭空生成 ----
echo "[5] 无认证段不新建"
cat > "$UCI_STATE" <<'EOF'
openclash.config.dashboard_password=Ab3xY9kL
EOF
run93
check_eq "退出码 0" "0" "$?"
check_eq "未新增认证段" "0" "$(auth_count)"

# ---- 用例 6：幂等 ----
echo "[6] 幂等"
cat > "$UCI_STATE" <<'EOF'
openclash.@authentication[0].enabled=1
openclash.@authentication[0].username=clash
openclash.@authentication[0].password=aaaabbbbccccddddeeeeffff
EOF
run93
FIRST=$(cat "$UCI_STATE")
run93
check_eq "退出码 0" "0" "$?"
check_eq "二次执行结果一致" "$FIRST" "$(cat "$UCI_STATE")"
check_eq "认证段仍为空" "0" "$(auth_count)"

# ---- 用例 7：Dashboard 密钥迁移回归 ----
echo "[7] Dashboard 密钥迁移回归"
cat > "$UCI_STATE" <<'EOF'
openclash.config.dashboard_password=aaaaaaaabbbbbbbbcccccccc
EOF
run93
check_eq "退出码 0" "0" "$?"
if has openclash.config.dashboard_password; then bad "24 位 hex 未清除"; else ok "24 位 hex 已清除"; fi
cat > "$UCI_STATE" <<'EOF'
openclash.config.dashboard_password=KeepMe99
EOF
run93
check_eq "非旧版格式保留" "KeepMe99" "$(val openclash.config.dashboard_password)"

rm -rf "$SBX"

echo
echo "==== $PASS passed / $FAIL failed ===="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
