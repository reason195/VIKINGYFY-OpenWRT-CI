#!/bin/sh
# Tailscale 子网路由 SNAT（fw4 include 脚本，由 /etc/config/firewall 的 ts_snat 段调用，
# 段本身由 /etc/uci-defaults/96-tailscale-panel-fix.sh 幂等创建）
#
# 背景：tailscaled 本该自己配这条 SNAT，但它用 linuxfw 初始化 netfilter 时
# 需要 iptables 命令（本固件只有 nftables/fw4，无 iptables），初始化失败，
# 结果既不给 tailscale0 配 IPv4，也不建 SNAT。
#
# 缺这条规则时：Tailscale 客户端访问 192.168.1.x，包能进去，但 LAN 设备的
# 回包目的地是 100.64.0.0/10，屋里的主路由不认这个网段，回不来 —— 表现为
# "能 ping 通路由器、访问不了家里其他设备"。
#
# 规则语义：从 tailscale0 进来、从 br-lan 出去的流量，把源地址伪装成路由器的
# LAN 地址（192.168.1.1），LAN 设备回包到路由器后由 conntrack 还原。

nft list chain inet fw4 srcnat >/dev/null 2>&1 || exit 0
nft list chain inet fw4 srcnat 2>/dev/null | grep -q '100.64.0.0/10 masquerade' && exit 0
nft add rule inet fw4 srcnat oifname "br-lan" ip saddr 100.64.0.0/10 masquerade 2>/dev/null
exit 0
