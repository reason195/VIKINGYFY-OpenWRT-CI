#!/bin/sh
# SPDX-License-Identifier: MIT
# test_buffy_credentials_init.sh - 「凭据快照改由 init 脚本投递」的沙箱回归测试（无需路由器/网络）
#
# 背景（2026-09-29 定位）：/etc/rc.local 位于 /lib/upgrade/keep.d/base-files-essential，
# sysupgrade 永久保留 → 实机 /etc/rc.local 可能仍是旧版固件，写在新版 rc.local 里的开机
# 钩子从不执行，/etc/openclash-credentials.txt 因此从未生成。修复方案：正式落点改为
# /etc/init.d/buffy-credentials（不在 keep.d，新文件必随固件投放），由
# /etc/uci-defaults/94-buffy-credentials.sh 负责 enable（/etc/rc.d/ 同样不在 keep.d，
# 升级后 overlay 重建会丢软链，必须靠 uci-defaults 重建）。
#
# 做法：把脚本里的绝对路径重写到沙箱，用「最小 rc.common 模拟」驱动真实 init 脚本，
# 用 mock init 脚本记录 94 传出的动作，断言调用链与退出码。
#
# 沙箱内两条独立路径，避免互相污染：
#   $SBX/etc/init.d/buffy-credentials      真实 init 脚本（用例 1 由 mock rc.common 驱动）
#   $SBX/mock/etc/init.d/buffy-credentials 记录型 mock（用例 2 中 94 脚本的调用目标）
#
# 覆盖：
#   1 init 脚本：shebang 精确、START=99、经 rc.common 约定 start 能跑通且确实调用 export 一次
#   2 uci-defaults：enable 一次 + 立即 export 一次；且 export 失败（全新刷机时上游还没生成
#     密钥，rc=1）时脚本仍 rc=0 —— 否则会被 uci-defaults 判为「未应用」而每次开机重试刷日志
#   3 静态守卫：rc.local 仍保留 export 调用（全新刷机路径的兜底，勿删）、新文件均为 LF
#
# 用法：sh Tests/test_buffy_credentials_init.sh
# 退出码：0 = 全部通过；1 = 有失败

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

INIT_SRC="$REPO_DIR/Files/etc/init.d/buffy-credentials"
UD_SRC="$REPO_DIR/Files/etc/uci-defaults/94-buffy-credentials.sh"
RCLOCAL_SRC="$REPO_DIR/Files/etc/rc.local"

for f in "$INIT_SRC" "$UD_SRC" "$RCLOCAL_SRC"; do
	[ -f "$f" ] || { echo "找不到 $f"; exit 1; }
done

PASS=0
FAIL=0

# 沙箱路径必须是不含反斜杠的 POSIX 路径：Windows/Git Bash 下 TMPDIR 可能是 Windows 路径，
# 反斜杠会在下面的 sed 替换串里被当作转义字符，破坏路径重写。
SBX=$(mktemp -d /tmp/credinit-test.XXXXXX 2>/dev/null || true)
[ -n "${SBX:-}" ] || SBX=$(mktemp -d)
case "$SBX" in
*\\*)
	echo "沙箱路径含反斜杠（$SBX），请设置 POSIX 风格的 TMPDIR 后重试"
	exit 1
	;;
esac

mkdir -p "$SBX/etc/init.d" "$SBX/mock/etc/init.d" "$SBX/usr/share/buffy" "$SBX/tmp"

# ---- 断言工具 ----
ok() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
check_eq() { # $1=描述 $2=期望 $3=实得
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$2] 实得 [$3]）"; fi
}
count() { # $1=记录文件 → 行数
	if [ -f "$1" ]; then wc -l < "$1" | tr -d ' \t'; else echo 0; fi
}
grep_n() { # $1=正则 $2=文件 → 匹配行数（注释行以 # 开头，不会被 ^[[:space:]]* 前缀匹配到）
	LC_ALL=C grep -c "$1" "$2" 2>/dev/null || true
}
check_lf() { # $1=描述 $2=文件（busybox sh 遇 CR 会报错，固件里必须 LF）
	if LC_ALL=C grep -q "$(printf '\r')" "$2" 2>/dev/null; then
		bad "$1（含 CR，busybox sh 会解析失败）"
	else
		ok "$1"
	fi
}
reset_calls() { rm -f "$SBX/export.calls" "$SBX/enable.calls"; }

# ---- 沙箱搭建 ----
# 路径重写用两段式哨兵替换：先统一替换为 @SBX@ 前缀，再展开为真实沙箱路径，
# 避免"先替换出的路径又被后一条规则二次替换"（$SBX 自身含 /tmp/ 时会踩到）。

# 真实 init 脚本（用例 1 的目标）
sed -e 's|/usr/share/buffy/export_credentials.sh|@SBX@/usr/share/buffy/export_credentials.sh|g' \
	"$INIT_SRC" | sed "s|@SBX@|$SBX|g" > "$SBX/etc/init.d/buffy-credentials"

