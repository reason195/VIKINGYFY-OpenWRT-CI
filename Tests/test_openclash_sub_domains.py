import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Scripts/openclash_sub_domains.py"
FAKE = ROOT / "Files/etc/openclash/custom/openclash_custom_fake_filter.list"
POLICY = ROOT / "Files/etc/openclash/custom/openclash_custom_domain_dns_policy.list"

CONFIG = """\
mixed-port: 7890
proxy-providers:
  优质服务商:
    type: http
    url: https://m1.tohno-0.top/api/v1/client/subscribe?token=abc
    interval: 3600
  备用服务商:
    type: http
    url: "https://sub.reason195.de5.net/sub/starter2026/mihomo.yaml"
  relay:
    type: http
    url: http://192.0.2.10/sub
  local:
    type: file
    path: ./proxy_provider/local.yaml
rules:
  - IP-CIDR,198.18.0.0/16,DIRECT
rule-providers:
  rule:
    type: http
    behavior: domain
    url: https://rules.example.net/rule.mrs
"""


class SubscriptionDomainTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="oc-subdom-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.yaml = self.tmp / "MihomoPro.yaml"
        self.yaml.write_text(CONFIG, encoding="utf-8")
        self.fake = self.tmp / "fake.list"
        self.policy = self.tmp / "policy.list"
        self.fake.write_text(FAKE.read_text(encoding="utf-8"), encoding="utf-8")
        self.policy.write_text(POLICY.read_text(encoding="utf-8"), encoding="utf-8")

    def run_script(self):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(self.yaml), str(self.fake), str(self.policy)],
            capture_output=True, text=True, timeout=20,
        )

    def test_static_lists_cover_current_airport(self):
        """静态兜底必须含本次事故的机场域名，防止有人改回只有 aisaka。"""
        for path in (FAKE, POLICY):
            text = path.read_text(encoding="utf-8")
            self.assertIn("+.tohno-0.top", text, path)
            self.assertIn("+.de5.net", text, path)

    @staticmethod
    def _parse_policy_entries(text):
        """解析 nameserver-policy 非注释行为 [(keys, servers), ...]，保持原始键序。"""
        entries = []
        current_servers = None
        for raw in text.splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if not raw[0].isspace() and line.endswith(":"):
                key = line[:-1].strip().strip('"\'')
                keys = tuple(k.strip() for k in key.split(",") if k.strip())
                current_servers = []
                entries.append((keys, current_servers))
            elif line.startswith("- ") and current_servers is not None:
                current_servers.append(line[2:].strip().strip('"\''))
        return entries

    @staticmethod
    def _matches_policy_key(host, pattern):
        if pattern.startswith("+."):
            suffix = pattern[2:]
            return host == suffix or host.endswith("." + suffix)
        return host == pattern

    def test_google_play_policy_precedes_geosite_cn(self):
        """Google Play 下载/跳转域名必须排在 geosite:cn 之前并走境外 DoH。"""
        entries = self._parse_policy_entries(POLICY.read_text(encoding="utf-8"))
        cn_idx = next(
            (i for i, (keys, _) in enumerate(entries) if "geosite:cn" in keys),
            None,
        )
        self.assertIsNotNone(cn_idx, "缺少 geosite:cn 策略条目")
        for host in (
            "services.googleapis.cn",
            "googleapis.cn",
            "redirector.xn--ngstr-lra8j.com",
            "redirector.gvt1.com",
            "dl.google.com",
        ):
            hit = next(
                (
                    (i, servers)
                    for i, (keys, servers) in enumerate(entries)
                    if any(self._matches_policy_key(host, k) for k in keys)
                ),
                None,
            )
            self.assertIsNotNone(hit, f"{host} 未命中任何 nameserver-policy 规则")
            idx, servers = hit
            self.assertLess(idx, cn_idx, f"{host} 必须位于 geosite:cn 之前")
            self.assertIn("https://dns.cloudflare.com/dns-query", servers)
            self.assertIn("https://dns.google/dns-query", servers)

    def test_extracts_only_proxy_provider_hosts(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        fake = self.fake.read_text(encoding="utf-8")
        policy = self.policy.read_text(encoding="utf-8")
        # 静态列表已覆盖 tohno-0.top / de5.net，不应重复追加
        self.assertEqual(fake.count("+.tohno-0.top"), 1)
        self.assertEqual(fake.count("+.de5.net"), 1)
        self.assertEqual(policy.count("+.tohno-0.top"), 1)
        self.assertEqual(policy.count("+.de5.net"), 1)
        # rule-providers / rules 段的域名不是订阅源，不得混入
        self.assertNotIn("rules.example.net", fake)
        self.assertNotIn("rules.example.net", policy)
        # IP 与 file provider 不产生条目
        self.assertNotIn("192.0.2.10", fake)
        self.assertNotIn("192.0.2.10", policy)

    def test_appends_new_airport_and_is_idempotent(self):
        self.fake.write_text("+.github.com\n", encoding="utf-8")
        self.policy.write_text('"geosite:cn":\n  - https://doh.pub/dns-query\n', encoding="utf-8")

        first = self.run_script()
        self.assertEqual(first.returncode, 0, first.stderr)
        fake = self.fake.read_text(encoding="utf-8")
        policy = self.policy.read_text(encoding="utf-8")
        self.assertIn("+.m1.tohno-0.top", fake)
        self.assertIn("+.sub.reason195.de5.net", fake)
        self.assertIn("+.m1.tohno-0.top", policy)
        self.assertIn("+.sub.reason195.de5.net", policy)

        second = self.run_script()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.fake.read_text(encoding="utf-8"), fake)
        self.assertEqual(self.policy.read_text(encoding="utf-8"), policy)
        self.assertIn("无需追加", second.stdout)

    def test_parent_domain_covers_child(self):
        self.fake.write_text("+.tohno-0.top\n+.de5.net\n", encoding="utf-8")
        self.policy.write_text('"+.tohno-0.top,+.de5.net":\n  - https://doh.pub/dns-query\n', encoding="utf-8")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.fake.read_text(encoding="utf-8"), "+.tohno-0.top\n+.de5.net\n")
        self.assertEqual(
            self.policy.read_text(encoding="utf-8"),
            '"+.tohno-0.top,+.de5.net":\n  - https://doh.pub/dns-query\n',
        )

    def test_no_proxy_providers_is_non_fatal(self):
        self.yaml.write_text("mixed-port: 7890\n", encoding="utf-8")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WARN", result.stdout + result.stderr)

    def test_missing_config_is_non_fatal(self):
        self.yaml.unlink()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WARN", result.stderr)


if __name__ == "__main__":
    unittest.main()
