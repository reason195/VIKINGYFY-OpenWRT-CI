#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# verify_flash.py — 校验已刷入路由器的固件与本仓库 Files/ 的一致性（含 secret 脱敏）。
#
# 用法：
#   python3 Scripts/verify_flash.py                     # 默认 192.168.1.1 root/root
#   python3 Scripts/verify_flash.py --host 10.0.0.1 --user admin --password xxxx
#   ROUTER_HOST=... ROUTER_USER=... ROUTER_PASSWORD=... python3 Scripts/verify_flash.py
#
# 依赖：pip install paramiko（仅在本地运行，不会被编译进固件）。
#
# 比对逻辑：
#   1. 固件一致性：把 Files/ 下每个文件与路由器 /rom（只读出厂层）比对。
#      - 含 @@SECRET@@ 占位符的文件做脱敏比对（占位符匹配任意值【含空注入】，并检查无占位符泄漏）；
#      - 构建期会与包默认合并/追加的文件（shadow）按「本地内容须按序出现在路由器中」比对；
#      - uci-defaults 脚本首启即被消费，跳过（改由运行时 uci 状态体现）；
#      - 其余文件逐字节比对（CRLF/LF 归一化）；
#      - git 索引为 100755 的文件额外校验路由器 /rom 侧执行位（Windows 工作区读不到真实
#        权限位，故以 git 索引为准；曾因 644 烤入固件导致 proxy_watch cron 静默失败）。
#   2. 运行时漂移：/etc 与 /rom 的差异仅作提示（openclash/apk 会改写运行时文件，属正常）。
#   3. 关键运行时状态：OpenClash 核心/规则集/DNS/防火墙等抽查。
#
# 退出码：0 = 固件一致性全部通过；1 = 存在不一致（运行时漂移不计入）。

import argparse
import os
import re
import subprocess
import sys

import paramiko

try:
    sys.stdout.reconfigure(encoding="utf-8")  # 避免 Windows GBK 控制台崩溃
except Exception:
    pass

SECRET_RE = re.compile(r"@@[A-Z0-9_]+@@")

# 首启即被 uci-defaults 消费，路由器上不存在（一致性由运行时 uci 状态体现）
SKIP_ON_ROUTER = {
    "etc/uci-defaults/90-buffy-dropbear.sh",
    "etc/uci-defaults/91-buffy-uhttpd.sh",
    "etc/uci-defaults/92-buffy-firewall.sh",
    "etc/uci-defaults/93-buffy-openclash.sh",
}

# 构建期会与软件包默认配置合并/追加的文件：路由器上可能多出重复块或追加的包用户行。
# 比对方式退化为「本地每一行须按序出现在路由器文件中」（见 line_subset）。
MERGE_FILES = {
    "etc/shadow",  # 构建时追加 avahi/ntp/dbus/dnsmasq/logd/sing-box/ubus 等包用户
}


def norm(b: bytes) -> bytes:
    return b.replace(b"\r\n", b"\n")


def local_bytes(files_dir: str, rel: str) -> bytes:
    with open(os.path.join(files_dir, rel), "rb") as f:
        return f.read()


def router_bytes(sftp, path: str):
    try:
        with sftp.open(path, "rb") as f:
            return f.read()
    except IOError:
        return None


def git_index_mode(files_dir: str, rel: str):
    """读 git 索引记录的文件模式（Windows 工作区读不到真实权限位）；不在 git 仓库或未跟踪时返回 None。"""
    try:
        out = subprocess.run(
            ["git", "-C", os.path.dirname(files_dir), "ls-files", "-s", "--", f"Files/{rel}"],
            capture_output=True, text=True, timeout=15,
        ).stdout.strip()
        return out.split()[0] if out else None
    except Exception:
        return None


def mask_root_hash(line: str) -> str:
    """把 shadow root 行的密码哈希字段替换为固定 token（两侧同步，密码由 secret 注入，不可比对）。"""
    if line.startswith("root:"):
        parts = line.split(":")
        if len(parts) > 1:
            parts[1] = "HASH"
        return ":".join(parts)
    return line


