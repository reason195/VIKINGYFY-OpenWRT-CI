#!/bin/sh
# SPDX-License-Identifier: MIT
# 93-buffy-openclash.sh 的 DNS 重建回归测试：防止两参数 uci set 留下空段。
# 同时覆盖：@dns_servers 幂等重建、与 @authentication 迁移循环共存、内置覆写模块登记。
# 用法：sh Tests/test_openclash_dns_servers.sh（可通过 TARGET 指定负控副本）

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
TARGET="${TARGET:-$REPO_DIR/Files/etc/uci-defaults/93-buffy-openclash.sh}"

[ -f "$TARGET" ] || { echo "找不到 $TARGET"; exit 1; }

PASS=0
FAIL=0

SBX=$(mktemp -d /tmp/oc-dns-servers.XXXXXX 2>/dev/null || true)
[ -n "${SBX:-}" ] || SBX=$(mktemp -d)
case "$SBX" in
*\\*)
	echo "沙箱路径含反斜杠（$SBX），请设置 POSIX 风格的 TMPDIR 后重试"
	exit 1
	;;
esac

mkdir -p "$SBX/bin"
UCI_STATE="$SBX/uci.state"
: >"$UCI_STATE"
export UCI_STATE
SBX_SEQ="$SBX/seq"
: >"$SBX_SEQ"
export SBX_SEQ

# mock 仅实现本测试所需子集，匿名段以 cfgXXXXXX 存储并按声明顺序索引。
cat > "$SBX/bin/uci" <<'MOCK'
#!/bin/sh
st="${UCI_STATE:?UCI_STATE 未设置}"
[ "${1:-}" = "-q" ] && shift
cmd="${1:-}"
[ $# -gt 0 ] && shift
[ -f "$st" ] || : >"$st"

parse_key() {
	local IFS='[]'
	set -f
	set -- $1
	set +f
	PKG="${1%%.*}"
	TYPE="${1#*@}"
	IDX="${2:-}"
	OPT="${3:-}"
}

get_val() { # $1=完整 key（openclash.cfgXXX.opt 形式）
	awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); f = 1; exit }
		END { exit(f ? 0 : 1) }' "$st"
}

sec_name() { # $1=段类型 $2=下标 → 打印内部段名；越界 rc=1（负下标 = 倒数第 n 段）
	awk -F= -v t="$1" -v i="$2" '
		$1 ~ /^openclash\.cfg/ && index(substr($1, 11), ".") == 0 && $2 == t {
			names[n++] = substr($1, 11)
		}
		END {
			idx = i + 0
			if (idx < 0) idx = n + idx
			if (idx >= 0 && idx < n) { print names[idx]; exit 0 }
			exit 1
		}' "$st"
}

drop_prefix() { # $1=key 前缀 → 删除所有以该前缀开头的行；无命中 rc=1
	n0=$(wc -l <"$st")
	awk -v p="$1" 'index($0, p) != 1' "$st" >"$st.t" && mv "$st.t" "$st"
	[ "$(wc -l <"$st")" -lt "$n0" ]
}

case "$cmd" in
get)
	key="${1:-}"
	[ -n "$key" ] || exit 1
	parse_key "$key"
	if [ -n "$IDX" ] && [ -z "$OPT" ]; then
		sec_name "$TYPE" "$IDX" # 兼容 93 认证循环而返回内部 ID；实际 uci get 匿名整段返回 type。
	elif [ -n "$IDX" ]; then
		name=$(sec_name "$TYPE" "$IDX") || exit 1
		get_val "${PKG}.${name}${OPT}"
	else
		get_val "$key"
	fi
	;;
set)
	# set 仅接受单参数 key=value，值保持原样。
	[ $# -eq 1 ] || { echo "Error: Invalid command line argument: $2" >&2; exit 255; }
	arg="$1"
	case "$arg" in *=*) ;; *) echo "Error: unterminated string" >&2; exit 255 ;; esac
	k="${arg%%=*}"; v="${arg#*=}"
	parse_key "$k"
	if [ -n "$IDX" ]; then
		name=$(sec_name "$TYPE" "$IDX") || exit 1
		k="${PKG}.${name}${OPT}"
	fi
	drop_prefix "$k=" || true
	printf '%s=%s\n' "$k" "$v" >>"$st"
	;;
add)
	[ "${1:-}" = "openclash" ] && [ -n "${2:-}" ] || exit 1
	_n=$(tr -dc 0-9 <"$SBX_SEQ")
	_n=${_n:-0}
	printf '%s\n' "$((_n + 1))" >"$SBX_SEQ"
	name=$(printf 'cfg%06x' "$_n")
	printf 'openclash.%s=%s\n' "$name" "$2" >>"$st"
	printf '%s\n' "$name"
	;;
