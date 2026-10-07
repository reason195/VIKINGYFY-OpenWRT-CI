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
uci -q delete openclash.config.custom_fakeip_filter
uci set openclash.config.custom_fakeip_filter='1'
uci -q delete openclash.config.skip_proxy_address
uci set openclash.config.skip_proxy_address='1'
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
# 仅匹配旧版格式，保留用户手动设置的其他长度/格式；API 认证仍完全交给上游管理。
DASH_PW="$(uci -q get openclash.config.dashboard_password)"
case "$DASH_PW" in
	*[!0-9a-fA-F]*|'') ;;
	*) [ "${#DASH_PW}" -eq 24 ] && uci -q delete openclash.config.dashboard_password ;;
esac

# 其余 Dashboard/API 凭据由 luci-app-openclash 自带的 /etc/uci-defaults/luci-openclash
# 首启生成。此文件在其之前执行，因此这里清除旧版密钥后，上游会按默认逻辑补上 8 位值。
# 查询：LuCI → OpenClash → 覆写设置；或 uci show openclash | grep -E 'dashboard_password|authentication'
# 快照：/etc/rc.local 每次开机调 /usr/share/buffy/export_credentials.sh 同步到
#      /etc/openclash-credentials.txt，便于命令行查看当前生效值。
uci commit openclash
exit 0