def line_subset(local_lines, router_lines) -> bool:
    """local 是否按序出现在 router 中（允许 router 多出额外行，用于合并文件比对）。"""
    it = iter(router_lines)
    return all(any(line == r for r in it) for line in local_lines)


def compare_secret(local_text: str, router_text: str):
    """脱敏比对：占位符匹配任意值（含空——可选 secret 未配置时构建期置空）；额外检查路由器侧无 @@ 残留。"""
    pat = "^" + SECRET_RE.sub(r".*?", re.escape(local_text)) + "$"
    if re.search(pat, router_text, re.DOTALL):
        return "OK" if "@@" not in router_text else "FAIL(占位符泄漏)"
    return "FAIL(结构不一致)"


def compare_file(sftp, files_dir: str, rel: str):
    lb = norm(local_bytes(files_dir, rel))
    rb = router_bytes(sftp, "/rom/" + rel)
    if rb is None:
        return "SKIP(路由器无此文件)", f"路由器出厂层不存在 /rom/{rel}"
    rb = norm(rb)

    if rel in MERGE_FILES:
        lt = lb.decode("utf-8", "replace").split("\n")
        rt = rb.decode("utf-8", "replace").split("\n")
        if rel == "etc/shadow":
            lt = [mask_root_hash(x) for x in lt]
            rt = [mask_root_hash(x) for x in rt]
        if line_subset(lt, rt):
            extra = len(rt) - len(lt)
            return "OK(合并)", f"本地 {len(lt)} 行全部就位" + (f"，路由器多 {extra} 行（包默认追加）" if extra > 0 else "")
        missing = [x for x in lt if x not in rt]
        return "FAIL(合并)", "缺失行: " + " | ".join(x[:60] for x in missing[:5])

    lt = lb.decode("utf-8", "replace")
    rt = rb.decode("utf-8", "replace")

    if SECRET_RE.search(lt):
        status = compare_secret(lt, rt)
        return status, "secret 占位符已注入、结构一致" if status == "OK" else ""

    if lb == rb:
        return "OK", "逐字节一致"

    for i, (a, b) in enumerate(zip(lb, rb)):
        if a != b:
            return "FAIL(内容差异)", f"首个差异 @字节 {i}: 本地={lb[max(0,i-24):i+24]!r} 路由器={rb[max(0,i-24):i+24]!r}"
    return "FAIL(长度差异)", f"本地 {len(lb)} 字节 vs 路由器 {len(rb)} 字节"


def run(cli, cmd, timeout=15):
    try:
        _, out, err = cli.exec_command(cmd, timeout=timeout)
        return out.read().decode("utf-8", "replace").strip(), err.read().decode("utf-8", "replace").strip()
    except Exception as ex:
        return "", f"EXEC-ERR: {ex}"


def uci_dump(cli, config):
    """解析 `uci show <config>` 输出为 key -> value（多值 list 项返回 list）。"""
    out, _ = run(cli, f"uci show {config} 2>/dev/null", timeout=20)
    d = {}
    for line in out.splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        vals = re.findall(r"'([^']*)'", v)
        d[k] = vals if len(vals) > 1 else (vals[0] if vals else v)
    return d


def find_named_section(d, type_prefix, name):
    """按 name 选项定位匿名段（如 firewall rule/zone），返回段 key（含索引）。"""
    for k, v in d.items():
        m = re.match(rf"^{re.escape(type_prefix)}\[(\d+)\]\.name$", k)
        if m and v == name:
            return f"{type_prefix}[{m.group(1)}]"
    return None


