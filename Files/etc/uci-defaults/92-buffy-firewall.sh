#!/bin/sh
# 自定义项：IPv6 WAN 放行 SSH(22) 与 LuCI(80/443)、硬件流卸载 + FullCone6、wan 区域 forward=DROP。
# 区域/默认规则及各软件包 include（qcanssecm/nikki/openclash/homeproxy）均由软件包自行管理，
# 不在此烘焙，随包更新自动继承。
exec 2>/dev/null
# --- defaults: 硬件流卸载 + fullcone6 ---
uci -q delete firewall.@defaults[0].flow_offloading_hw
uci set firewall.@defaults[0].flow_offloading_hw='1'
uci -q delete firewall.@defaults[0].fullcone6
uci set firewall.@defaults[0].fullcone6='1'
# --- wan 区域 forward 改 DROP（默认 REJECT） ---
i=0
while [ -n "$(uci -q get firewall.@zone[$i].name)" ]; do
    [ "$(uci -q get firewall.@zone[$i].name)" = "wan" ] && {
        uci set firewall.@zone[$i].forward='DROP'
        break
    }
    i=$((i + 1))
done
# --- 放行规则（匿名段 + name 选项，等价于 config rule / option name） ---
uci add firewall rule >/dev/null
uci set firewall.@rule[-1].name='Allow-WAN-SSH-v6'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].family='ipv6'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].dest_port='22'
uci set firewall.@rule[-1].target='ACCEPT'

uci add firewall rule >/dev/null
uci set firewall.@rule[-1].name='Allow-WAN-LuCI-v6'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].family='ipv6'
uci set firewall.@rule[-1].proto='tcp'
uci add_list firewall.@rule[-1].dest_port='80'
uci add_list firewall.@rule[-1].dest_port='443'
uci set firewall.@rule[-1].target='ACCEPT'

uci commit firewall
exit 0