# 94 脚本（用例 2 的目标）：两个绝对路径都指向沙箱内的对应物
sed -e 's|/etc/init.d/buffy-credentials|@SBX@/mock/etc/init.d/buffy-credentials|g' \
	-e 's|/usr/share/buffy/export_credentials.sh|@SBX@/usr/share/buffy/export_credentials.sh|g' \
	"$UD_SRC" | sed "s|@SBX@|$SBX|g" > "$SBX/uci-defaults-94.sh"

# 最小 rc.common 模拟（真实实现见 /etc/rc.common）：按 OpenWrt 约定 source 目标脚本并调用 action。
# 内核执行 `#!/bin/sh /etc/rc.common` 时等价于 `sh /etc/rc.common <init脚本> <action>`，此处照此驱动。
cat > "$SBX/etc/rc.common" <<'MOCK'
#!/bin/sh
INIT="$1"; shift
ACTION="${1:-start}"
[ -f "$INIT" ] || { echo "no such init script: $INIT" >&2; exit 1; }
. "$INIT"
echo "START=${START:-<unset>}"
case "$ACTION" in
	start) start ;;
	*) echo "unsupported action: $ACTION" >&2; exit 1 ;;
esac
MOCK

# 记录型 mock init 脚本：把收到的动作写进 enable.calls
cat > "$SBX/mock/etc/init.d/buffy-credentials" <<MOCK
#!/bin/sh
echo "\${1:-<none>}" >> "$SBX/enable.calls"
exit 0
MOCK

# mock export_credentials.sh：记录调用，退出码由 $EXPORT_RC 控制
cat > "$SBX/usr/share/buffy/export_credentials.sh" <<MOCK
#!/bin/sh
echo called >> "$SBX/export.calls"
exit "\${EXPORT_RC:-0}"
MOCK

# ---- 用例 1：init 脚本经 rc.common 约定被正确调用 ----
echo "[1] init 脚本"
reset_calls
OUT=$(EXPORT_RC=0 sh "$SBX/etc/rc.common" "$SBX/etc/init.d/buffy-credentials" start 2>&1)
check_eq "start 退出码 0" "0" "$?"
check_eq "START=99（供 rc.d/S99 软链命名）" "START=99" "$OUT"
check_eq "export_credentials.sh 被调用 1 次" "1" "$(count "$SBX/export.calls")"
check_eq "源文件含 START=99" "1" "$(grep_n '^START=99$' "$INIT_SRC")"
check_eq "源文件 start() 中确有 export 调用（非注释行）" "1" \
	"$(grep_n '^[[:space:]]*/usr/share/buffy/export_credentials\.sh' "$INIT_SRC")"
check_eq "init 脚本 shebang 精确匹配" "1" \
	"$(grep_n '^#!/bin/sh /etc/rc\.common$' "$INIT_SRC")"

# ---- 用例 2：uci-defaults 94 脚本 ----
echo "[2] uci-defaults 94"
reset_calls
EXPORT_RC=0 sh "$SBX/uci-defaults-94.sh"
check_eq "升级路径（密钥已存在）退出码 0" "0" "$?"
check_eq "已 enable init 脚本" "1" "$(count "$SBX/enable.calls")"
check_eq "已立即执行一次快照" "1" "$(count "$SBX/export.calls")"
check_eq "传给 init 脚本的动作是 enable" "enable" "$(head -1 "$SBX/enable.calls")"

reset_calls
EXPORT_RC=1 sh "$SBX/uci-defaults-94.sh"
check_eq "全新刷机路径（上游尚未生成密钥）仍退出码 0" "0" "$?"
check_eq "此时仍已 enable" "1" "$(count "$SBX/enable.calls")"

reset_calls
EXPORT_RC=0 sh "$SBX/uci-defaults-94.sh"
EXPORT_RC=0 sh "$SBX/uci-defaults-94.sh"
check_eq "重复执行幂等（enable 累计 2 次，无副作用）" "2" "$(count "$SBX/enable.calls")"

check_eq "94 脚本恒以 exit 0 收尾" "1" "$(grep_n '^exit 0$' "$UD_SRC")"

# ---- 用例 3：静态守卫（防回归）----
echo "[3] 静态守卫"
check_eq "rc.local 仍保留 export 调用（全新刷机路径兜底）" "1" \
	"$(grep_n '^/usr/share/buffy/export_credentials\.sh >/dev/null 2>&1$' "$RCLOCAL_SRC")"
check_lf "init 脚本为 LF" "$INIT_SRC"
check_lf "94 脚本为 LF" "$UD_SRC"
check_lf "rc.local 为 LF" "$RCLOCAL_SRC"

rm -rf "$SBX"

echo
echo "==== $PASS passed / $FAIL failed ===="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