RUNTIME_CHECKS = [
    ("固件版本", "cat /etc/openwrt_release"),
    ("内核", "uname -a"),
    ("OpenClash 关键项", "uci show openclash 2>/dev/null | grep -E 'en_mode|operation_mode|redirect_dns|enable_respect_rules|core_type|core_version|github_address_mod|enable_geoip_dat|enable_custom_domain_dns_server|custom_domain_dns_server|skip_proxy_address|disable_masq_cache|custom_fakeip_filter|china_ip_route|log_level|enable=|config_path'"),
    ("核心与规则集", "ls -la /etc/openclash/core/clash_meta 2>/dev/null; ls /etc/openclash/rule_provider/ 2>/dev/null | wc -l; wc -c /etc/openclash/config/MihomoPro.yaml 2>/dev/null"),
    ("clash 进程与端口", "pidof clash; netstat -tln 2>/dev/null | grep -E ':(9090|7890|7891|7893|7874)'"),
    ("开机自检", "ls -la /etc/.openclash-bootstrap-done 2>/dev/null; cat /tmp/boot_selfcheck.log 2>/dev/null | tail -3"),
    ("dnsmasq 关键项", "uci get dhcp.@dnsmasq[0].cachesize; uci get dhcp.@dnsmasq[0].strictorder; uci get dhcp.@dnsmasq[0].quietdhcp; uci get dhcp.@dnsmasq[0].rebind_domain; cat /tmp/dnsmasq.*.d/60-fallback.conf 2>/dev/null"),
    ("防火墙", "uci show firewall 2>/dev/null | grep -E 'Allow-WAN|flow_offloading|fullcone'"),
    ("uhttpd / DDNS", "uci show uhttpd 2>/dev/null | grep -E 'redirect_https|listen_https'; uci show ddns 2>/dev/null | grep -E 'ip_interface|enabled|lookup_host'"),
    ("运行时 crontab", "cat /etc/crontabs/root 2>/dev/null"),
]


