"""校验随镜像发布的 OpenClash 覆写模块与首启登记脚本。

模块是纯文本 INI 三段格式（16-overwrite-module-format.md §16.2），这里只做结构校验，
避免把 YAML 解析器带进构建依赖；YAML 段用 PyYAML 解析（缺失则跳过）。
"""
import re
import shutil
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "Files/etc/openclash/overwrite/OC_SelfHeal_AntiLeak"
DEFAULTS = ROOT / "Files/etc/uci-defaults/93-buffy-openclash.sh"


class OverwriteModuleTest(unittest.TestCase):
    def setUp(self):
        self.text = MODULE.read_text(encoding="utf-8")

    def test_meta_header(self):
        self.assertTrue(self.text.startswith("#!NAME = OC_SelfHeal_AntiLeak"))
        self.assertIn("#!DESC = ", self.text)
        self.assertIn("#!CONFIG = all", self.text)

    def test_required_sections(self):
        for header in ("[General]", "[YAML]"):
            self.assertRegex(self.text, r"(?m)^" + re.escape(header) + r"\s*$")

    def test_general_keys(self):
        match = re.search(r"(?ms)^\[General\]\s*$", self.text)
        self.assertIsNotNone(match)
        general = re.split(r"(?m)^\[", self.text[match.end():])[0]
        for key in ("ENABLE_RESPECT_RULES", "APPEND_WAN_DNS"):
            self.assertRegex(general, r"(?m)^" + key + r"\s*=")
        # 主路由保留 IPv6：模块若写这两个键会把 IPv6 出口/DNS 关掉
        self.assertNotIn("IPV6_ENABLE", general)
        self.assertNotIn("IPV6_DNS", general)

    def test_yaml_block(self):
        try:
            import yaml
        except ImportError:  # pragma: no cover - 构建机无 PyYAML 时跳过
            self.skipTest("PyYAML not installed")
        match = re.search(r"(?ms)^\[YAML\]\s*$", self.text)
        self.assertIsNotNone(match)
        data = yaml.safe_load(self.text[match.end():])
        # 主路由保留 IPv6：不得在 YAML 段关掉 dns.ipv6（旁路由才关）
        self.assertNotIn("dns", data)
        provider = data["proxy-providers*"]["set"]
        self.assertEqual(provider["interval"], 3600)
        self.assertEqual(provider["health-check"]["interval"], 180)
        self.assertEqual(provider["health-check"]["timeout"], 5000)
        self.assertEqual(provider["health-check"]["lazy"], False)
        self.assertEqual(provider["health-check"]["expected-status"], 204)
        group = data["<proxy-groups>*"]
        self.assertEqual(group["where"]["type"], "/^(url-test|fallback|load-balance)$/")
        self.assertEqual(group["set"]["interval"], 180)
        self.assertEqual(group["set"]["timeout"], 5000)
        self.assertEqual(group["set"]["lazy"], False)
        self.assertEqual(group["set"]["expected-status"], 204)
        self.assertEqual(group["set"]["empty-fallback"], "DIRECT")

    def test_registered_by_uci_defaults(self):
        script = DEFAULTS.read_text(encoding="utf-8")
        self.assertIn("OC_SelfHeal_AntiLeak", script)
        self.assertIn("enable=1", script)
        self.assertIn("config_overwrite", script)
        # filter_aaaa_dns 是 openclash init 的内部还原标记，uci-defaults 写它会
        # 触发 revert_dnsmasq() 把 dhcp.filter_aaaa 清空；本机保留 IPv6，不能碰。
        self.assertNotRegex(script, r"(?m)^uci set openclash\.config\.filter_aaaa_dns")
        # 主路由保留 IPv6：ipv6_enable / ipv6_dns 不得被关
        self.assertNotRegex(script, r"(?m)^uci set openclash\.config\.ipv6_(enable|dns)='0'")

    def test_shell_syntax(self):
        sh = shutil.which("sh")
        if not sh:  # pragma: no cover
            self.skipTest("requires a POSIX shell")
        import subprocess
        result = subprocess.run([sh, "-n", str(DEFAULTS)], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())


if __name__ == "__main__":
    unittest.main()