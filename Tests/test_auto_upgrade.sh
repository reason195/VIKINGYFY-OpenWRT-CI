#!/bin/sh
# SPDX-License-Identifier: MIT
# test_auto_upgrade.sh - 路由器端 auto_upgrade.sh 的沙箱回归测试（无需路由器/网络）
#
# 做法：把脚本中的绝对路径重写到沙箱，PATH 前置 mock（uci/curl/df/flock/date/sysupgrade），
# 用最小 atom 源与假 uci 状态驱动决策逻辑，断言日志输出与 uci 状态。
# 沙箱内 curl 只对 releases.atom 返回 fixture、其余一律失败，因此下载永远走失败分支，
# 不会真的下载或刷机（另加 sysupgrade mock 兜底并断言其从未被调用）。
#
# 覆盖（对应 2026-09-17「新固件未自动升级」排障后的修复）：
#   1 正常升级路径（last_tag 落后于最新 release）
#   2 基线自愈：last_tag 缺失 + 固件内含 /etc/buffy-version → 以运行版本为基线并升级
#   3 旧固件兜底：last_tag 缺失且无 buffy-version → 仅记录基线、不刷机
#   4 已是最新
#   5 未启用：退出行为不变，周一推一次告警（/tmp 标记节流）
#   6 配置段缺失：自动重建并继续
#
# 用法：sh Tests/test_auto_upgrade.sh
# 退出码：0 = 全部通过；1 = 有失败
# 注意：Windows/Git Bash 下进程创建很慢（每个 mock 都是一次 fork），单次运行约 2–4 分钟；
# Linux 上不到 1 秒。本机验证建议后台运行。

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
TARGET="$REPO_DIR/Files/usr/share/buffy/auto_upgrade.sh"
LIB="$REPO_DIR/Files/usr/share/buffy/lib-buffy.sh"

[ -f "$TARGET" ] || { echo "找不到 $TARGET"; exit 1; }
[ -f "$LIB" ] || { echo "找不到 $LIB"; exit 1; }

REAL_DATE=$(command -v date)
[ -x "$REAL_DATE" ] || REAL_DATE=/bin/date
TAG_NEW="IPQ60XX-WIFI-NO-VIKINGYFY-main-26.09.17-06.35.27"
TAG_OLD="IPQ60XX-WIFI-NO-VIKINGYFY-main-26.09.08-06.29.39"
PASS=0
FAIL=0

# 沙箱路径必须是不含反斜杠的 POSIX 路径：Windows/Git Bash 下 TMPDIR 可能是 Windows 路径，
# 反斜杠会在下面的 sed 替换串里被当作转义字符，破坏路径重写。
SBX=$(mktemp -d /tmp/autoupgrade-test.XXXXXX 2>/dev/null || true)
[ -n "${SBX:-}" ] || SBX=$(mktemp -d)
case "$SBX" in
*\\*)
	echo "沙箱路径含反斜杠（$SBX），请设置 POSIX 风格的 TMPDIR 后重试"
	exit 1
	;;
esac

# ---- 沙箱搭建 ----
mkdir -p "$SBX/bin" "$SBX/etc" "$SBX/tmp/sysinfo" "$SBX/share/buffy"
echo "jdcloud,re-cs-07" > "$SBX/tmp/sysinfo/board_name"

# 路径重写用两段式哨兵替换：先统一替换为 @SBX@ 前缀，再展开为真实沙箱路径，
# 避免"先替换出的路径又被后一条规则二次替换"（$SBX 自身含 /tmp/ 时会踩到）。
rewrite() {
	sed -e 's|/usr/share/buffy|@SBX@/share/buffy|g' \
		-e 's|/etc/buffy-version|@SBX@/etc/buffy-version|g' \
		-e 's|/etc/buffy-notify.conf|@SBX@/etc/buffy-notify.conf|g' \
		-e 's|/tmp/|@SBX@/tmp/|g' "$1" | sed "s|@SBX@|$SBX|g"
}
rewrite "$TARGET" > "$SBX/auto_upgrade.sh"
rewrite "$LIB" > "$SBX/share/buffy/lib-buffy.sh"

# 最小 atom 源（含 feed 级 id 与两条 entry，格式与 GitHub releases.atom 一致）
cat > "$SBX/etc/atom.xml" <<'ATOM'
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en-US">
  <id>tag:github.com,2008:https://github.com/reason195/VIKINGYFY-OpenWRT-CI/releases</id>
  <title>Release notes from VIKINGYFY-OpenWRT-CI</title>
  <entry>
    <id>tag:github.com,2008:Repository/1298512691/IPQ60XX-WIFI-NO-VIKINGYFY-main-26.09.17-06.35.27</id>
    <title>IPQ60XX-WIFI-NO-VIKINGYFY-main-26.09.17-06.35.27</title>
  </entry>
  <entry>
    <id>tag:github.com,2008:Repository/1298512691/IPQ60XX-WIFI-NO-VIKINGYFY-main-26.09.08-06.29.39</id>
    <title>IPQ60XX-WIFI-NO-VIKINGYFY-main-26.09.08-06.29.39</title>
  </entry>
