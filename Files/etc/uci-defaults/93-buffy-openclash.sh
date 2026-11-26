#!/bin/sh
# 自定义 OpenClash 选项（其余全部使用 luci-app-openclash 包默认值，随包更新自动继承）。
# 注意：enable / config_path 不在此设置 —— rc.local 在检测到
# /etc/openclash/config/MihomoPro.yaml 存在时才启用，避免空配置空转。
exec 2>/dev/null
uci -q delete openclash.config.en_mode
uci set openclash.config.en_mode='fake-ip'
uci -q delete openclash.config.operation_mode
uci set openclash.config.operation_mode='fake-ip'
uci -q delete openclash.config.redirect_dns
uci set openclash.config.redirect_dns='1'
uci -q delete openclash.config.enable_respect_rules
uci set openclash.config.enable_respect_rules='1'
uci -q delete openclash.config.log_level
uci set openclash.config.log_level='error'
uci -q delete openclash.config.china_ip_route
uci set openclash.config.china_ip_route='1'
uci -q delete openclash.config.core_type
uci set openclash.config.core_type='Meta'
uci -q delete openclash.config.core_version
uci set openclash.config.core_version='linux-arm64'
uci -q delete openclash.config.github_address_mod
uci set openclash.config.github_address_mod='https://testingcf.jsdelivr.net/'
uci -q delete openclash.config.enable_geoip_dat
uci set openclash.config.enable_geoip_dat='1'
# 第二DNS服务器（dnsmasq 侧）：指定域名不走 clash fake-ip，直接经 223.5.5.5 解析真实 IP
# 域名列表见 /etc/openclash/custom/openclash_custom_domain_dns.list
uci -q delete openclash.config.enable_custom_domain_dns_server
uci set openclash.config.enable_custom_domain_dns_server='1'
uci -q delete openclash.config.custom_domain_dns_server
uci set openclash.config.custom_domain_dns_server='223.5.5.5'
# 关键修复：订阅源/规则源/DDNS 等"路由器自身需直连"的域名必须返回真实 IP。
# 根因：provider 拉取用 proxy: DIRECT，但域名经 respect-rules + fake-ip DNS
# 解析成 198.18.x.x，DIRECT 直连 fake-ip 必然 EOF（alpha 核心行为）。
# 解法：custom_fakeip_filter 把这些域名加入 fake-ip-filter（解析真实 IP）。
# 域名列表见 /etc/openclash/custom/openclash_custom_fake_filter.list
# 配套：同一批域名还要在 openclash_custom_domain_dns_policy.list 里指向国内 DoH 直连，
# 否则仍会走 nameserver（境外 DoH，respect-rules 下经代理）解析——代理未启动时同样
# 解析不了，首启拉订阅死锁。两个列表都由构建期 Scripts/openclash_sub_domains.py
# 从 MihomoPro.yaml 的 proxy-providers 自动补齐。
uci -q delete openclash.config.custom_fakeip_filter
uci set openclash.config.custom_fakeip_filter='1'
uci -q delete openclash.config.skip_proxy_address
uci set openclash.config.skip_proxy_address='1'
# DNS 防泄漏：订阅自带的 DNS 段通常是国内 DoH（alidns/doh.pub），且 enable_custom_dns=0
# 时插件不覆写 → 国外域名由国内解析器解析，权威侧看到的是国内 ISP 解析器（DNS 泄漏），
# 而流量却从境外节点出去。
# 方案：enable_custom_dns=1 由 @dns_servers 生成 nameserver（境外 DoH，respect-rules=1
# 下 DoH 连接经代理出口）；custom_name_policy=1 合并 openclash_custom_domain_dns_policy.list，
# 让国内/私有/苹果域名仍走国内 DoH 直连（保 CDN 就近解析）。
uci -q delete openclash.config.enable_custom_dns
uci set openclash.config.enable_custom_dns='1'
uci -q delete openclash.config.custom_name_policy
uci set openclash.config.custom_name_policy='1'
# 重建 @dns_servers：default=国内 bootstrap（用于解析 DoH 主机名）；nameserver=境外 DoH
# 有界循环：删一段后其余段前移，故始终删 [0]；上限防 uci 异常时空转
_i=0
while [ "$_i" -lt 64 ] && uci -q delete "openclash.@dns_servers[0]"; do
	_i=$((_i + 1))
