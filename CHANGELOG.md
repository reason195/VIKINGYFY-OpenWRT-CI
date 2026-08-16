# 变更记录（2026-08-16）：实机验收两处固件 bug 修复 + 刷机校验工具增强

针对最新 release（26.08.15-21.46.59）实机验收发现两处固件 bug 并修复：proxy_watch 自加入以来从未成功运行（缺执行位）；`ipv6 'auto'` 与显式 wan6 冲突导致 wan_6 接口每秒翻动。均已在仓库修复，并在路由器上应急修复验证通过。

## 一、proxy_watch.sh 缺执行位（每小时代理探测自加入以来静默失败）

- **现象**：cron `5 * * * *` 每次执行 rc=126（Permission denied），crond 无告警、`/tmp/proxy_watch.log` 从未产生——代理中断时唯一的小时级探测完全失效。
- **根因**：git 索引中该文件为 100644（其余 buffy 脚本均 100755）；`Settings.sh` 的 `cp -rf` 原样烤入固件；`WRT-CORE.yml` Check Scripts 的 `chmod +x` 只作用于 maxdepth 3，buffy 脚本在深度 5 救不到。
- **修复**：`git update-index --chmod=+x`（proxy_watch.sh 与 lib-buffy.sh 一并对齐 755）；`Settings.sh` 拷贝后对 `./files/usr/share/buffy/*.sh` 兜底 `chmod +x`。
- **实机验证**：路由器 chmod +x 后直接执行 rc=0、`proxy 204 OK`、失败标记自动清除。

## 二、wan `ipv6 'auto'` 与显式 wan6 冲突（wan_6 每秒翻动，1d855ec 引入的回归）

- **现象**：pppoe wan 的 `ipv6 'auto'` 自动派生 wan_6 虚拟 dhcpv6 接口，与显式 wan6 形成两个 odhcp6c 同链路、同 DUID 冲突；wan_6 永久 pending 且每秒翻动（实测 15 分钟 1682 条日志），logread 环形缓冲被冲爆（只能回看约 3 分钟，掩盖其他故障痕迹），load ~2.1。IPv6 本身经显式 wan6 一直正常（GUA + /60 PD）。
- **修复**：`Files/etc/config/network` wan 段改为 `option ipv6 '1'`——只协商 IPv6CP、不派生 wan_6，DHCPv6 继续由显式 wan6 负责。
- **实机验证**：路由器 uci 同改并 reload 后 wan_6 消失、翻动停止、wan6 重新拿到 GUA + /60、load 从 2.1 回落至 ~1.4。

## 三、verify_flash.py 两处修正

- `compare_secret` 占位符匹配 `.+?` → `.*?`：可选 secret 未配置时构建期置空注入，空串无法匹配 `.+?`，导致 sing-box config.json 误报 FAIL（本次实发）。
- 新增执行位校验：git 索引为 100755 的文件，路由器 /rom 侧必须可执行（Windows 工作区读不到真实权限位，故以 git 索引为准；校验逻辑见 `git_index_mode`）——正是此前漏掉问题一的盲区。
- 注意：本仓库自身提交不触发 CI 构建（定时任务只比较上游 immortalwrt 是否更新），需手动 workflow_dispatch 或等上游更新后，以上固件侧修复才会进入 release。

## 四、代理检测静默模式：手动停止 OpenClash 不再告警

- **需求**：经 LuCI 手动停止 OpenClash 后，proxy_watch（每小时 204 探测）与 boot_selfcheck（重启后开机自检）仍会探测失败并推送"代理中断/自检失败"告警。
- **难点**：enable=0 不等于"手动停止"——init 的 start_fail() 在**启动失败**时同样会清零 enable（boot_selfcheck 原注释明确记录过此行为），只看 enable 会把最需要告警的静默故障静音。
- **方案**（三处配合）：
  - `Handles.sh` 构建期给 openclash init 增加补丁：start_fail() 失败时额外留下 `/etc/.openclash-start-failed` 标记；start_service() 真正开始启动尝试时清除（enable=0 的空跑不清除，避免"失败后仅重启不处理"时标记丢失、告警静默）；
  - `proxy_watch.sh` / `boot_selfcheck.sh` 按状态分流：enable=0 且无标记 → 手动停止，静默跳过；enable=0 且有标记 → 启动失败，照常告警；enable=1 → 运行期崩溃照常告警（运行期崩溃不会清 enable）。
- **边界**：LuCI 停止按钮会置 enable=0（实机确认），纯 CLI `/etc/init.d/openclash stop` 不改 enable，视为临时中断仍会告警一次——需要静默请用 LuCI 停止或 `uci set openclash.config.enable='0'`。
- **实机验证**：手动停止状态 proxy_watch 跳过（rc=0 不发告警）、boot_selfcheck 0 秒跳过；模拟启动失败（enable=0 + 标记）走告警分支（rc=1、204 FAIL、推送告警）。

## 五、OpenClash 周更任务畸形 cron 行修复（GEO/大陆白名单自动更新静默失效）

- **发现**：26.08.16 固件实机验收发现运行时 crontab 里 OpenClash 自动生成的周更任务是 4 字段畸形行（`0  * *  /usr/share/openclash/openclash_geo.sh ipdb`），busybox crond 整行拒绝 → GEO 数据库/大陆白名单的每周自动更新自始无效（此前被首启引导下载掩盖；旧固件同样存在）。
- **根因**：开机流程 `boot() → restart() → stop_service()` 先 `del_cron` 删除烤入的正确 5 字段行（带 #openclash-cron-task 标记），随后 `add_cron()` 按模板 `0 $(day_time) * * $(week_time) cmd` 重新生成；`geo_update_day_time` / `geo_update_week_time` 等 10 个时刻表选项从未配置，`uci_get_config` 对缺失选项返回空且退出码 0，模板里的 `|| 兜底`永不触发 → 两个字段为空。
- **修复**：`93-buffy-openclash.sh` 补齐 5 组时刻表选项（周一凌晨 0-4 点错峰，与 Files/etc/crontabs/root 烤入版一致），`add_cron` 即可自行生成正确行。
- **实机验证**：设置选项并重启 OpenClash 后，add_cron 重新生成全部 5 行标准 5 字段任务，代理 204 恢复正常。

## 六、性能优化落地（第二轮实机评估产出）

