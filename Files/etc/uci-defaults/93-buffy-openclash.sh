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
uci -q delete openclash.config.custom_fakeip_filter
uci set openclash.config.custom_fakeip_filter='1'
uci -q delete openclash.config.custom_name_policy
uci set openclash.config.custom_name_policy='1'
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
uci -q delete openclash.config.chnr_custom_url
uci set openclash.config.chnr_custom_url='https://ispip.clang.cn/all_cn.txt'
uci -q delete openclash.config.chnr6_custom_url
uci set openclash.config.chnr6_custom_url='https://ispip.clang.cn/all_cn_ipv6.txt'
uci -q delete openclash.config.disable_quic_go_gso
uci set openclash.config.disable_quic_go_gso='1'
uci -q delete openclash.config.default_dashboard
uci set openclash.config.default_dashboard='zashboard'
uci -q delete openclash.config.dashboard_password
uci set openclash.config.dashboard_password='TauBuwn7'
# clash API / dashboard 认证（沿用现有凭据）
uci add openclash authentication >/dev/null
uci set openclash.@authentication[-1].enabled='1'
uci set openclash.@authentication[-1].username='Clash'
uci set openclash.@authentication[-1].password='suH9w0lB'
uci commit openclash
exit 0
