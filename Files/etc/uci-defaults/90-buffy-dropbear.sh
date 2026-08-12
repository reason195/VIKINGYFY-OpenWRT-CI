#!/bin/sh
# 自定义项：移除 dropbear 的 lan 接口绑定，允许经 WAN(IPv6) 远程 SSH。
# 其余选项全部使用 dropbear 软件包默认值，随包更新自动继承。
exec 2>/dev/null
uci -q delete dropbear.@dropbear[0].Interface
uci -q delete dropbear.@dropbear[0].DirectInterface
uci commit dropbear
exit 0