delete)
	key="${1:-}"
	[ -n "$key" ] || exit 1
	parse_key "$key"
	if [ -n "$IDX" ] && [ -z "$OPT" ]; then
		name=$(sec_name "$TYPE" "$IDX") || exit 1
		drop_prefix "openclash.$name"      # 声明行 + 该段全部选项行
	elif [ -n "$IDX" ]; then
		name=$(sec_name "$TYPE" "$IDX") || exit 1
		drop_prefix "${PKG}.${name}${OPT}="
	else
		drop_prefix "$key="
	fi
	;;
commit) exit 0 ;;
show)
	# 仅实现 uci show <pkg>：键=值，值统一加单引号（与真实 uci 一致）。
	awk -F= '{ v = substr($0, index($0, "=") + 1); print $1 "=\047" v "\047" }' "$st"
	;;
*) echo "Error: unrecognized command 'uci $cmd'" >&2; exit 1 ;;
esac
exit $?
MOCK
chmod +x "$SBX/bin/uci"
PATH="$SBX/bin:$PATH"
export PATH

ok() { PASS=$((PASS + 1)); echo "  PASS $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check_eq() { # $1=描述 $2=期望 $3=实得
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$2] 实得 [$3]）"; fi
}
run93() { sh "$TARGET"; }

g() { uci -q get "openclash.@dns_servers[$1].$2"; }
dns_secs() {
	awk -F= '$1 ~ /^openclash\.cfg/ && index(substr($1, 11), ".") == 0 && $2 == "dns_servers" { n++ }
		END { print n + 0 }' "$UCI_STATE"
}
dns_opts() { # 第 $1 个 dns_servers 段的 option 行数
	awk -F= -v i="$1" '
		$1 ~ /^openclash\.cfg/ && index(substr($1, 11), ".") == 0 && $2 == "dns_servers" { if (n++ == i + 0) name = substr($1, 11) }
		name != "" && index($1, "openclash." name ".") == 1 { c++ }
		END { print c + 0 }' "$UCI_STATE"
}
reset_sbx() {
	: >"$UCI_STATE"
	: >"$SBX_SEQ"
}
seed_dns() { # $1=内部段名 $2=type $3=ip $4=group $5=enabled（enabled 传空 → 造空段）
	printf 'openclash.%s=dns_servers\n' "$1" >>"$UCI_STATE"
	[ -n "$5" ] || return 0
	printf 'openclash.%s.enabled=%s\nopenclash.%s.type=%s\nopenclash.%s.ip=%s\nopenclash.%s.group=%s\n' \
		"$1" "$5" "$1" "$2" "$1" "$3" "$1" "$4" >>"$UCI_STATE"
}
snap_dns() {
	for _s in 0 1 2 3; do
		echo "$(g "$_s" type)|$(g "$_s" ip)|$(g "$_s" group)|$(g "$_s" enabled)"
	done
}

# ---- 用例 0：mock 自检 ----
echo "[0] mock 自检：set 语法、值保留及 add/delete 子集"
reset_sbx
uci set openclash.config.probe_k probe_v 2>/dev/null
check_eq "两参数 set 的退出码" "255" "$?"
check_eq "两参数 set 未写入任何行" "0" "$(grep -c probe_k "$UCI_STATE" 2>/dev/null)"
uci set openclash.config.probe_k=probe_v
check_eq "单参数 set 生效" "probe_v" "$(uci -q get openclash.config.probe_k)"
uci set "openclash.config.probe_q='quoted'"
check_eq "单参数 set 保留字面单引号" "'quoted'" "$(uci -q get openclash.config.probe_q)"
uci set 'openclash.config.probe_q="quoted"'
check_eq "单参数 set 保留字面双引号" '"quoted"' "$(uci -q get openclash.config.probe_q)"
uci add openclash dns_servers >/dev/null
check_eq "add 对后续 uci 进程立即可见（staged delta）" "1" "$(dns_secs)"
uci -q delete openclash.config.no_such_option 2>/dev/null
check_eq "delete 不存在的项返回非 0（删除循环的退出条件）" "1" "$?"
reset_sbx
seed_dns cfg0f0001 udp 1.1.1.1 default 1
check_eq "索引键解析到内部段名" "1.1.1.1" "$(g 0 ip)"