- **sysctl 生效顺序修复**：`/etc/init.d/sysctl` 按字典序应用 `/etc/sysctl.d/*.conf`（字母 > 数字），qca-nss-ecm.conf（conntrack_max=65535）在 `99-` 之后应用、覆盖烤入的 131072（实机复现）。文件改名 `99-` → `zz-network-optimizations.conf` 保证最后应用。
- **TCP 缓冲区上限 1MB → 4MB**：代理两段 TCP 均终结于路由器，单流吞吐上限 ≈ 缓冲/RTT，1MB 在 50ms RTT 下仅 ~160Mbps。
- **BBR**：`GENERAL.txt` 增加 `kmod-tcp-bbr`，sysctl 末行启用（旧固件无模块时该行失败、不影响其余行，新固件自动生效）。
- **find-process-mode: always → off**（`Handles.sh` 构建期注入 MihomoPro.yaml）：路由器场景 LAN 流量永远匹配不到本机进程，always 对每个连接白查一次 /proc。
- **移除 coremark**（每日 4:00 跑分无意义）**与 luci-app-samba4**（零共享空转 ~30MB）。
- **评估结论修正**：首轮评估的「DNS 劫持断链」为误报——测试时 OpenClash 处于手动停止状态，明文解析/污染 IP/无 fake-ip 均为停止态设计行为；运行态受控复测 fake-ip（198.18.0.9）、dnsmasq→7874 劫持、国外域名 AAAA 抑制全部正常。IPv6 泄漏担忧同理撤销。
- **路由器应急**（即时生效）：zz- sysctl 部署（conntrack 131072、缓冲 4MB 实测就位）、samba4 停用、coremark cron 删除、find-process-mode 改 off 并重启验证 204 OK。BBR 与包精简待下次构建。

# 变更记录（2026-08-17）：OpenClash url-test 组 tolerance 注入 + YYDS 新版评估

## 一、url-test 策略组注入 tolerance: 50

- **问题**：legacy 模板的 url-test 锚点（BaseUT）无 tolerance（默认 0），节点延迟 1ms 之差即切换出口 IP，破坏会话一致性（流媒体 IP 风控、网页登录态掉线）。
- **修复**：`Handles.sh` 构建期对 BaseUT 锚点注入 `tolerance: 50`（新节点快 50ms 以上才切换；与 YYDS 新版 Pro v2.0.6 的标配取值一致），幂等防重复注入，模板变更 WARN 跳过。
- **实机验证**：路由器注入后 `clash_meta -t` 校验通过、重启后 204 OK。

## 二、YYDS 新版（Pro v2.0.6）评估结论：维持 legacy

- **兼容性实测**：新版注入真实订阅后 `clash_meta -t` 校验通过，与当前 alpha 核心完全兼容。用户此前"起不来"的原因是新版 proxy-providers 为注释掉的示例行，需取消注释并替换 `YOUR_PRIMARY_URL`/`YOUR_BACKUP_URL`（旧版为中文占位符「优质订阅源地址」）。
- **不迁移的原因**：新版 fake-ip-filter 丢失 `rule-set:China/Direct/Private`（仅 5 个固定域名），国内域名将落入 fake-ip、全部挤进 clash 用户态转发——相比 legacy 的「国内域名真实 IP → nft china_ip_route 内核直连 → NSS 硬件加速」是显著性能退步；另缺少欧盟策略组与 AppleCN/Download/抖快书/XPTV 等规则集。新版取向为软路由 TUN 场景。
- **新版优点择优吸收**：其标配的 `tolerance: 50` 已按上节注入 legacy。

## 三、BBR 本地安装验证：不可行

- 实测 `apk add kmod-tcp-bbr` 失败：固件未配置任何软件源，且自编译内核（fork @1f96307）与官方源 kmod 的 vermagic 不匹配，装上也无法加载。
- 正确路径为下次构建（GENERAL.txt 已含 kmod-tcp-bbr），刷入后 `sysctl -n net.ipv4.tcp_congestion_control` 应输出 bbr（sysctl 行已就位）。

## 四、工具链：一键升级 + uci-defaults 运行时校验 + 离线单测

- **`Scripts/upgrade_firmware.py`（新增）**：一键从 GitHub latest release 下载本设备 sysupgrade 固件并刷入。sha256 三重校验（GitHub 资产 digest → 本地 → 路由器侧，任一不符即中止）；刷机前校验 `board_name` 防刷错设备；nohup 触发防 SSH 断连；刷机后按 uptime 下降确认真重启、等待开机自检（含静默模式跳过分支）再自动运行 `verify_flash.py` 复验。支持 `--dry-run` / `--reset`(sysupgrade -n) / `--tag` / `--no-verify`。
- **`verify_flash.py` 增强**：新增第 2 节「uci-defaults 运行时效果」校验——第 1 节 SKIP 掉的 4 个首启消费脚本（dropbear 解绑 / uhttpd 强制 HTTPS / 防火墙卸载与 WAN v6 放行 / OpenClash 全量选项含 cron 时刻表与凭据一致性）现在有运行时断言，补上文件比对覆盖不到的盲区。
- **`Tests/test_upgrade_firmware.py`（新增）**：18 例离线单测（mock GitHub API / SSH / 下载 / 时间），全部通过。
- 已在 26.08.17-00.13.34 固件实测：30 项文件一致 + 4 项 uci-defaults 效果全绿。

# 变更记录（2026-08-13）：开机噪音根治 + 开机自检/全机体检 + 硬件流卸载修复

在上一轮验收基础上收尾四件事：根治 OpenClash 开机日志噪音、加开机自检与告警、加全机体检脚本、修复硬件流量卸载未默认开启。

## 一、根治 OpenClash 开机 shell 噪音（'1/0: not found' + 'sh: out of range'）

- **现象**：每次开机 logread 里都出现 10 行噪音，夹在「OpenClash Already Stop!」与「OpenClash Already Start!」之间：
  ```
  /etc/rc.d/S99openclash: /etc/rc.common: line 42: 1: not found
  /etc/rc.d/S99openclash: /etc/rc.common: line 42: 0: not found
  ...（line 42~48 各两行）
  /etc/rc.d/S99openclash: sh: out of range
  ```
