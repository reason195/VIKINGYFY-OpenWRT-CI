# VIKINGYFY-OpenWRT-CI（京东云 jdcloud_re-cs-07 定制版）

基于 [VIKINGYFY/OpenWRT-CI](https://github.com/VIKINGYFY/OpenWRT-CI) 的 ImmortalWRT 固件自动构建项目，本仓库只维护单设备固件：

- 设备：京东云 jdcloud_re-cs-07（Qualcomm IPQ60xx 平台，无 WiFi）
- 目标：`qualcommax/ipq60xx`，aarch64
- 登录地址：`192.168.1.1`，root 密码由 GitHub Secret `ROUTER_ROOT_PASSWORD` 注入
- 构建：每日 **00:17（北京时间）** 检查上游 [VIKINGYFY/immortalwrt](https://github.com/VIKINGYFY/immortalwrt) 的 **`owrt` 分支**，有更新才自动编译并发布 release；旧 release 自动清理只留 5 个
  - 上游 `main` 分支已于 **2026-10-15 停更**（最后一个提交 `f9b0ce7`），继续跟 `main` 等于冻结在旧内核/旧插件；本项目与旁路由项目（fork 自本项目）一样改用仍在更新的 `owrt`（2026-11-26 `f814b1b`）
  - 换分支的副作用：release tag 前缀由 `IPQ60XX-WIFI-NO-VIKINGYFY-main-` 变成 `-owrt-`，**已在跑 `-main-` 固件的设备需要手动刷一次**（旧固件的自动升级脚本里写死了旧前缀，跨前缀不会自己升）；刷入新固件后 `auto_upgrade.sh` 改为从 `/etc/buffy-version` 推导前缀，此后 CI 再换分支也不会卡死

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
| `TAILSCALE_AUTHKEY` | `/etc/config/tailscale`（Tailscale 预认证密钥，可选；缺省只装不登录） |

必需 secret 缺失会终止构建；可选 secret 缺失只置空占位符、不阻断构建。

## 固件内置功能

- **OpenClash**：核心 / 规则集 / GEO / 大陆白名单 / 面板均在构建期预置，刷机首启即用（首启规则集空缓存死锁已修复）；控制台登录密钥与 SOCKS5/HTTP(S) 认证由 `luci-app-openclash` 首启随机生成（旧版自造值在升级首启自动迁移），快照见 `/etc/openclash-credentials.txt`
  - 内置覆写钩子 `/etc/openclash/custom/openclash_custom_overwrite.sh`（DNS 缓存 4096、监听 `127.0.0.1:7874`、各订阅注入 `client-fingerprint: chrome`、跨地区「自动选择」url-test、**美国优先** fallback 组作为默认代理首项）与覆写模块 `OC_SelfHeal_AntiLeak`（节点列表每小时刷新、代理组 180s 健康检查、`empty-fallback: DIRECT`——全部节点失效时**直连放行**，不断网但会暴露真实出口，要零泄漏需改成 `REJECT`）
  - **美国优先**：默认代理首项为 `美国优先`（`fallback`：美国自动 → 自动选择），美国节点全挂自动退到全球最快，不用人工切组；`us_failover.sh` 每分钟兜底修复卡在死节点上的 `美国自动`/`美国策略`（Clash REST API，日志 `/tmp/us_failover.log`）。订阅里没有「美国自动」时钩子退回中性行为（首项仍是「自动选择」）
  - **Tailscale**：官方 `tailscale` + 社区面板 `luci-app-tailscale`（LuCI「系统→Tailscale」），节点名 `owrt-main`、宣告 `192.168.1.0/24`、`accept_dns=0`（不吃掉 dnsmasq/OpenClash 的 DNS）；`/etc/fw4-ts-snat.sh` 补 tailscaled 在本固件上配不出的 SNAT（无 iptables，linuxfw 初始化失败），`96-tailscale-panel-fix.sh` 首启修 helper（`tailscale0` IPv4、退出码、ACL 日志权限）；控制面域名已进 fake-ip-filter + 直连规则（否则 tailscaled 卡在 doLogin）
- **DNS**：OpenClash fake-ip 分流；dnsmasq 唯一上游锁定 `127.0.0.1#7874`（`append_wan_dns=0`），不再写 `60-fallback.conf` 直连兜底——客户端并发/重传时 dnsmasq 会把查询转给公共 DNS，绕过代理造成 DNS 泄漏（26.11.24 实机证实）。代价是 Clash 未就绪时没有 DNS 可用
- **订阅域名自同步**：`Scripts/openclash_sub_domains.py` 在构建期把 `proxy-providers` 的订阅域名追加进 `Files/etc/openclash/custom/` 的两个列表（fake-ip-filter + nameserver-policy，走国内 DoH 直连），机场换域名无需手改
- **DDNS + HTTPS**：DuckDNS DDNS、Let's Encrypt 证书（DNS-01）自动签发/续期、LuCI 强制 HTTPS
- **防火墙**：IPv6 WAN 放行 SSH/LuCI、wan 区域 forward=DROP、硬件流量卸载
- **监控告警**：ntfy + Telegram 双通道（见下方脚本）

### 监控脚本（`Files/usr/share/buffy/`）

| 脚本 | 作用 |
|---|---|
| `lib-buffy.sh` | 公共函数库（log/notify/resolve/证书检查/代理探测） |
| `boot_selfcheck.sh` | 开机自检：确认 OpenClash 核心 + 代理 204 就绪 |
| `health_check.sh` | 每日体检：WAN/DNS（唯一上游/防泄漏）/证书/防火墙/流量卸载 |
| `proxy_watch.sh` | 每小时代理 204 探测，失败告警（运行中守护） |
| `us_failover.sh` | 每分钟检查 `美国自动`/`美国策略`，卡在死节点上就切到存活节点或切回「美国自动」 |
| `cert_check.sh` | 每日证书签发/续期，失败告警 |
| `first_boot_download.sh` | 首启引导：更新 GEO/白名单/面板，幂等仅执行一次 |
| `auto_upgrade.sh` | 每日 10:07 检查 GitHub 新 release，自动下载校验并 sysupgrade（见「路由器端自动升级」） |

## 路由器端自动升级

`Files/usr/share/buffy/auto_upgrade.sh` 由 cron 每日 10:07 触发，发现新的 release 后自动下载、校验 sha256 并 sysupgrade 刷入：

- 构建窗口：CI 每天 **00:17（北京时间）** 检查上游并编译（`cron: 17 16 * * *` UTC），release 通常早于 10:07 的自动升级落地；若当天没赶上，设备次日再刷
- 开关：`/etc/config/auto_upgrade` 的 `enabled`（**默认 1**）；`keep_config=0`（**默认**）→ `sysupgrade -n` **不保留配置刷机**，改为 `1` 才保留
- Release 前缀：只刷与本机**同 CI 分支**的版本——前缀从 `/etc/buffy-version` 剥掉末尾日期推导（不再写死 `-main-`/`-owrt-`），推导不出来就跳过刷机并告警一次（宁可停更，也不能把旁路由/别的分支的镜像刷进主路由）；atom 里暂无本分支 release 时静默等待，不算故障
- 基线：`last_tag` 记录当前运行的 release tag；为空时读固件内 `/etc/buffy-version`（构建期由 `Settings.sh` 写入）作为运行版本，据此判断是否需要升级
- 保留配置刷机时会额外打包 `/etc/tailscale/tailscaled.state`（`sysupgrade -f`）——否则每次刷机都以同一 authkey 重新注册，tailnet 里留下一串 `owrt-main-1/2` 且子网路由要重新批准
- 校验：读 release 附带的 `SHA256SUMS.txt`（免 GitHub API 限流），sha256 不符即中止；刷机前校验 `board_name`
- 日志：`/tmp/auto_upgrade.log`；失败与"未启用"都会推 ntfy/Telegram 告警（后者每周一提醒一次）
- 调试：`AUTO_UPGRADE_DRYRUN=1 /usr/share/buffy/auto_upgrade.sh` 走完整流程但不刷写

```bash
uci show auto_upgrade                                # 查看开关与基线
uci set auto_upgrade.@auto_upgrade[0].enabled='1'    # 启用
uci commit auto_upgrade
/usr/share/buffy/auto_upgrade.sh                     # 立即执行一次
```

> 为什么默认不保留配置：`/etc/rc.local` 在 `/lib/upgrade/keep.d/base-files-essential` 的保留清单里，
> 保留升级会让它永远停在旧固件的版本、新版的开机钩子进不了运行层，`sysupgrade -n` 才会用上镜像里的新文件。
> `-n` 会清空 `/etc/config`（本开关也在里面），刷机后由镜像内置的 `Files/etc/config/auto_upgrade` 恢复
> 默认值（`enabled=1`、`keep_config=0`），`last_tag` 缺失时脚本再按 `/etc/buffy-version` 自愈基线。
> 排查看 `/tmp/auto_upgrade.log`（每次运行都记录「刷机模式」）与 `uci show auto_upgrade`；
> 改回保留配置：`uci set auto_upgrade.@auto_upgrade[0].keep_config='1' && uci commit auto_upgrade`。

## 一键升级

`Scripts/upgrade_firmware.py` 从 GitHub latest release 下载本设备的 sysupgrade 固件、校验 sha256 并刷入：

```bash
pip install paramiko
python3 Scripts/upgrade_firmware.py                            # 默认 192.168.1.1 root/root，不保留配置刷机（sysupgrade -n）
python3 Scripts/upgrade_firmware.py --dry-run                  # 只下载+校验，不刷机
python3 Scripts/upgrade_firmware.py --yes                      # 跳过刷机确认（默认已是不保留配置）
python3 Scripts/upgrade_firmware.py --keep-config              # 改回保留配置升级（不清空 /etc 覆盖层）
python3 Scripts/upgrade_firmware.py --no-verify                # 刷机后不等待重启、不自动复验
```

- sha256 以 GitHub 资产 `digest` 为准，本地 + 路由器侧双重校验，不一致即中止
- 刷机前校验路由器 `board_name` 与固件设备段一致，防止刷错设备
- 默认不保留配置（`-n` 清空 `/etc` 覆盖层，改用镜像内置配置，含构建期注入的 secret）：刷机前先在路由器上 `sysupgrade -b /tmp/backup.tar.gz` 备份，需要时 `sysupgrade -r` 还原
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