# ---- 用例 1：全新状态重建 ----
echo "[1] 全新状态：恰好 4 段、每段 4 个 option 齐全"
reset_sbx
run93
check_eq "退出码 0" "0" "$?"
check_eq "dns_servers 段数" "4" "$(dns_secs)"
_i=0
while [ "$_i" -lt 4 ]; do
	check_eq "[$_i] option 行数（空段即当年故障形状）" "4" "$(dns_opts "$_i")"
	_i=$((_i + 1))
done
unset _i

# ---- 用例 2：取值 ----
echo "[2] 取值与源码一致（default=国内 bootstrap，nameserver=境外 DoH）"
check_eq "[0].enabled" "1" "$(g 0 enabled)"
check_eq "[0].type" "udp" "$(g 0 type)"
check_eq "[0].ip" "119.29.29.29" "$(g 0 ip)"
check_eq "[0].group" "default" "$(g 0 group)"
check_eq "[1].enabled" "1" "$(g 1 enabled)"
check_eq "[1].type" "udp" "$(g 1 type)"
check_eq "[1].ip" "223.5.5.5" "$(g 1 ip)"
check_eq "[1].group" "default" "$(g 1 group)"
check_eq "[2].enabled" "1" "$(g 2 enabled)"
check_eq "[2].type" "https" "$(g 2 type)"
check_eq "[2].ip" "dns.cloudflare.com/dns-query" "$(g 2 ip)"
check_eq "[2].group" "nameserver" "$(g 2 group)"
check_eq "[3].enabled" "1" "$(g 3 enabled)"
check_eq "[3].type" "https" "$(g 3 type)"
check_eq "[3].ip" "dns.google/dns-query" "$(g 3 ip)"
check_eq "[3].group" "nameserver" "$(g 3 group)"

# ---- 用例 3：字面引号 ----
echo "[3] 取值里不得残留字面引号"
check_eq "dns 段取值带单引号的行数" "0" \
	"$(awk -F= -v q="'" '$1 ~ /^openclash\.cfg[0-9a-f]+\.(ip|type|group|enabled)$/ && index($2, q) > 0 { n++ } END { print n + 0 }' "$UCI_STATE")"

# ---- 用例 4：旧镜像残留 ----
echo "[4] 残留 5 段（空段 + 引号污染 + 用户手工段）全清后重建"
reset_sbx
seed_dns cfg0f0001 udp 119.29.29.29 default 1
seed_dns cfg0f0002 https "'dns.alidns.com/dns-query'" nameserver 1
seed_dns cfg0f0003 https https://dns.google/dns-query nameserver 1
seed_dns cfg0f0004 '' '' '' ''
seed_dns cfg0f0005 udp 8.8.8.8 default 1
check_eq "前置条件：5 段" "5" "$(dns_secs)"
run93
check_eq "退出码 0" "0" "$?"
check_eq "重建后段数（不漏删、不累加）" "4" "$(dns_secs)"
check_eq "末段是重建后的 dns.google" "dns.google/dns-query" "$(g 3 ip)"
check_eq "第 5 段不存在" "" "$(g 4 ip)"
if grep -q "8.8.8.8" "$UCI_STATE"; then bad "用户手工段未被清除"; else ok "用户手工段按设计一并清除（dns_servers 由 uci-defaults 全权重建）"; fi
if grep -q "alidns" "$UCI_STATE"; then bad "国内 DoH / 引号污染值未清除"; else ok "国内 DoH 与引号污染值已清除"; fi

# ---- 用例 5：幂等 ----
echo "[5] 幂等：连跑两次仍是同样 4 段"
reset_sbx
run93
FIRST_LINES=$(wc -l <"$UCI_STATE")
SNAP=$(snap_dns)
run93
check_eq "退出码 0" "0" "$?"
check_eq "状态文件行数不变" "$FIRST_LINES" "$(wc -l <"$UCI_STATE")"
check_eq "段数不变" "4" "$(dns_secs)"
check_eq "四段取值不变" "$SNAP" "$(snap_dns)"
unset FIRST_LINES SNAP