done
unset _i
_buffy_add_dns() {
	_s="$(uci add openclash dns_servers)" || return 0
	# uci set 只接受单参数 key=value；两参数形式返回 255，会留下空 DNS 段。
	uci set "openclash.$_s.enabled=1"
	uci set "openclash.$_s.type=$1"
	uci set "openclash.$_s.ip=$2"
	uci set "openclash.$_s.group=$3"
}
_buffy_add_dns udp 119.29.29.29 default
_buffy_add_dns udp 223.5.5.5 default
_buffy_add_dns https dns.cloudflare.com/dns-query nameserver
_buffy_add_dns https dns.google/dns-query nameserver
unset -f _buffy_add_dns
unset _s
uci -q delete openclash.config.enable_meta_sniffer
uci set openclash.config.enable_meta_sniffer='1'
uci -q delete openclash.config.enable_meta_sniffer_pure_ip
uci set openclash.config.enable_meta_sniffer_pure_ip='1'
uci -q delete openclash.config.geo_auto_update
uci set openclash.config.geo_auto_update='1'
uci -q delete openclash.config.geoip_auto_update
uci set openclash.config.geoip_auto_update='1'
uci -q delete openclash.config.geosite_auto_update
uci set openclash.config.geosite_auto_update='1'
uci -q delete openclash.config.geoasn_auto_update
uci set openclash.config.geoasn_auto_update='1'
uci -q delete openclash.config.chnr_auto_update
uci set openclash.config.chnr_auto_update='1'
# 定时更新时刻表（小时/星期几）：add_cron() 的模板 "0 $(day_time) * * $(week_time) cmd" 依赖这些选项，
# 缺失时 uci_get_config 返回空且退出码 0，"|| 兜底"失效 → 生成 "0  * *  cmd" 畸形 4 字段行，
# busybox crond 整行拒绝 → GEO/大陆白名单周更静默失效（且开机 stop_service 会先删掉烤入的
# 正确行再生成畸形版）。时刻表与 Files/etc/crontabs/root 烤入版保持一致（周一凌晨错峰）。
for _opt in geo:0 geosite:2 geoip:1 geoasn:3 chnr:4; do
	_name="${_opt%%:*}"; _hour="${_opt##*:}"
	uci -q delete openclash.config.${_name}_update_day_time
	uci set openclash.config.${_name}_update_day_time="$_hour"
	uci -q delete openclash.config.${_name}_update_week_time
	uci set openclash.config.${_name}_update_week_time='1'
done
uci -q delete openclash.config.chnr_custom_url
uci set openclash.config.chnr_custom_url='https://ispip.clang.cn/all_cn.txt'
uci -q delete openclash.config.chnr6_custom_url
uci set openclash.config.chnr6_custom_url='https://ispip.clang.cn/all_cn_ipv6.txt'
uci -q delete openclash.config.disable_quic_go_gso
uci set openclash.config.disable_quic_go_gso='1'
uci -q delete openclash.config.default_dashboard
uci set openclash.config.default_dashboard='zashboard'

# 迁移旧版曾生成的 24 位十六进制 Dashboard 密钥：清空后由后续执行的
# luci-app-openclash 自带 uci-defaults 生成默认 8 位随机字母数字密钥。
# 仅匹配旧版格式，保留用户手动设置的其他长度/格式。
DASH_PW="$(uci -q get openclash.config.dashboard_password)"
case "$DASH_PW" in
	*[!0-9a-fA-F]*|'') ;;
	*) [ "${#DASH_PW}" -eq 24 ] && uci -q delete openclash.config.dashboard_password ;;
esac

