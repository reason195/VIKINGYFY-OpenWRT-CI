#!/bin/sh
# 自定义项：LuCI 监听。80(HTTP) 使用 uhttpd 软件包默认值，局域网直接 http://192.168.1.1 访问，
# 不做 HTTP→HTTPS 强制跳转（IP 直访必然证书告警 ERR_CERT_AUTHORITY_INVALID）；
# 443(HTTPS) 保留，首启用自签证书，90 秒后由 /usr/share/buffy/cert_check.sh 替换为
# Let's Encrypt 证书——经 DDNS 域名（reason195.duckdns.org）访问时可免告警。
# 其余选项全部使用 uhttpd 软件包默认值。
exec 2>/dev/null
uci -q delete uhttpd.main.redirect_https
uci -q delete uhttpd.main.listen_https
uci add_list uhttpd.main.listen_https='0.0.0.0:443'
uci add_list uhttpd.main.listen_https='[::]:443'
uci commit uhttpd
exit 0