</feed>
ATOM

# uci mock：状态存于 $SBX/etc/uci-state（section/enabled/keep_config/last_tag）
# 注意：key 前缀含 [0]，参数展开 ${k#prefix} 里 [0] 是通配符（匹配字符 0）而非字面量，
# 必须用 case + 引号模式做字面剥离；读写状态也用纯 shell 循环，避免热路径频繁创建子进程。
cat > "$SBX/bin/uci" <<UCI
#!/bin/sh
STATE="$SBX/etc/uci-state"
PREFIX='auto_upgrade.@auto_upgrade[0]'
[ -f "\$STATE" ] || : > "\$STATE"

get_state() {
	V=""
	while IFS= read -r L; do
		case "\$L" in
		"\$1"=*) V="\${L#*=}" ;;
		esac
	done < "\$STATE"
	printf '%s' "\$V"
}

set_state() {
	: > "\$STATE.new"
	while IFS= read -r L; do
		case "\$L" in
		"\$1"=*) : ;;
		*) printf '%s\n' "\$L" >> "\$STATE.new" ;;
		esac
	done < "\$STATE"
	printf '%s=%s\n' "\$1" "\$2" >> "\$STATE.new"
	mv "\$STATE.new" "\$STATE"
}

[ "\${1:-}" = "-q" ] && shift
case "\${1:-}" in
	get)
		KEY="\${2:-}"
		case "\$KEY" in
		"\$PREFIX") KEY=section ;;
		"\$PREFIX".*) KEY="\${KEY#"\$PREFIX".}" ;;
		*) KEY="" ;;
		esac
		V=\$(get_state "\$KEY")
		[ -n "\$V" ] || exit 1
		printf '%s\n' "\$V"
		;;
	set)
		KV="\${2:-}"
		KEY="\${KV%%=*}"
		case "\$KEY" in
		"\$PREFIX".*) KEY="\${KEY#"\$PREFIX".}" ;;
		*) exit 1 ;;
		esac
		set_state "\$KEY" "\${KV#*=}"
		;;
	add)
		set_state section auto_upgrade
		;;
	commit)
		:
		;;
	*)
		exit 1
		;;
esac
exit 0
UCI

# curl mock：atom 源返回 fixture；其余请求失败（下载路径必然走 fail()）；记录全部调用
cat > "$SBX/bin/curl" <<CURL
#!/bin/sh
printf '%s\n' "\$*" >> "$SBX/etc/curl.log"
for A in "\$@"; do
	case "\$A" in
	*releases.atom*) cat "$SBX/etc/atom.xml"; exit 0 ;;
	esac
done
exit 22
CURL

# df mock：/tmp 空间充足
cat > "$SBX/bin/df" <<'DF'
#!/bin/sh
echo "Filesystem     1M-blocks      Used Available Use% Mounted on"
echo "tmpfs                975         1       974   0% /tmp"
DF

# flock mock：测试串行，无需并发控制
cat > "$SBX/bin/flock" <<'FLOCK'
#!/bin/sh
exit 0
FLOCK

# sysupgrade mock：仅记录调用（沙箱内不应被触发）
cat > "$SBX/bin/sysupgrade" <<SUPG
#!/bin/sh
printf '%s\n' "\$*" >> "$SBX/etc/sysupgrade.log"
exit 0
SUPG

# date mock：接管 +%u（周一告警节流判定）与日志时间戳（避免热路径再 exec 真实 date），其余透传
cat > "$SBX/bin/date" <<DATE
#!/bin/sh
case "\${1:-}" in
+%u) echo "\${MOCK_DOW:-3}"; exit 0 ;;
"+%F %T") echo "2026-09-17 10:07:00"; exit 0 ;;
esac
exec "$REAL_DATE" "\$@"
DATE

chmod +x "$SBX/bin/"* || exit 1
PATH="$SBX/bin:$PATH"
export PATH

# ---- 断言助手 ----
LOG_HAS() { grep -q "$1" "$SBX/tmp/auto_upgrade.log"; }
LOG_NOT() { ! grep -q "$1" "$SBX/tmp/auto_upgrade.log"; }
LAST_TAG() { sed -n 's/^last_tag=//p' "$SBX/etc/uci-state" | tail -n 1; }
CURL_CALLED() { [ -s "$SBX/etc/curl.log" ]; }
SUPG_CALLED() { [ -s "$SBX/etc/sysupgrade.log" ]; }