def check_uci_defaults(cli):
    """校验 4 个首启即消费的 uci-defaults 脚本的运行时效果，返回 [(脚本, ok, 详情)]。"""
    results = []

    # 90-buffy-dropbear.sh：解绑 lan 接口，允许经 WAN(IPv6) SSH
    d = uci_dump(cli, "dropbear")
    bound = [k for k in d if "Interface" in k]
    results.append(("90-buffy-dropbear.sh", not bound,
                    "Interface/DirectInterface 已解绑" if not bound else f"仍存在接口绑定: {bound}"))

    # 91-buffy-uhttpd.sh：LuCI 强制 HTTPS（redirect + 监听 443）
    d = uci_dump(cli, "uhttpd")
    rh = d.get("uhttpd.main.redirect_https")
    lh = d.get("uhttpd.main.listen_https")
    if not isinstance(lh, list):
        lh = [lh]
    ok = rh == "1" and "0.0.0.0:443" in lh and "[::]:443" in lh
    results.append(("91-buffy-uhttpd.sh", ok,
                    f"redirect_https={rh!r} listen_https={lh!r}"))

    # 92-buffy-firewall.sh：硬件流卸载 + fullcone6 + wan forward=DROP + WAN v6 放行 SSH/LuCI
    d = uci_dump(cli, "firewall")
    fo = d.get("firewall.@defaults[0].flow_offloading")
    foh = d.get("firewall.@defaults[0].flow_offloading_hw")
    fc6 = d.get("firewall.@defaults[0].fullcone6")
    wan_sec = find_named_section(d, "firewall.@zone", "wan")
    wan_fwd = d.get(f"{wan_sec}.forward") if wan_sec else None
    ssh_sec = find_named_section(d, "firewall.@rule", "Allow-WAN-SSH-v6")
    luci_sec = find_named_section(d, "firewall.@rule", "Allow-WAN-LuCI-v6")
    ssh_ok = bool(ssh_sec and d.get(f"{ssh_sec}.src") == "wan"
                  and d.get(f"{ssh_sec}.family") == "ipv6" and d.get(f"{ssh_sec}.proto") == "tcp"
                  and d.get(f"{ssh_sec}.dest_port") == "22" and d.get(f"{ssh_sec}.target") == "ACCEPT")
    luci_dp = d.get(f"{luci_sec}.dest_port") if luci_sec else None
    luci_ok = bool(luci_sec and d.get(f"{luci_sec}.src") == "wan"
                   and d.get(f"{luci_sec}.family") == "ipv6" and d.get(f"{luci_sec}.proto") == "tcp"
                   and luci_dp and set(luci_dp) == {"80", "443"}
                   and d.get(f"{luci_sec}.target") == "ACCEPT")
    ok = fo == "1" and foh == "1" and fc6 == "1" and wan_fwd == "DROP" and ssh_ok and luci_ok
    results.append(("92-buffy-firewall.sh", ok,
                    f"flow_offloading={fo} hw={foh} fullcone6={fc6} wan.forward={wan_fwd} "
                    f"SSHv6={'✓' if ssh_ok else '✗'} LuCIv6={'✓' if luci_ok else '✗'}"))

    # 93-buffy-openclash.sh：核心/规则/订阅/时刻表/凭据等运行时选项
    d = uci_dump(cli, "openclash")
    expected = {
        "en_mode": "fake-ip", "operation_mode": "fake-ip", "redirect_dns": "1",
        "enable_respect_rules": "1", "log_level": "error", "china_ip_route": "1",
        "core_type": "Meta", "core_version": "linux-arm64",
        "github_address_mod": "https://testingcf.jsdelivr.net/", "enable_geoip_dat": "1",
        "enable_custom_domain_dns_server": "1", "custom_domain_dns_server": "223.5.5.5",
        "custom_fakeip_filter": "1", "skip_proxy_address": "1",
        "enable_meta_sniffer": "1", "enable_meta_sniffer_pure_ip": "1",
        "geo_auto_update": "1", "geoip_auto_update": "1", "geosite_auto_update": "1",
        "geoasn_auto_update": "1", "chnr_auto_update": "1",
        "disable_quic_go_gso": "1", "default_dashboard": "zashboard",
        "chnr_custom_url": "https://ispip.clang.cn/all_cn.txt",
        "chnr6_custom_url": "https://ispip.clang.cn/all_cn_ipv6.txt",
    }
    for name, hour in (("geo", "0"), ("geosite", "2"), ("geoip", "1"), ("geoasn", "3"), ("chnr", "4")):
        expected[f"{name}_update_day_time"] = hour
        expected[f"{name}_update_week_time"] = "1"
    mism = [f"{k}: 期望{v!r}≠实际{d.get('openclash.config.' + k)!r}"
            for k, v in expected.items() if d.get("openclash.config." + k) != v]
    dash_pw = d.get("openclash.config.dashboard_password")
    api_sec = "openclash.@authentication[0]"
    api_en = d.get(f"{api_sec}.enabled")
    api_user = d.get(f"{api_sec}.username")
    api_pw = d.get(f"{api_sec}.password")
    if not dash_pw:
        mism.append("dashboard_password: 为空（应首启随机生成）")
    if api_en != "1" or api_user != "clash" or not api_pw:
        mism.append(f"authentication: enabled={api_en!r} username={api_user!r} password空={not api_pw}")
    creds, _ = run(cli, "cat /etc/openclash-credentials.txt 2>/dev/null", timeout=10)
    if not creds:
        mism.append("/etc/openclash-credentials.txt: 不存在")
    else:
        cred_dash = re.search(r"^dashboard_password: (\S+)$", creds, re.M)
        cred_api = re.search(r"^api_password: (\S+)$", creds, re.M)
        if not cred_dash or cred_dash.group(1) != dash_pw:
            mism.append("credentials 与 uci dashboard_password 不一致")
        if not cred_api or cred_api.group(1) != api_pw:
            mism.append("credentials 与 uci api_password 不一致")
    ok = not mism
    results.append(("93-buffy-openclash.sh", ok, "全部选项一致" if ok else "; ".join(mism[:5])))

    return results