- **根因（设备实测 + 上游 issue #4822/#5084 确认）**：`boot() -> restart() -> stop_service/start_service` 整条启动链路未重定向输出；`start_service` 的 `do_run_file()` 里那行包管理器检测 `[ "$small_flash_memory" == "1" ] || ... || $(opkg status libc ...) || $(apk list libc ...) && mkdir -p /tmp/etc/openclash && CACHE_PATH=...` 的 `&&`/`||` 优先级与命令替换在 busybox ash 下触发 `1/0: not found` + `sh: out of range`（报错行号落在 `/etc/rc.common` 的 `enable()` 函数体 line 42~48）。纯噪音：核心随后照常 `Start Successful`，不影响任何功能（此前已实测）。
- **修复**（`Scripts/Handles.sh` 构建期补丁，最小改动）：把 `boot()` 末尾的 `restart` 改为 `restart >> "$LOG_FILE" 2>/dev/null`——函数重定向会传导到所有子调用（含后台 `check_core_status`），噪音从 stderr 彻底消失；`LOG_*` 本就写 `/tmp/openclash*.log`，诊断信息不受影响。upstream 结构变化时 WARN 跳过、不阻断构建。

## 二、开机自检（防「看似启动、实际未接管流量」的静默故障）

新增 `Files/usr/share/buffy/boot_selfcheck.sh`（rc.local 开机 120s 后台拉起，flock 防重入）：
- 校验核心 `/etc/openclash/core/clash_meta` 存在且可执行；
- 等 `pidof clash` + external-controller(9090/`cn_port`) 应答（最长 5 分钟）；
- 端到端代理 204（路由器自身经 clash + 显式 7890/7891/7893 端口兜底，最长 5 分钟，规避「启动早期节点未就绪」竞态）；
- 失败写 `/tmp/boot_selfcheck.log` 并推 ntfy `buffy-reason195-router`（同次开机去重）；成功只更新时间戳不打扰。
- 守卫按「MihomoPro.yaml 存在即校验」而非 `enable` 标志——因为 init 的 `start_fail()` 失败时会把 enable 清零，只盯 enable 会漏掉最该告警的静默故障。

## 三、全机体检（非 OpenClash 项）

新增 `Files/usr/share/buffy/health_check.sh`（每日 06:30 cron，可手动运行，失败推 ntfy）：
- WAN：IPv4 默认路由/网关可达/公网 IPv4 可达/IPv6 地址与可达性/DNS 解析；
- DDNS 证书：`reason195.duckdns.org` 可解析 + LE 证书剩余天数（>14 天）；
- dnsmasq 备用上游：`60-fallback.conf` 按真实 conf-dir（`/tmp/dnsmasq.<cfgid>.d`）glob 定位、dnsmasq 运行、本地解析；
- 防火墙：IPv6 放行规则（`Allow-WAN-SSH-v6`/`Allow-WAN-LuCI-v6`）、wan 区域 forward=DROP、IPv6 转发；
- 硬件流量卸载：开关 + nft flowtable 状态。

## 四、修复：硬件流量卸载默认未开启

- **根因**：`92-buffy-firewall.sh` 只设了 `flow_offloading_hw=1`。查 fw4 源码（`fw4.uc` 的 `resolve_offload_devices()`）发现它**先判断软件开关 `flow_offloading`，未开启则直接返回空、根本不生成 flowtable**——只开硬件开关等于没开。
- **修复**：补设 `flow_offloading=1`（软件开关负责生成 flowtable + `flow offload` 规则，硬件开关在其上加 `flags offload`；内核不支持硬件时 fw4 自动回退软件卸载，不会断网）。

---

# 变更记录（2026-08-13 追加）：路由器重启起不来 + 构建阶段预置 GEO/白名单/最新面板

用户反映「路由器重启后起不来，必须手动断电才能恢复网络」，同时要求验证并固化构建阶段的 GEO 数据库、大陆白名单下载与面板版本更新。本轮三项改动均已完成并本地验证。

## 一、修复：重启后起不来（需断电恢复）——qca-ssdk 热重启回归