check() { # check <描述> <条件表达式>
	if eval "$2"; then
		PASS=$((PASS + 1))
		echo "  [PASS] $1"
	else
		FAIL=$((FAIL + 1))
		echo "  [FAIL] $1"
		echo "    ---- 沙箱日志 ----"
		sed 's/^/    /' "$SBX/tmp/auto_upgrade.log"
	fi
}

# 每个用例前重置 uci 状态 / 日志 / 标记
reset_case() { # reset_case <enabled> <keep_config> <last_tag> <section> [buffy_version]
	: > "$SBX/etc/uci-state"
	{
		[ "$4" = "1" ] && echo "section=auto_upgrade"
		echo "enabled=$1"
		echo "keep_config=$2"
		[ -n "$3" ] && echo "last_tag=$3"
	} >> "$SBX/etc/uci-state"
	rm -f "$SBX/etc/buffy-version"
	[ -n "${5:-}" ] && printf '%s\n' "$5" > "$SBX/etc/buffy-version"
	: > "$SBX/tmp/auto_upgrade.log"
	rm -f "$SBX/tmp/.auto_upgrade_off_notified" "$SBX/etc/curl.log" "$SBX/etc/sysupgrade.log"
}

run_script() {
	if command -v timeout >/dev/null 2>&1; then
		timeout 60 sh "$SBX/auto_upgrade.sh" >/dev/null 2>&1
	else
		sh "$SBX/auto_upgrade.sh" >/dev/null 2>&1
	fi
	echo $?
}

echo "== 用例 1：正常升级路径（基线落后） =="
reset_case 1 1 "$TAG_OLD" 1
RC=$(run_script)
check "识别到新版本" "LOG_HAS '发现新固件：$TAG_OLD -> $TAG_NEW'"
check "进入下载步骤（沙箱内下载失败，退出码 1）" "[ \"$RC\" = \"1\" ]"
check "失败原因来自校验清单而非前置闸门" "LOG_HAS 'SHA256SUMS.txt 拉取失败'"
check "沙箱内未触发 sysupgrade" "! SUPG_CALLED"

echo "== 用例 2：基线自愈（last_tag 缺失 + 固件内有构建 tag） =="
reset_case 1 1 "" 1 "$TAG_OLD"
RC=$(run_script)
check "按固件内版本初始化基线" "LOG_HAS '基线缺失，已按固件内构建版本初始化：$TAG_OLD'"
check "写入 uci last_tag=运行版本" "[ \"\$(LAST_TAG)\" = \"$TAG_OLD\" ]"
check "据此判定需要升级（未误判为已是最新）" "LOG_HAS '发现新固件：$TAG_OLD -> $TAG_NEW'"
check "未走「记录最新版本为基线」的旧分支" "LOG_NOT '为基线（不刷机）'"

echo "== 用例 3：旧固件兜底（无 buffy-version） =="
reset_case 1 1 "" 1
RC=$(run_script)
check "记录最新版本为基线且不刷机" "LOG_HAS '固件无版本标识：记录当前最新版本 $TAG_NEW 为基线（不刷机）'"
check "退出码 0" "[ \"$RC\" = \"0\" ]"
check "未进入下载" "LOG_NOT '尝试下载'"

echo "== 用例 4：已是最新 =="
reset_case 1 1 "$TAG_NEW" 1 "$TAG_NEW"
RC=$(run_script)
check "判定已是最新并退出" "LOG_HAS '已是最新（$TAG_NEW），退出'"
check "未进入下载" "LOG_NOT '尝试下载'"

echo "== 用例 5：未启用（周一告警节流） =="
reset_case 0 1 "" 1 "$TAG_OLD"
MOCK_DOW=1
export MOCK_DOW
RC=$(run_script)
check "未启用时仍退出 0（行为不变）" "[ \"$RC\" = \"0\" ]"
check "日志记录未启用" "LOG_HAS '未启用（enabled≠1），退出'"
check "周一触发一次告警（curl 被调用）" "CURL_CALLED"
check "写入节流标记" "[ -f \"$SBX/tmp/.auto_upgrade_off_notified\" ]"
: > "$SBX/etc/curl.log"
run_script >/dev/null 2>&1
check "同日第二次不再告警（节流生效）" "! CURL_CALLED"
unset MOCK_DOW

echo "== 用例 6：配置段缺失（自动重建） =="
reset_case 0 1 "" 0 "$TAG_OLD"
RC=$(run_script)
check "检测到配置段缺失并重建" "LOG_HAS '配置段缺失，已按默认值重建'"
check "重建后继续执行并发现新固件" "LOG_HAS '发现新固件：$TAG_OLD -> $TAG_NEW'"

rm -rf "$SBX" 2>/dev/null || true

echo
echo "==== 结果：$PASS passed, $FAIL failed ===="
[ "$FAIL" = "0" ] || exit 1
exit 0