def main():
    ap = argparse.ArgumentParser(description="校验已刷入固件与本仓库 Files/ 的一致性")
    ap.add_argument("--host", default=os.environ.get("ROUTER_HOST", "192.168.1.1"))
    ap.add_argument("--user", default=os.environ.get("ROUTER_USER", "root"))
    ap.add_argument("--password", default=os.environ.get("ROUTER_PASSWORD", "root"))
    ap.add_argument("--files", default=None, help="Files/ 目录路径（默认脚本同级的 ../Files）")
    args = ap.parse_args()

    files_dir = args.files or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Files")
    files_dir = os.path.abspath(files_dir)
    if not os.path.isdir(files_dir):
        print(f"ERROR: 找不到 Files/ 目录: {files_dir}")
        return 2

    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    print(f"== 连接 {args.user}@{args.host} ==")
    try:
        cli.connect(args.host, username=args.user, password=args.password, timeout=10, banner_timeout=10, auth_timeout=10)
    except Exception as ex:
        print(f"ERROR: SSH 连接失败: {ex}")
        return 2
    sftp = cli.open_sftp()

    print("\n===== 1. Files/ vs /rom（固件一致性） =====")
    failures = 0
    for dirpath, _, files in os.walk(files_dir):
        for fn in files:
            rel = os.path.relpath(os.path.join(dirpath, fn), files_dir).replace(os.sep, "/")
            if rel in SKIP_ON_ROUTER:
                print(f"[SKIP] {rel}  (uci-defaults 首启已消费)")
                continue
            status, detail = compare_file(sftp, files_dir, rel)
            # 执行位校验：git 索引 755 的文件，路由器 /rom 侧也必须可执行
            if status.startswith("OK") and git_index_mode(files_dir, rel) == "100755":
                try:
                    if not sftp.stat("/rom/" + rel).st_mode & 0o111:
                        status, detail = "FAIL(无执行位)", "git 索引为 100755，但路由器 /rom 侧不可执行（cron 直接执行会 rc=126 静默失败）"
                except IOError:
                    pass  # /rom 无此文件，内容比对已报告
            mark = "✅" if status.startswith("OK") else "❌"
            print(f"{mark} [{status:<12}] {rel}")
            if detail:
                print(f"        {detail}")
            if not status.startswith("OK"):
                failures += 1

    print("\n===== 2. uci-defaults 运行时效果（首启已消费的脚本） =====")
    for script, ok, detail in check_uci_defaults(cli):
        print(f"{'✅' if ok else '❌'} [{script}] {detail}")
        if not ok:
            failures += 1

    print("\n===== 3. 运行时状态抽查 =====")
    for label, cmd in RUNTIME_CHECKS:
        o, e = run(cli, cmd)
        print(f"--- {label}\n{o}" + (f"\n[stderr] {e}" if e else ""))

    print("\n===== 4. /etc vs /rom（运行时漂移，仅提示） =====")
    for dirpath, _, files in os.walk(files_dir):
        for fn in files:
            rel = os.path.relpath(os.path.join(dirpath, fn), files_dir).replace(os.sep, "/")
            if rel in SKIP_ON_ROUTER:
                continue
            rom, etc = router_bytes(sftp, "/rom/" + rel), router_bytes(sftp, "/" + rel)
            if rom is None:
                continue
            if etc is None:
                print(f"[!] {rel} 出厂有但运行时被删")
            elif norm(rom) != norm(etc):
                print(f"[~] {rel} 运行时与出厂不同（openclash/apk 改写，属正常）")

    sftp.close()
    cli.close()

    print("\n===== 汇总 =====")
    if failures:
        print(f"❌ 固件一致性：{failures} 项不一致（详见第 1/2 节）")
        return 1
    print("✅ 固件一致性：全部通过（Files/ 覆盖层 + uci-defaults 运行时效果）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
