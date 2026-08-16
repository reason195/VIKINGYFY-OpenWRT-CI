# VIKINGYFY-OpenWRT-CI（京东云 jdcloud_re-cs-07 定制版）

基于 [VIKINGYFY/OpenWRT-CI](https://github.com/VIKINGYFY/OpenWRT-CI) 的 ImmortalWRT 固件自动构建项目，本仓库只维护单设备固件：

- 设备：京东云 jdcloud_re-cs-07（Qualcomm IPQ60xx 平台，无 WiFi）
- 目标：`qualcommax/ipq60xx`，aarch64
- 登录地址：`192.168.1.1`，root 密码由 GitHub Secret `ROUTER_ROOT_PASSWORD` 注入
- 构建：每 6 小时检查上游 [VIKINGYFY/immortalwrt](https://github.com/VIKINGYFY/immortalwrt)（main 分支），有更新才自动编译并发布 release；旧 release 自动清理只留 5 个

## 目录结构

| 目录 | 说明 |
|---|---|
| `.github/workflows/` | CI：QCA-ALL（触发）、WRT-CORE（编译核心）、Auto-Clean（清理 release） |
| `Scripts/` | 构建脚本与工具（Packages.sh / Handles.sh / Settings.sh / verify_flash.py），仅在 CI 构建机运行，**不会编译进固件** |
| `Config/` | 编译配置：GENERAL.txt（通用包）+ IPQ60XX-WIFI-NO.txt（设备） |
| `Files/` | 路由器根文件系统覆盖层，**仅此目录内容会拷入固件 rootfs** |

## 构建与 Secrets 注入

构建时 `Scripts/Settings.sh` 把 `Files/` 拷入 rootfs，并用 GitHub Secrets 替换 `@@XXX@@` 占位符：

| Secret | 注入位置 |
|---|---|
| `PPPOE_USERNAME` / `PPPOE_PASSWORD` | `/etc/config/network`（PPPoE 拨号） |
| `DDNS_TOKEN` | `/etc/config/ddns` + `/etc/config/acme`（DuckDNS） |
| `HP_ADDRESS` / `HP_UUID` | `/etc/config/homeproxy` |
| `MAIN_AIRPORT_SUB` / `BACKUP_AIRPORT_SUB` | `/etc/openclash/config/MihomoPro.yaml`（机场订阅） |
| `ROUTER_ROOT_PASSWORD` | `/etc/shadow`（SHA-256 crypt 哈希） |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | `/etc/buffy-notify.conf`（告警，可选） |
| `SINGBOX_SS_PASSWORD` | `/etc/sing-box/config.json`（Shadowsocks 入站，可选） |

必需 secret 缺失会终止构建；可选 secret 缺失只置空占位符、不阻断构建。

## 固件内置功能

- **OpenClash**：核心 / 规则集 / GEO / 大陆白名单 / 面板均在构建期预置，刷机首启即用（首启规则集空缓存死锁已修复）；控制台/API 凭据首启随机生成
- **DNS**：dnsmasq 备用上游（223.5.5.5 / 119.29.29.29 / 2400:3200::1）+ fake-ip 分流
- **DDNS + HTTPS**：DuckDNS DDNS、Let's Encrypt 证书（DNS-01）自动签发/续期、LuCI 强制 HTTPS
- **防火墙**：IPv6 WAN 放行 SSH/LuCI、wan 区域 forward=DROP、硬件流量卸载
- **监控告警**：ntfy + Telegram 双通道（见下方脚本）

### 监控脚本（`Files/usr/share/buffy/`）

| 脚本 | 作用 |
|---|---|
| `lib-buffy.sh` | 公共函数库（log/notify/resolve/证书检查/代理探测） |
| `boot_selfcheck.sh` | 开机自检：确认 OpenClash 核心 + 代理 204 就绪 |
| `health_check.sh` | 每日体检：WAN/DNS/证书/备用上游/防火墙/流量卸载 |
| `proxy_watch.sh` | 每小时代理 204 探测，失败告警（运行中守护） |
| `cert_check.sh` | 每日证书签发/续期，失败告警 |
| `first_boot_download.sh` | 首启引导：更新 GEO/白名单/面板，幂等仅执行一次 |

## 一键升级

`Scripts/upgrade_firmware.py` 从 GitHub latest release 下载本设备的 sysupgrade 固件、校验 sha256 并刷入：

```bash
pip install paramiko
python3 Scripts/upgrade_firmware.py                          # 默认 192.168.1.1 root/root，保留配置升级
python3 Scripts/upgrade_firmware.py --dry-run                # 只下载+校验，不刷机
python3 Scripts/upgrade_firmware.py --reset --yes            # 重置配置(sysupgrade -n)并跳过确认
python3 Scripts/upgrade_firmware.py --no-verify              # 刷机后不等待重启、不自动复验
```

- sha256 以 GitHub 资产 `digest` 为准，本地 + 路由器侧双重校验，不一致即中止
- 刷机前校验路由器 `board_name` 与固件设备段一致，防止刷错设备
- 刷机后自动等待重启（按 uptime 判断确已重启）、等 OpenClash 开机自检完成后再运行 `verify_flash.py` 复验；`--no-verify` 跳过
- 建议已安装并登录 `gh`（避免 GitHub 匿名 API 限流）

## 刷机校验

刷机后可用 `Scripts/verify_flash.py` 校验路由器与本仓库 `Files/` 的一致性（含 secret 脱敏比对与 uci-defaults 运行时效果）：

```bash
pip install paramiko
python3 Scripts/verify_flash.py                              # 默认 192.168.1.1 root/root
python3 Scripts/verify_flash.py --host 10.0.0.1 --user admin --password xxxx
ROUTER_HOST=192.168.1.1 ROUTER_PASSWORD=root python3 Scripts/verify_flash.py
```

## 上游参考

- 自用源码：[VIKINGYFY/immortalwrt](https://github.com/VIKINGYFY/immortalwrt)
- 自用插件：[VIKINGYFY/packages](https://github.com/VIKINGYFY/packages)
- 本地编译器：[VIKINGYFY/OWRT-Tools](https://github.com/VIKINGYFY/OWRT-Tools)
- 上游项目：[VIKINGYFY/OpenWRT-CI](https://github.com/VIKINGYFY/OpenWRT-CI)
- U-BOOT（高通）：[chenxin527/uboot-qsdk12.5-build](https://github.com/chenxin527/uboot-qsdk12.5-build) / [1980490718/u-boot-2016](https://github.com/1980490718/u-boot-2016)

#
[![Stargazers over time](https://starchart.cc/VIKINGYFY/OpenWRT-CI.svg?variant=adaptive)](https://starchart.cc/VIKINGYFY/OpenWRT-CI)
