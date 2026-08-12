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
- **修正（2026-08-12）**：此前误用 `custom_name_policy`（nameserver-policy，clash DNS 引擎层）实现近似效果——那不是方案内容，且经实测在 0.47.156 下**未真正生效**（运行 yaml 无 nameserver-policy 段、无 reason195 条目）。已改回方案对应的 dnsmasq 侧开关，并关闭 `custom_name_policy`/`custom_fakeip_filter`（包默认即为 0）。
- **GeoIP Dat**：`enable_geoip_dat` 0→**1**。
- **清理 Fallback 组**：禁用 `dns.google/dns-query`、`dns.cloudflare.com/dns-query`（方案要求无 fallback，非直连域名交远端解析）。
- **自动更新**：GEO/GeoIP/白名单数据库自动更新本就开启（每周，满足方案要求）；**配置本体的自动更新不适用**——当前是手动 YAML 路径（无订阅条目），方案三选一中的自动更新需改为订阅转换/覆写模块，为避免重蹈断网覆辙未切换。
- 全程带备份（`/root/bak-buffy/`）分步验证，未出现断网；重启后直连域名正常解析、代理域名仍 fake-ip、代理出口仍马来西亚。
- 说明：clash DNS 的 `ipv6: false`（方案在出站不支持 IPv6 时的标准做法）会过滤 AAAA——局域网内用域名访问路由器时只拿到 A 记录（DuckDNS 服务器地址），请直接使用 `192.168.1.1`；外网访问不受影响（手机用自己的 DNS 解析 AAAA）。

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
| `crontabs/root` | 新增：00:00 续期 / 00:05 重载 uhttpd / 00:20 证书检查告警 |

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
- 开机 ~90 秒后台触发证书自愈（首次开机即尝试签发 LE 证书）。

### 新增脚本
- `Files/usr/share/buffy/cert_check.sh` —— 证书健康检查 + ntfy 告警（见上）。
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