- **现象**：路由器（京东云 RE-CS-07 / IPQ60XX-WIFI-NO）执行重启后无法正常启动，必须断电重新上电才能恢复网络；冷启动正常。
- **根因（三重证据）**：
  1. 上游 [VIKINGYFY/OpenWRT-CI#351](https://github.com/VIKINGYFY/OpenWRT-CI/issues/351)「05/10之后的60xx-wifi-no版本升级出现重启异常问题」，维护者自认「可能是新版ssdk的问题」；
  2. 上游 2026-05-12 提交 `bb72cd01`（`{qca-nss-dp, qca-ssdk} update to win.nss.1.1.r35`）恰好把 ssdk 从 446db12b 升级到 d9a19649，与本固件实际安装的 `kmod-qca-ssdk 2025.11.14~d9a19649` 吻合；
  3. 新旧 ssdk 源码对比：旧版 `ssdk_driver` **无** `.shutdown` 处理器（重启正常）；新版新增 `.shutdown = ssdk_shutdown`（重启时 `cancel_delayed_work_sync` 停掉 mac/sw 同步工作）。与 OpenWrt 官方已确认的 ath11k 热重启回归（[PR #24601](https://github.com/openwrt/openwrt/pull/24601)：新增 shutdown 处理器 → warm reset 后起不来，仅断电可恢复）同型。
- **修复**（最小改动，恢复旧版已知正常行为）：新增补丁 `Scripts/patches/qca-ssdk-012-drop-ssdk-shutdown-handler.patch`，删除 `ssdk_shutdown()` 及 `.shutdown` 注册；`Scripts/Settings.sh` 在 qualcommax 构建时把补丁拷入 `package/qca-nss/qca-ssdk/patches/`（OpenWrt 自动应用，编号 012 接在现有 011 之后）。已在真实 ssdk 源码上验证补丁干净应用、无残留引用（避免未用 static 函数告警）。
- **验证方式**：重新编译刷入后测试 `reboot`（或 LuCI 重启）即可确认；若仍复现，需串口日志定位（SBL1 卡点 / 内核 boot 卡点）。

## 二、构建阶段预置 GEO 数据库 + 大陆白名单（不再依赖首启联网下载）

此前 OpenClash 的 GEO 数据库与 chnroute 只在路由器首启由 `first_boot_download.sh` 下载（依赖首启网络，失败下次开机重试）。本轮改为 **`Scripts/Handles.sh` 构建时直接下载并烤进固件**，刷机首启即用：

- **GEO 数据库**（下载源与 `openclash_geo.sh` 完全一致，jsdelivr 镜像优先、GitHub 直连兜底）：
  - `GeoIP.dat`（Loyalsoldier/v2ray-rules-dat）→ `/etc/openclash/GeoIP.dat`
  - `GeoSite.dat`（同仓库）→ `/etc/openclash/GeoSite.dat`
  - `ASN.mmdb`（xishang0128/geoip）→ `/etc/openclash/ASN.mmdb`
  - `Country.mmdb`（alecthw/mmdb_china_ip_list lite）→ `/etc/openclash/Country.mmdb`
  - 校验：>10KB 且非 HTML 响应，失败终止构建（与核心/规则集/MihomoPro 同策略）。
- **大陆白名单 chnroute**（源 ispip.clang.cn，与 `openclash_chnroute.sh` 相同）：
  - 下载 `all_cn.txt` / `all_cn_ipv6.txt`，按脚本 fw4 分支逐字节生成 `china_ip_route.ipset` / `china_ip6_route.ipset`（ImmortalWRT 使用 firewall4，`93-buffy-openclash.sh` 已设 `china_ip_route=1`），烤进 `/etc/openclash/`。实测 v4 4337 条 / v6 1617 条。
- **实测**：本机完整跑通构建段脚本——4 个 GEO 文件（17.4MB/10.4MB/12MB/212KB）、v4/v6 ipset、面板 zip 全部下载并落位正确。

## 三、构建阶段预置最新面板（Zashboard / Metacubexd）

openclash 包自带的面板是仓库固定版本（可能滞后）。本轮在构建时用与 `openclash_download_dashboard.sh` 相同的源**拉取最新版并覆盖**：

- **Zashboard**：`Zephyruso/zashboard` gh-pages-cdn-fonts 分支 zip → `/usr/share/openclash/ui/zashboard/`
- **Metacubexd**：`MetaCubeX/metacubexd` gh-pages 分支 zip → `/usr/share/openclash/ui/metacubexd/`
- 校验：解压目录存在且 `index.html` 非空，失败终止构建。实测各 17 个文件、index.html 就位（Metacubexd v1.271.0）。
- 说明：路由器的周更 crontab 与 `first_boot_download.sh` 保留不变（刷机后仍可自动追新）；本改动保证**刷机那一刻就是最新版**。

# 变更记录（2026-08-13）：刷机验收 + 构建修复「OpenClash 核心/规则集烤不进固件」

用户刷入最新 release（IPQ60XX-WIFI-NO-VIKINGYFY-main-26.08.12-05.42.01，上游 de810bc，内核 6.18.41）后验收，发现 OpenClash 首启失败，逐层定位出**两个构建侧缺陷**并已修复（路由器上也已同步修复并全链路验证）。

## 一、缺陷 1：核心烤错路径（首启 "Core is not Detected"）

- **现象**：刷机后 OpenClash 启动即报 `【Meta】Core is not Detected installed` → 联网下载核心 → 版本检查失败 → `enable` 被重置为 0 → 整个科学上网不可用。
- **根因**：`Scripts/Handles.sh` 把核心下载到 `$OC_DIR/root/usr/share/openclash/core/clash_meta`，而 OpenClash master 的规范路径是 **`/etc/openclash/core/clash_meta`**（`openclash_core.sh` 的 `meta_core_path`；init 启动时 `[ ! -f /etc/openclash/clash ]` 才触发下载）。固件里 `/usr/share/openclash/core/clash_meta` 一直存在（10.7MB）但 OpenClash 从不检测该路径。
- **修复**（`Scripts/Handles.sh`）：
  - 下载路径改为 `$OC_DIR/root/etc/openclash/core`（随包 root/ 整体安装到 `/etc/openclash/core/`，Makefile `$(CP) root/*` 已确认）。
  - 下载后校验：文件 >5MB 且 `file` 判定 `ARM aarch64` ELF（构建机为 x86_64，不能直接执行 arm64 二进制）——校验失败**终止构建**，不再静默产出无核心坏固件（原逻辑 `download failed; continuing!`）。
- **实测**：修复后 `/etc/openclash/clash` 软链正常指向核心、9090 API 就绪、`OpenClash Start Successful!`，全程不再触发联网下载。

## 二、缺陷 2：首启规则集空缓存死锁（刷机后全屋 DNS 挂）

- **现象**：核心修好后 OpenClash 能启动，但所有 provider 拉取 `EOF`、系统 DNS 对所有域名返回 "No answer"。
- **根因（首启死锁链）**：规则集（rule-set）无本地缓存 → 需联网下载 → 依赖 DNS 解析 github/jsdelivr 域名 → fake-ip-filter 域名走 nameserver(DoH) 解析 → DoH 连接按 `respect-rules` 路由 → 规则未加载 → 落 `MATCH` **空代理组** → EOF → 全链路断。备用订阅是纯 IP URL（`141.148.169.212`）所以能拉成功，反向印证了「只有域名解析是死的」。线上路由器此前正常是因为规则集已有本地缓存；刷机首启无缓存即死锁（此前的验收漏掉了首启场景）。
- **决定性证据**：包里烤入的 `oc-cn-domain.mrs` 首启直接加载 114,954 条规则 → 证明「规则集烤进固件即可首启生效」。
- **修复**（`Scripts/Handles.sh`）：构建时解析 `MihomoPro.yaml` 的 `rule-providers` 段（兼容 YYDS 内联锚点格式 `{<<: *BehaviorDN, url: ...}` 与展开多行格式），按 OpenClash 路径约定 `./rule_provider/<name>` 把**全部规则集烤进** `$OC_DIR/root/etc/openclash/rule_provider/`，任一失败终止构建。39 个 666OS 规则集 + 包自带 oc-cn-domain.mrs ≈ **1MB**，固件体积影响可忽略。
- **实测**：40 个规则文件就位后重启 OpenClash——China 111,338 条 / Proxy 27,274 条等全部加载，kaze1/github 返回真实 IP、google 返回 fake-ip（198.18.0.18 分流正确），主订阅（[优] Hong Kong 节点）+ 备用订阅均拉取成功，`google/generate_204`=204、baidu=200。
- **顺带**：`MihomoPro.yaml` 下载失败也改为终止构建（原来 `continuing!`，与核心/规则集一致）。

## 三、缺陷 3：rc.local 备用 DNS 落错目录（从未生效）

- **现象**：dnsmasq conf-dir 里始终没有 rc.local 写的 `60-fallback.conf`（备用上游 223.5.5.5 等从未生效）。
- **根因**：`Files/etc/rc.local` 用 `uci show dhcp | sed -n "s/^dhcp\.\([^.]*\)\.type='dnsmasq'.*/\1/p"` 提取 cfgid——但本固件 uci 对匿名 dnsmasq section 打印为 `dhcp.@dnsmasq[0]=dnsmasq`，**不存在 `.type='dnsmasq'` 行**，提取恒为空 → 写到 `/tmp/dnsmasq..d` 错误目录。
- **修复**（`Files/etc/rc.local`）：改用与 OpenClash init 相同的方法——`uci -q show 'dhcp.@dnsmasq[0]'` 首行 awk 取 cfgid，再读 `/tmp/etc/dnsmasq.conf.<cfgid>` 的 `conf-dir=`；带 `/tmp/etc/dnsmasq.conf.*` 兜底。已在路由器实测：cfgid=cfg01411c、DIR=/tmp/dnsmasq.cfg01411c.d；停用 OpenClash 期间 baidu/github 正常解析（备用上游接住），OpenClash 重启后 `60-fallback.conf` 保留不被清理。

## 四、刷机验收结论（其余项全部通过）

- 固件版本：与最新 release 完全一致（上游 de810bc / 内核 6.18.41）。
- 核心路径、规则集、MihomoPro.yaml（22.8KB，含订阅注入）、fake-ip-filter 6 条、第二 DNS（reason195.duckdns.org → 真实 IP 13.251.105.66）、dnsmasq cachesize=0、备用上游、DDNS、防火墙 v6 放行、证书自愈、cron 定时任务均按设计就位。
- 首次开机引导：GeoIP/GeoSite/chnroute 更新成功；Zashboard/Metacubexd 面板更新警告（当时 DNS 尚在恢复中），下次开机自动重试（设计行为）。
- 路由器已同步修复：`/etc/openclash/core/clash_meta` 就位、40 个规则集就位、修复版 `/etc/rc.local` 上线（与仓库 HEAD 比对字节一致后覆盖），重启后可自恢复。

# 变更记录（2026-08-12）

本轮工作分两部分：**① 在路由器（京东云 RE-CS-07 / ImmortalWRT SNAPSHOT）上在线完成了一系列优化与修复**；**② 把全部改动固化进本仓库的 `Files/` 与 `Config/`，使重新编译的固件开箱即用（即插即用）**。

---

## 一、路由器在线调整（已全部生效并验证）

### 1. DNS 备用上游 + strict-order（故障切换）
- 现象：dnsmasq 只转发 `127.0.0.1#7874`（OpenClash），clash 一挂全屋 DNS 即断。
- 处理：新增备用上游 `223.5.5.5` / `119.29.29.29` / `2400:3200::1`，并开启 `strictorder`（保证正常时 100% 走 clash 的 fake-ip，只有 clash 不可达才降级备用，避免 fake-ip 模式被真实 IP 绕过）。
- 实测：停用 OpenClash 期间 baidu/github 均正常解析（备用上游接住）；恢复后 fake-ip 正常。
- 关键实现细节：备用服务器**不能**写进 uci 的 `server` 列表——OpenClash 看门狗每 ~30 秒会把该列表强制重置为只剩 7874 一条。因此备用上游写入 **dnsmasq conf-dir**（`/tmp/dnsmasq.<cfg>.d/60-fallback.conf`，看门狗不管理），由 `rc.local` 每次开机重建。

### 2. dnsmasq DNS 缓存（cachesize=2048）持久化
- 现象：`cachesize` 反复被改回 0（OpenClash `disable_masq_cache=1` 的看门狗逻辑 + 启动时无条件归零的 bug）。
- 处理：
  - OpenClash 配置 `disable_masq_cache` 1 → **0**（看门狗不再强制归零）；
  - `dnsmasq_cachesize` 8000 → **2048**（OpenClash 自身记账值同步）；
  - `cachesize_dns` 1 → **0**（清理停止时误恢复为 0 的旧记账）。
  - 完整重启 OpenClash 验证：cachesize 保持 2048。

### 3. DDNS 修复（IPv6 远程访问）
- 现象：已有 DuckDNS 配置（reason195.duckdns.org）从不更新——`ip_interface` 写的是接口名 `wan6`（不存在），实际应写设备名 **`pppoe-wan`**；且 `ddns-scripts` 包此前未安装。
- 处理：修正 `ip_interface`，补装 `ddns-scripts` + `luci-app-ddns`。验证：`reason195.duckdns.org AAAA = 2409:8a5c:1403:4fed:...`（阿里/腾讯 DoH 均可查到），每 10 分钟自动检查更新。

### 4. 防火墙 IPv6 放行（外网访问路由器）
- 新增两条规则（`family ipv6`，`src wan`）：
  - `tcp 22`（SSH）
  - `tcp 80/443`（LuCI / HTTPS）
- dropbear 移除 `DirectInterface lan` 绑定，改为监听所有接口（否则外网 SSH 连不上）。
- 验证：通过 WAN v6 访问 LuCI 返回 200。

### 5. LuCI HTTPS（Let's Encrypt 正式证书）
- uhttpd 开启 `redirect_https`（HTTP 自动 307 跳转 HTTPS）。
- 用 acme.sh（DNS-01 验证，走 DuckDNS TXT，不依赖入站端口）+ DuckDNS 插件签发正式 LE 证书，部署到 uhttpd。
- 验证：Windows schannel 信任该证书链；外网 `https://reason195.duckdns.org` 无告警。
- 续期自动化：每日 00:00 `acme renew` + 00:05 重载 uhttpd。

### 6. 证书续期失败告警（新增）
- DuckDNS 无推送 API、路由器无邮件账户，故选用 **ntfy.sh** 推送（零配置，手机装 ntfy App 或直接访问网页订阅即可收到）。
- 脚本 `/usr/share/buffy/cert_check.sh`（每日 00:20 运行）：
  - 证书缺失 → 尝试签发，连续失败 ≥3 次推送告警；
  - 证书剩余 <14 天 → 尝试续期，失败推送告警；
  - 签发成功 → 自动把 uhttpd 切到 LE 证书。
- 订阅地址：`https://ntfy.sh/buffy-reason195-cert`。
- 改 `NTFY` 变量即可切换 Bark / ServerChan 等通道。

### 8. 按 Aethersailor 方案调整 OpenClash（2026-08-12 追加）
用户要求按 [Custom_OpenClash_Rules 设置方案](https://github.com/Aethersailor/Custom_OpenClash_Rules/wiki/OpenClash-%E8%AE%BE%E7%BD%AE%E6%96%B9%E6%A1%88) 调整，逐项落地并验证：
- **cachesize 归 0**：`disable_masq_cache` 0→**1**、`dnsmasq_cachesize`→**0**、`cachesize_dns`→**1**、dhcp `cachesize`→**0**。重启后运行期 `cache disabled`，方案要求的「禁止 Dnsmasq 缓存 DNS」生效（此前的 2048 缓存工作按用户决定撤销）。
- **第二 DNS（DDNS 域名返回真实 IP）**：采用 LuCI「DNS 设置」页的**第二DNS服务器**开关（`enable_custom_domain_dns_server=1` + `custom_domain_dns_server=223.5.5.5`，dnsmasq 侧，`server=/reason195.duckdns.org/223.5.5.5`）。验证：该域名返回真实 IP（13.251.105.66 / 2409:8a5c:...），不再被 fake-ip 劫持。
- **修正（2026-08-12）**：此前误用 `custom_name_policy`（nameserver-policy，clash DNS 引擎层）实现近似效果——那不是方案内容，且经实测在 0.47.156 下**未真正生效**（运行 yaml 无 nameserver-policy 段、无 reason195 条目）。已改回方案对应的 dnsmasq 侧开关，并关闭失效的 `custom_name_policy`；`custom_fakeip_filter` 则因后续发现的真实需求重新启用（见下节 9）。
- **GeoIP Dat**：`enable_geoip_dat` 0→**1**。
- **清理 Fallback 组**：禁用 `dns.google/dns-query`、`dns.cloudflare.com/dns-query`（方案要求无 fallback，非直连域名交远端解析）。
- **自动更新**：GEO/GeoIP/白名单数据库自动更新本就开启（每周，满足方案要求）；**配置本体的自动更新不适用**——当前是手动 YAML 路径（无订阅条目），方案三选一中的自动更新需改为订阅转换/覆写模块，为避免重蹈断网覆辙未切换。
- 全程带备份（`/root/bak-buffy/`）分步验证，未出现断网；重启后直连域名正常解析、代理域名仍 fake-ip、代理出口仍马来西亚。
- 说明：clash DNS 的 `ipv6: false`（方案在出站不支持 IPv6 时的标准做法）会过滤 AAAA——局域网内用域名访问路由器时只拿到 A 记录（DuckDNS 服务器地址），请直接使用 `192.168.1.1`；外网访问不受影响（手机用自己的 DNS 解析 AAAA）。

### 9. 刷机后验收与重大修复：provider 拉取全部 EOF（2026-08-12 追加）

刷机后的固件 OpenClash 无法拉取任何 provider（主订阅、规则源全部 `EOF`），全网断。逐层排查最终定位：

- **表象**：`[Provider] 优质服务商 pull error: Get "https://kaze1...": EOF`（主订阅+全部域名类规则源失败，仅 IP 直连的备用订阅成功）。
- **排除项**：核心二进制（裸跑对照试验）、nft 防火墙规则（清空规则后仍失败）、YAML 锚点（666OS 模板的 `&2/*2` 锚点结构、展开后仍失败）、TUN、IPv6 路由（补默认路由后 ping6 通）——均非根因。
- **根因（决定性证据）**：clash 的 SOCKS 出站完全正常（kaze1 经规则 DIRECT 得 403 可达），但 **clash DNS 对 kaze1 返回 fake-ip（198.18.0.128）**。provider 定义 `proxy: DIRECT` 拉取时域名经 respect-rules + fake-ip DNS 解析成 198.18.x.x，DIRECT 直连 fake-ip 必然 EOF；而普通连接走了规则（DIRECT 规则 → 真实 IP）所以正常。
- **修复（验证有效）**：启用 OpenClash 的 `custom_fakeip_filter`，把「路由器自身需直连」的域名加入 fake-ip-filter（强制解析真实 IP）：`+.aisaka-taiga.com`（主订阅）、`+.duckdns.org`（DDNS/acme）、`+.github.com`/`+.githubusercontent.com`/`+.githubassets.com`（规则源/面板下载）、`+.jsdelivr.net`（核心/Geo 下载）。
- **验证结果**：主订阅 19818B、备用 1836B 拉取成功，0 pull error；kaze1/duckdns/github 解析真实 IP、google 仍 fake-ip（分流正确）；baidu 200、google 200（经代理）、DuckDNS API 200（DDNS/acme 通路恢复）。
- 锚点排除：666OS 模板的 YAML 锚点/合并键曾高度嫌疑（展开后仍失败），实测**锚点非根因**——带锚点与展开版在修复后均验证可用。live 源配置保留固件烘焙的原始（带锚点）版本，与下次固件一致。

### 10. 订阅更新后 custom_fakeip_filter 持久性验证与自愈加固（2026-08-12 追加）

- **验证结论：更新订阅后修复依然生效**。模拟完整更新流程（重新下载 666OS YYDS 模板 → 注入机场订阅 URL → 替换 `config/MihomoPro.yaml` → 重启 OpenClash）后：运行 yaml 的 fake-ip-filter 自定义条目仍为 6 条、0 pull error、DNS 分流正常、出站正常。原因：`custom_fakeip_filter=1` 存于 uci（overlay），列表文件存于 `/etc/openclash/custom/`（overlay），`yml_change.sh` 每次生成配置时重新合并（`merge_list_from_file` 自带去重）。
- **已排查无风险的操作**：OpenClash stop/restart 的残留清理只删 `/tmp` 与 dnsmasq 配置（`dnsmasq_openclash_custom_domain.conf` 等），**不触碰 `/etc/openclash/custom/`**；`one_key_update`/`plugin_update` 只更新核心/插件，不重置 uci 配置；LuCI「更新配置」（`action_update_config`）走 `openclash.sh` → yml_change 重新合并；provider 节点更新只动 `proxy_provider/` 缓存。
- **自愈加固（rc.local）**：每次启动检查 `custom_fakeip_filter=1` 与列表文件存在性，被误删/改回 0 时自动恢复（内容与 `Files/etc/openclash/custom/openclash_custom_fake_filter.list` 一致）。已实测：删除列表 + 标志归 0 → 运行自愈块 → 列表重建、标志恢复 1 → 重启后运行 yaml 仍 6 条、0 错误。
- **刷机即自愈**：列表文件烘焙进 `/rom`（Files/ → rootfs），恢复出厂设置后 uci-defaults 重新执行 + `/rom` 文件保留，修复不丢。

### 7. 其他排查结论
- **SSH "密码错误" 根因**：非路由器故障，是 `sshpass` 在 Git Bash 下的 PTY 兼容问题。改用 OpenSSH `SSH_ASKPASS` 机制后 root/root 正常登录。
- **SSH 主机密钥变更告警**：known_hosts 里 192.168.1.1 的旧条目来自刷机前的旧固件，已清理（备份 `known_hosts.old`）。
- **cachesize 历史波动**（8000↔0）：OpenClash 自身管理行为，非人为。

---

## 二、固件化改动（本仓库）

### 软件包（`Config/GENERAL.txt`）
新增：
```
CONFIG_PACKAGE_ddns-scripts=y
CONFIG_PACKAGE_ddns-scripts-duckdns=y
CONFIG_PACKAGE_luci-app-ddns=y
CONFIG_PACKAGE_acme=y
```

### OpenClash 来源分支（`Scripts/Packages.sh`）
- `UPDATE_PACKAGE "openclash" "vernesong/OpenClash" "dev"` → **`master`**（稳定分支，与路由器已升级的 0.47.156 一致；已验证 master/dev/0.47.110/0.47.156 的默认配置逐字节相同，`93-buffy-openclash.sh` 完全兼容）。

### 配置文件（`Files/etc/config/`）
| 文件 | 改动 |
|---|---|
| `dhcp` | `cachesize`=**0**（按方案禁用 dnsmasq 缓存）；`quietdhcp 1`、`strictorder 1`、`rebind_domain cn.ntp.org.cn`（修复 DNS-rebind 误报）；SLAAC 混合 RA、静态租约（7 台设备） |
| `ddns` | `ip_interface` wan6→**pppoe-wan**（DDNS 修复），DuckDNS token |
| `network` | PPPoE 账号/密码、LAN 网段、IPv6 中继（wan6/modem） |
| `system` | 主机名 `OWRT`、时区 `CST-8`/`Asia/Shanghai`、NTP 国内服务器 |
| `acme` | **新增**：LE 证书配置（DNS-01 + DuckDNS，含 token），account_email 为真实邮箱 |
| `homeproxy` | 保留用户节点（edgetunnel）与自定义 DNS（未启用） |
| `upnpd` | 保留自定义 UUID / STUN（启用状态） |
| `ubootenv` / `cpufreq` / `autoreboot` / `fstab` / `openssl` / `partexp` / `mdmconfig` / `wireless` | 设备相关或含自定义值的配置，保留 |
| `crontabs/root` | 新增：00:00 续期 / 00:05 重载 uhttpd / 00:20 证书检查告警；周一面板周更（05:00 Zashboard / 06:00 Metacubexd，`openclash_download_dashboard.sh`） |

### 自定义项脚本（`Files/etc/uci-defaults/`，新增）
按「仓库只保留自定义项、其余默认选项由软件包自动生成」原则，把整文件覆盖改为**首次开机 uci-defaults 脚本**（默认选项随软件包版本自动继承，重置/重刷后同样生效）：

| 脚本 | 设置的自定义项 |
|---|---|
| `90-buffy-dropbear.sh` | 删除 `DirectInterface lan`（监听所有接口，外网 SSH 可达）；其余用 dropbear 包默认 |
| `91-buffy-uhttpd.sh` | `redirect_https=1` + 监听 443（自签证书首启自动生成，LE 证书签发后自动切换）；其余用 uhttpd 包默认 |
| `92-buffy-firewall.sh` | 新增 `Allow-WAN-SSH-v6`（tcp 22）/ `Allow-WAN-LuCI-v6`（tcp 80/443）两条 v6 放行规则 + `flow_offloading_hw`/`fullcone6` + wan 区域 `forward=DROP`；区域、默认规则及各软件包 include 均由包自行管理 |
| `93-buffy-openclash.sh` | `en_mode/operation_mode=fake-ip`、`redirect_dns=1`、`enable_respect_rules=1`、`log_level=error`、`china_ip_route=1`、`core_type=Meta`、`core_version=linux-arm64`、`github_address_mod`（镜像）、`enable_geoip_dat=1`、第二 DNS（`enable_custom_domain_dns_server=1` + `custom_domain_dns_server=223.5.5.5`，dnsmasq 侧）、`skip_proxy_address=1`、Meta sniffer、GEO/GeoIP/白名单自动更新、`disable_quic_go_gso`、dashboard 与 API 认证；dns_servers 等其余全部用包默认 |

> 说明：openclash 的 `enable`/`config_path` **不**在 uci-defaults 里设置——`rc.local` 检测到 `/etc/openclash/config/MihomoPro.yaml` 存在时才启用，避免空配置空转。`cachesize_dns`/`dnsmasq_cachesize` 为 OpenClash 运行时记账字段，不固化。

### 删除的冗余文件（与软件包默认值逐字节一致，软件包会自动生成）
用路由器本地 apk 仓库 `apk fetch` + `apk extract` 提取**同版本**包默认配置逐一比对后删除：

- `Files/etc/config/dropbear`、`uhttpd`、`firewall`、`openclash` —— 改为上方 uci-defaults 脚本
- `Files/etc/config/rpcd`、`etherwake`、`samba4`、`syncdial`、`luci`、`radius`（wpad 自带）、`sing-box` —— 与包默认逐字节一致
- `Files/etc/config/ubihealthd`、`wolultra` —— 空文件且无包归属
- `Files/etc/ppp/options`、`filter`、`chap-secrets` —— 与 ppp 包默认一致

### 启动脚本（`Files/etc/rc.local`）
- 每次开机重建 dnsmasq 备用上游 conf 文件（`/tmp` 重启即清）+ 重启 dnsmasq；
- 开机 ~90 秒后台触发证书自愈（首次开机即尝试签发 LE 证书）；
- 开机 ~30 秒后台触发首次引导（等 OpenClash 就绪 + 科学上网可用后自动更新 GEO 数据库 / 大陆白名单 / Zashboard / Metacubexd）。

### 新增脚本
- `Files/usr/share/buffy/cert_check.sh` —— 证书健康检查 + ntfy 告警（见上）。
- `Files/usr/share/buffy/first_boot_download.sh` —— 首次开机引导：等 OpenClash 启动完成、科学上网可用后，后台自动更新 GEO 数据库（GeoIP/GeoSite/ASN/Country，`openclash_geo.sh all`）、大陆白名单（chnroute v4/v6，`openclash_chnroute.sh`）、面板版本（Zashboard / Metacubexd，`openclash_download_dashboard.sh`）；成功写标记 `/etc/.openclash-bootstrap-done` 仅执行一次，失败下次开机重试。
- `Files/usr/lib/acme/client/dnsapi/dns_duckdns.sh` —— acme.sh 的 DuckDNS DNS-01 插件（acme 包不自带，需随固件补齐）。
- `Files/etc/openclash/custom/openclash_custom_domain_dns.list` —— 第二DNS服务器域名列表（`reason195.duckdns.org`，dnsmasq 侧，经 223.5.5.5 解析真实 IP）。
- **已删除** `openclash_custom_fake_filter.list` / `openclash_custom_domain_dns_policy.list` —— 包自带模板文件（luci-app-openclash 自带），旧方案残留；相关开关 `custom_fakeip_filter`/`custom_name_policy` 已关闭（包默认 0），不再烘焙以冻结模板。

---

## 三、固件开箱行为（编译刷机后）

1. **DNS**：dnsmasq 缓存按方案禁用（cachesize 0）；备用上游 223.5.5.5 / 119.29.29.29 / 2400:3200::1 自动就位；clash 异常时全屋 DNS 不中断（严格模式下正常时仍 100% 走 clash fake-ip）；`reason195.duckdns.org` 返回真实 IP（第二 DNS）。
2. **DDNS**：开机即向 DuckDNS 上报公网 IPv6（PPPoE 重拨自动跟进）。
3. **远程访问**：外网 `ssh root@reason195.duckdns.org` 与 `https://reason195.duckdns.org` 可用（防火墙已放行 v6）。
4. **HTTPS**：开机先用自签证书过渡，~90 秒后后台签发正式 LE 证书并自动切换，浏览器无告警；每日自动续期，失败推送 ntfy 告警。
5. **DNS-rebind**：`cn.ntp.org.cn` 等含内网 IP 的域名已放行，局域网 NTP 对时不再被误拦。
6. **首次开机自动更新**：等 OpenClash 启动完成、科学上网可用后，后台自动更新 GEO 数据库（GeoIP/GeoSite/ASN/Country）、大陆白名单（chnroute v4/v6）与面板版本（Zashboard / Metacubexd）；任一步失败下次开机自动重试，全部成功后不再重复（标记 `/etc/.openclash-bootstrap-done`，日志 `/tmp/first_boot_download.log`）。

---

## 四、GitHub Secrets 注入机制（2026-08-12 新增）

敏感值不再入库，改为**占位符 + CI 构建时注入**：

| Secret | 注入位置 | 说明 |
|---|---|---|
| `PPPOE_USERNAME` / `PPPOE_PASSWORD` | `Files/etc/config/network` | PPPoE 拨号账号密码 |
| `DDNS_TOKEN` | `Files/etc/config/ddns` + `Files/etc/config/acme` | DuckDNS token（两处同步） |
| `HP_ADDRESS` / `HP_UUID` | `Files/etc/config/homeproxy` | VLESS 节点地址 / UUID（address/tls_sni/ws_host 三处共用 HP_ADDRESS） |
| `MAIN_AIRPORT_SUB` / `BACKUP_AIRPORT_SUB` | `Scripts/Handles.sh`（构建时写入 MihomoPro.yaml） | 机场主 / 备用订阅地址（YYDS 模板中的「优质订阅源」「备用订阅源」占位符） |
| `ROUTER_ROOT_PASSWORD` | `Files/etc/shadow` | 生成 SHA-256 crypt 哈希（`openssl passwd -5`，与 OpenWrt `$5$` 格式一致）写入 root 行 |

**工作机制**：
- `Files/` 内以 `@@SECRET_NAME@@` 占位符替代明文；`Scripts/Settings.sh` 拷贝 `Files/` 后调用 `inject_secret()`（python3 字面替换，无正则/转义陷阱）注入；root 密码单独生成哈希写 shadow。
- 任何必需 secret **未设置时构建直接失败**（exit 1），且注入后有占位符残留检查——绝不产出带占位符的坏固件。
- `QCA-ALL.yml` 调用 `WRT-CORE.yml` 时 `secrets: inherit`，secrets 以环境变量传入。
- 已用含特殊字符（`&`/`|`/`\`）的密码在本地完整模拟注入流程验证：所有位置替换正确、无残留、shadow 行 9 字段格式完整。

---

## 五、注意事项

- **敏感信息**：全部敏感值已通过 GitHub Secrets 注入，仓库内无明文（`Files/etc/shadow` 保留出厂 root 密码哈希作为兜底，构建时被 `ROUTER_ROOT_PASSWORD` 覆盖）。请确保仓库为私有。
- **account_email**：已与路由器实时状态同步为 `reason195@gmail.com`（Let's Encrypt 到期提醒会发到该邮箱，非敏感值保留明文）。
- **仓库与路由器一致性**：已逐文件比对同步；`ddns`/`acme`/`network`/`system`/`rc.local` 与路由器实时状态字节级一致。`dhcp` 与 live 仅选项顺序差异（功能等价）；`crontabs/root` 未烧入 `coremark` 行（该包安装时自行添加）。
- **配置简化重构**（本次新增）：已用路由器本地 apk 仓库提取的同版本包默认配置，在隔离 UCI 环境（`uci -c` 包装器）中对 4 个 uci-defaults 脚本做了端到端验证——基线为纯包默认（`DirectInterface=lan`、`redirect_https=0`、wan `forward=REJECT`、`log_level=0`），运行后全部正确应用，`enable` 保持默认 0（避免空配置空转），`dns_servers` 等默认内容原样保留。
- **关于烘焙的凭据**：`Files/etc/dropbear/*_host_key` 仍烘焙了 SSH 主机密钥（每台用同一固件的设备共享同一套主机密钥）。如担心固件分发后的安全（同密钥可互信 MITM），建议删除——dropbear 首启会自动重新生成。root 密码已由 `ROUTER_ROOT_PASSWORD` secret 在构建时覆盖，刷机后为 secret 值。
- **OpenClash 升级后**：`disable_masq_cache=1` 是按方案设定的期望状态（cachesize 0）。若后续版本/设置把它改回 0，cachesize 会回升——此时确认是否仍符合方案意图。
- **自动更新说明**：配置本体（MihomoPro.yaml）是手动 YAML 路径，无订阅条目，无法自动更新；更新配置需手动在 OpenClash 中重新获取或重新编译固件（GEO/GeoIP/白名单数据库已每周自动更新）。
- **ntfy 订阅**：`https://ntfy.sh/buffy-reason195-cert`（网页直接订阅，或手机 App）。仅失败/临期时推送，不会刷屏。
- **IPv4 仍是 CGNAT**：外网访问依赖 IPv6，客户端需有 IPv6（手机蜂窝网络默认支持）。
