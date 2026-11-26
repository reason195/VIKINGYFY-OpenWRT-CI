#!/bin/sh
# Tailscale 面板方案（asvow/luci-app-tailscale）在本固件上的四处必要修补，首启执行一次。
# 只在面板 helper 存在时执行：helper 来自 luci-app-tailscale，缺包时直接跳过。

[ -x /usr/sbin/tailscale_helper ] || exit 0

# 1) exit-code bug：helper 最后一行是
#      [ -n "$(uci changes firewall)" ] && uci commit firewall && /etc/init.d/firewall reload
#    firewall 没有待提交改动时 [ -n "" ] 返回 1，脚本退出码=1，
#    procd 判定实例崩溃并无限重启，导致 tailscale up --reset 反复执行、状态抖动。
#    删掉文件末尾的 exit 0，统一在补丁段落末尾补一个。
sed -i '/^exit 0$/d' /usr/sbin/tailscale_helper

# 2) 本固件无 iptables，tailscaled 的 linuxfw 初始化失败，不会给 tailscale0
#    配 IPv4（节点显示在线但接口无地址，其他设备连不进来）。这里幂等补上。
#    SNAT 由 /etc/fw4-ts-snat.sh 负责。
if ! grep -q 'TS_IP4=' /usr/sbin/tailscale_helper 2>/dev/null; then
	cat >> /usr/sbin/tailscale_helper <<'EOF'

# --- 本固件修补：tailscaled 不自动配 tailscale0 IPv4，这里幂等补上 ---
TS_IP4=$(tailscale ip -4 2>/dev/null)
[ -n "$TS_IP4" ] && ip addr add "$TS_IP4/32" dev tailscale0 2>/dev/null
exit 0
EOF
else
	printf '%s\n' 'exit 0' >> /usr/sbin/tailscale_helper
fi

# 3) 注册 fw4 include，让子网路由 SNAT 规则在每次 firewall reload/restart 后自动重建。
chmod +x /etc/fw4-ts-snat.sh 2>/dev/null
if [ -z "$(uci -q get firewall.ts_snat)" ]; then
	uci set firewall.ts_snat=include
	uci set firewall.ts_snat.type='script'
	uci set firewall.ts_snat.path='/etc/fw4-ts-snat.sh'
	uci commit firewall
fi

# 4) 面板「Logs」页读不出内容：log.js 先 fs.stat('/sbin/logread') 探测路径，
#    但包自带的 ACL 只给了 `logread -e tailscale` 的 exec 权限，没有 stat/read，
#    探测返回 null → logger 为 null → 页面空白。补一条 read 权限。
ACL=/usr/share/rpcd/acl.d/luci-app-tailscale.json
if [ -f "$ACL" ] && ! grep -q '"/sbin/logread"' "$ACL"; then
	sed -i 's#^	*"/sbin/logread -e tailscale"#				"/sbin/logread": [ "read" ],\n&#' "$ACL"
	/etc/init.d/rpcd restart
fi

exit 0