# 迁移旧版仓库自造的 SOCKS5/HTTP(S) 认证段（openclash.@authentication）。
# 旧版生成 username='clash'（小写）+ 24 位十六进制口令；上游 luci-openclash 只在
# 「该段完全不存在」时生成默认值（username='Clash' + 8 位随机字母数字），旧段只要存在
# 就永远占位、认证信息无法回到上游生成。两个特征同时命中才删（改过名或口令的一律视为
# 用户自定义并保留），删除后由排在本文件之后的 luci-openclash 重新生成。
_i=0
while _sec="$(uci -q get "openclash.@authentication[$_i]")" && [ -n "$_sec" ]; do
	_u="$(uci -q get "openclash.@authentication[$_i].username")"
	_p="$(uci -q get "openclash.@authentication[$_i].password")"
	if [ "$_u" = "clash" ]; then
		case "$_p" in
			*[!0-9a-fA-F]*|'') ;;
			*) [ "${#_p}" -eq 24 ] && uci -q delete "openclash.@authentication[$_i]" ;;
		esac
	fi
	# 删除后后续段前移填补当前下标，故仅在本下标未被腾空时递增
	[ "$(uci -q get "openclash.@authentication[$_i]")" = "$_sec" ] && _i=$((_i + 1))
done
unset _i _sec _u _p

# Dashboard 密钥与 SOCKS5/HTTP(S) 认证（@authentication）均由 luci-app-openclash 自带的
# /etc/uci-defaults/luci-openclash 首启生成。本文件在其之前执行，上面两段迁移清除旧版
# 自造值后，上游才会按「为空/无段」判断补上默认 8 位随机值。
# 查询：LuCI → OpenClash → 覆写设置；或 uci show openclash | grep -E 'dashboard_password|authentication'
# 快照：/etc/init.d/buffy-credentials 每次开机调 /usr/share/buffy/export_credentials.sh 同步到
#      /etc/openclash-credentials.txt，便于命令行查看当前生效值。

# ── DNS 上游收口 / fake-ip 持久化 ──────────────────────────────────
# append_wan_dns / append_default_dns 会把 WAN 下发的运营商 DNS 追加进 clash 的
# nameserver 作为兜底：clash 的 DoH 不可用时会转而问运营商 DNS，等于把 DNS 泄漏出去。
# 与 /etc/rc.local 删掉 dnsmasq 直连兜底是同一件事的两侧，必须同时关。
# enable_redirect_dns=1：让插件把 dnsmasq 的上游重定向到 7874（再保险一层）；
# store_fakeip=1：重启后保留 fake-ip 映射，客户端缓存的 198.18.x.x 仍能命中路由；
# dnsmasq_noresolv=1：dnsmasq 不再读 /etc/resolv.conf.auto（PPPoE 下发的 DNS）。
for _kv in append_wan_dns append_default_dns enable_redirect_dns store_fakeip dnsmasq_noresolv; do
	uci -q delete "openclash.config.$_kv"
done
uci set openclash.config.append_wan_dns='0'
uci set openclash.config.append_default_dns='0'
uci set openclash.config.enable_redirect_dns='1'
uci set openclash.config.store_fakeip='1'
uci set openclash.config.dnsmasq_noresolv='1'
unset _kv

# ── 登记内置覆写模块（幂等）────────────────────────────────────────
# 模块文件随镜像发布在 /etc/openclash/overwrite/OC_SelfHeal_AntiLeak；
# sysupgrade -n 会清空 /etc/config，但镜像文件仍在，因此每次首启都在这里重新登记。
# enable=1：刷完即生效，无需到 LuCI 手动开启。
MODULE_NAME='OC_SelfHeal_AntiLeak'
MODULE_FILE="/etc/openclash/overwrite/$MODULE_NAME"
if [ -s "$MODULE_FILE" ] && ! uci -q show openclash | grep -q "\.name='$MODULE_NAME'"; then
	_max_order="$(uci -q show openclash | sed -n "s/^openclash\.[^.=]*\.order='\([0-9]*\)'$/\1/p" | sort -n | tail -1)"
	uci add openclash config_overwrite >/dev/null
	uci set "openclash.@config_overwrite[-1].name=$MODULE_NAME"
	uci set "openclash.@config_overwrite[-1].type=file"
	uci add_list "openclash.@config_overwrite[-1].config=all"
	uci set "openclash.@config_overwrite[-1].enable=1"
	uci set "openclash.@config_overwrite[-1].order=$(( ${_max_order:-0} + 1 ))"
	unset _max_order
fi
unset MODULE_NAME MODULE_FILE

uci commit openclash
exit 0
