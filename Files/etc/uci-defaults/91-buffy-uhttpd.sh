#!/bin/sh
# 自定义项：LuCI 强制 HTTPS。首启用 uhttpd 自签证书（config cert 默认段），
# 90 秒后由 /usr/share/buffy/cert_check.sh 后台替换为 Let's Encrypt 证书。
# 其余选项全部使用 uhttpd 软件包默认值。
exec 2>/dev/null
uci -q delete uhttpd.main.redirect_https
uci set uhttpd.main.redirect_https='1'
uci -q delete uhttpd.main.listen_https
uci add_list uhttpd.main.listen_https='0.0.0.0:443'
uci add_list uhttpd.main.listen_https='[::]:443'
uci commit uhttpd
exit 0
