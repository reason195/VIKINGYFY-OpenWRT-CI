# 高质量<免费>交流群

点击链接加入群聊【IPQ技术讨论群】：https://qm.qq.com/q/v7nMhzB4oU
该群为普通交流群。

# 高质量<付费>中转站

点击链接加入群聊【LiBwrt-Ai学习】：https://qm.qq.com/q/HTa7OiWNCU
该群为AI中转站群。

# 本地编译器

https://github.com/VIKINGYFY/OWRT-Tools.git

# 自用修改版插件

https://github.com/VIKINGYFY/packages.git

# OpenWRT-CI

官方版：

https://github.com/immortalwrt/immortalwrt.git

自用版：

https://github.com/VIKINGYFY/immortalwrt.git

# U-BOOT

高通版-沉心：

https://github.com/chenxin527/uboot-qsdk12.5-build.git

高通版-小猪：

https://github.com/1980490718/u-boot-2016.git

联发科-全新版：

https://github.com/VIKINGYFY/UBOOT-CI/releases

联发科-官方版：

https://drive.wrt.moe/uboot/mediatek

# 固件简要说明

固件每天早上5点自动编译。

固件信息里的时间为编译开始的时间，方便核对上游源码提交时间。

MEDIATEK系列、QUALCOMMAX系列、ROCKCHIP系列、X86系列。

# 目录简要说明

workflows——自定义CI配置

Scripts——自定义脚本（构建期脚本与校验工具，不会编译进固件）

Config——自定义配置

Files——路由器根文件系统覆盖层（仅此目录的内容会被拷入固件 rootfs）

# 刷机校验脚本

`Scripts/verify_flash.py` 用于校验已刷入路由器的固件与本仓库 `Files/` 的一致性（含 secret 脱敏比对）：

- 逐字节比对 `Files/` 与路由器 `/rom`（只读出厂层）；含 `@@SECRET@@` 占位符的文件做脱敏比对；shadow/openssl 等构建期与包默认合并的文件按包含关系比对。
- 抽查 OpenClash 核心/规则集/DNS/防火墙等运行时状态，并提示 `/etc` 与 `/rom` 的运行时漂移。
- 依赖 paramiko，仅本地运行，**不会被编译进固件**。

```bash
pip install paramiko
python3 Scripts/verify_flash.py                              # 默认 192.168.1.1 root/root
python3 Scripts/verify_flash.py --host 10.0.0.1 --user admin --password xxxx
ROUTER_HOST=192.168.1.1 ROUTER_PASSWORD=root python3 Scripts/verify_flash.py
```

#
[![Stargazers over time](https://starchart.cc/VIKINGYFY/OpenWRT-CI.svg?variant=adaptive)](https://starchart.cc/VIKINGYFY/OpenWRT-CI)