# ---- 用例 6：与 authentication 迁移循环共存 ----
echo "[6] 与 @authentication 迁移共存（两个循环都复用 _i）"
reset_sbx
printf 'openclash.config.dashboard_password=0123456789abcdef01234567\n' >>"$UCI_STATE"
printf 'openclash.cfg0e0001=authentication\nopenclash.cfg0e0001.enabled=1\nopenclash.cfg0e0001.username=clash\nopenclash.cfg0e0001.password=fedcba9876543210fedcba98\n' >>"$UCI_STATE"
printf 'openclash.cfg0e0002=authentication\nopenclash.cfg0e0002.enabled=1\nopenclash.cfg0e0002.username=Clash\nopenclash.cfg0e0002.password=Zx9Qw2Er\n' >>"$UCI_STATE"
seed_dns cfg0f0011 udp 1.1.1.1 default 1
run93
check_eq "退出码 0" "0" "$?"
check_eq "dns_servers 仍是 4 段" "4" "$(dns_secs)"
check_eq "首段已是重建值" "119.29.29.29" "$(g 0 ip)"
check_eq "旧版认证段已删、上游段前移" "Clash" "$(uci -q get 'openclash.@authentication[0].username')"
check_eq "认证段总数为 1" "1" "$(awk -F= '$2 == "authentication" { n++ } END { print n + 0 }' "$UCI_STATE")"
if grep -q "1.1.1.1" "$UCI_STATE"; then bad "dns 旧段清理干净（未通过）"; else ok "dns 旧段清理干净"; fi

# ---- 用例 7：后续选项照常落地 ----
echo "[7] dns 段之后的选项未受中断"
reset_sbx
run93
check_eq "enable_custom_dns" "1" "$(uci -q get openclash.config.enable_custom_dns)"
check_eq "custom_name_policy" "1" "$(uci -q get openclash.config.custom_name_policy)"
# 主路由仍用「第二DNS服务器」给 DDNS 域名返回真实 IP
check_eq "enable_custom_domain_dns_server" "1" "$(uci -q get openclash.config.enable_custom_domain_dns_server)"
check_eq "custom_domain_dns_server" "223.5.5.5" "$(uci -q get openclash.config.custom_domain_dns_server)"
# DNS 泄漏收口：WAN/默认 DNS 不得被追加进 clash，fake-ip 映射要持久化
check_eq "append_wan_dns" "0" "$(uci -q get openclash.config.append_wan_dns)"
check_eq "append_default_dns" "0" "$(uci -q get openclash.config.append_default_dns)"
check_eq "store_fakeip" "1" "$(uci -q get openclash.config.store_fakeip)"
check_eq "dnsmasq_noresolv" "1" "$(uci -q get openclash.config.dnsmasq_noresolv)"
check_eq "enable_redirect_dns" "1" "$(uci -q get openclash.config.enable_redirect_dns)"
check_eq "enable_meta_sniffer" "1" "$(uci -q get openclash.config.enable_meta_sniffer)"
check_eq "en_mode" "fake-ip" "$(uci -q get openclash.config.en_mode)"
check_eq "geo_update_day_time" "0" "$(uci -q get openclash.config.geo_update_day_time)"
check_eq "chnr6_custom_url" "https://ispip.clang.cn/all_cn_ipv6.txt" "$(uci -q get openclash.config.chnr6_custom_url)"

# ---- 用例 8：内置覆写模块登记（幂等） ----
# 93 只在 /etc/openclash/overwrite/<模块> 存在时登记；把该路径重定向到沙箱，
# 才能在构建机/开发机上验证 uci add + 负下标 + order 递增那一段。
echo "[8] 内置覆写模块登记（路径重定向到沙箱）"
mkdir -p "$SBX/overwrite"
printf '#!NAME = OC_SelfHeal_AntiLeak\n#!DESC = test\n#!CONFIG = all\n' > "$SBX/overwrite/OC_SelfHeal_AntiLeak"
sed "s#/etc/openclash/overwrite#$SBX/overwrite#g" "$TARGET" > "$SBX/93-module.sh"
reset_sbx
sh "$SBX/93-module.sh"
check_eq "退出码 0" "0" "$?"
check_eq "模块已登记" "OC_SelfHeal_AntiLeak" "$(uci -q get 'openclash.@config_overwrite[0].name')"
check_eq "模块类型 file" "file" "$(uci -q get 'openclash.@config_overwrite[0].type')"
check_eq "模块已启用" "1" "$(uci -q get 'openclash.@config_overwrite[0].enable')"
check_eq "模块 order" "1" "$(uci -q get 'openclash.@config_overwrite[0].order')"
MODULE_LINES=$(wc -l <"$UCI_STATE")
sh "$SBX/93-module.sh"
check_eq "重复执行退出码 0" "0" "$?"
check_eq "重复执行不重复登记" "$MODULE_LINES" "$(wc -l <"$UCI_STATE")"
check_eq "config_overwrite 段数" "1" "$(awk -F= '$2 == "config_overwrite" { n++ } END { print n + 0 }' "$UCI_STATE")"
unset MODULE_LINES

rm -rf "$SBX"

echo
echo "==== $PASS passed / $FAIL failed ===="
[ "$FAIL" -eq 0 ] || exit 1
exit 0