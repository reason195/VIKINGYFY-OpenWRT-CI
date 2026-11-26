#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
"""把机场订阅域名补进 OpenClash 的 fake-ip-filter 与 nameserver-policy。

刷机用 sysupgrade -n 会清空 proxy_provider 缓存，首启必须重新拉订阅。
proxy-providers 用 proxy: DIRECT 拉取：订阅域名若被 fake-ip 解析成 198.18.x.x，
DIRECT 必然 EOF；即使返回真实 IP，若解析走 nameserver（境外 DoH，respect-rules 下
经代理出口），代理没启动时同样解析不了。两种都是「代理起不来 → 拉不到订阅」的死锁。

订阅域名随机场更换，硬编码必然漏。构建期（Scripts/Handles.sh 注入订阅后）从
MihomoPro.yaml 的 proxy-providers 段提取 URL 主机名，补进两个列表；文件里已有的
条目（含父域覆盖，如 +.de5.net 覆盖 sub.de5.net）不重复添加。脚本幂等。

用法：
    python3 Scripts/openclash_sub_domains.py <MihomoPro.yaml> <fake_filter.list> <dns_policy.list>
"""

import ipaddress
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

DNS_SERVERS = ("https://doh.pub/dns-query", "https://dns.alidns.com/dns-query")
FAKE_APEX = re.compile(r"^\s*\+\.([A-Za-z0-9_.-]+)\s*(?:#.*)?$", re.M)
POLICY_APEX = re.compile(r"\+\.([A-Za-z0-9_.-]+)")


def subscription_hosts(yaml_path):
    """提取 proxy-providers 段内 url 的主机名；不依赖 PyYAML（构建机未必安装）。"""
    hosts = []
    in_providers = False
    for line in yaml_path.read_text(encoding="utf-8").splitlines():
        if not in_providers:
            if re.match(r"^proxy-providers:\s*$", line):
                in_providers = True
            continue
        # 回到顶层即离开 proxy-providers 段
        if line and not line[0].isspace():
            break
        m = re.search(r"\burl:\s*[\"']?([^\"'\s]+)", line)
        if not m:
            continue
        host = urlsplit(m.group(1)).hostname
        if not host or "." not in host or host == "localhost":
            continue
        try:
            ipaddress.ip_address(host)
            continue  # IP 字面量不受 DNS 影响
        except ValueError:
            pass
        if host not in hosts:
            hosts.append(host)
    return hosts


def covered(host, domains):
    """host 是否已被某个域名条目覆盖（自身或父域）。"""
    return any(host == d or host.endswith("." + d) for d in domains)


def covered_in_fake_filter(text):
    return [m.group(1).rstrip(".") for m in FAKE_APEX.finditer(text)]


def covered_in_dns_policy(text):
    return [m.group(1).rstrip(".") for m in POLICY_APEX.finditer(text)]


def append(path, block):
    with path.open("a", encoding="utf-8") as fh:
        fh.write(block)


def main(argv):
    if len(argv) != 4:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        print(f"用法: {argv[0]} <MihomoPro.yaml> <fake_filter.list> <dns_policy.list>", file=sys.stderr)
        return 2

    yaml_path, fake_path, policy_path = (Path(p) for p in argv[1:])
    if not yaml_path.is_file():
        print(f"WARN: 找不到 {yaml_path}，跳过订阅域名推导（静态列表兜底）", file=sys.stderr)
        return 0
    for p in (fake_path, policy_path):
        if not p.is_file():
            print(f"ERROR: 找不到 {p}", file=sys.stderr)
            return 1

    hosts = subscription_hosts(yaml_path)
    if not hosts:
        print("WARN: MihomoPro.yaml 的 proxy-providers 段没有解析到订阅域名，跳过（静态列表兜底）")
        return 0

    fake_text = fake_path.read_text(encoding="utf-8")
    fake_new = [h for h in hosts if not covered(h, covered_in_fake_filter(fake_text))]
    if fake_new:
        lines = ["", "# 构建期自动追加：MihomoPro.yaml proxy-providers 的订阅域名（见 Scripts/openclash_sub_domains.py）"]
        lines += [f"+.{h}" for h in fake_new]
        append(fake_path, "\n".join(lines) + "\n")
        print("fake-ip-filter 追加: " + ", ".join(fake_new))

    policy_text = policy_path.read_text(encoding="utf-8")
    policy_new = [h for h in hosts if not covered(h, covered_in_dns_policy(policy_text))]
    if policy_new:
        key = ",".join(f"+.{h}" for h in policy_new)
        block = ["", "# 构建期自动追加：订阅域名走国内 DoH 直连，避免“代理未启动 → 解析不了 → 拉不到订阅”的死锁"]
        block.append(f'"{key}":')
        block += [f"  - {server}" for server in DNS_SERVERS]
        append(policy_path, "\n".join(block) + "\n")
        print("nameserver-policy 追加: " + ", ".join(policy_new))

    if not fake_new and not policy_new:
        print("订阅域名均已覆盖，无需追加")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
