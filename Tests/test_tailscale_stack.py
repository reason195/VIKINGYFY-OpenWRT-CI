"""Tailscale 整套（官方包 + 社区面板 + fw4 SNAT + 首启补丁）的静态一致性校验。"""
import re
import shutil
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "Files/etc/config/tailscale"
SNAT = ROOT / "Files/etc/fw4-ts-snat.sh"
FIX = ROOT / "Files/etc/uci-defaults/96-tailscale-panel-fix.sh"
GENERAL = ROOT / "Config/GENERAL.txt"
SETTINGS = ROOT / "Scripts/Settings.sh"
CORE = ROOT / ".github/workflows/WRT-CORE.yml"
ALL = ROOT / ".github/workflows/QCA-ALL.yml"


def uci_options(text):
    """把 UCI 配置拆成 {option: value}（只关心 option/list 行）。"""
    values = {}
    for line in text.splitlines():
        m = re.match(r"\s*(option|list)\s+(\S+)\s+'([^']*)'", line)
        if m:
            key, value = m.group(2), m.group(3)
            values[key] = (values[key] + " " + value) if key in values else value
    return values


class TailscaleStackTest(unittest.TestCase):
    def test_uci_config(self):
        cfg = uci_options(CONFIG.read_text(encoding="utf-8"))
        # accept_dns 必须是 0：接受 100.100.100.100 会绕过 dnsmasq/OpenClash 分流
        self.assertEqual(cfg["enabled"], "1")
        self.assertEqual(cfg["accept_dns"], "0")
        self.assertEqual(cfg["config_path"], "/etc/tailscale")
        self.assertEqual(cfg["fw_mode"], "nftables")
        # 主路由 LAN 段，不能抄旁路由/其他网段
        self.assertEqual(cfg["advertise_routes"], "192.168.1.0/24")
        # 节点名显式写死，避免 owrt-1 这类后缀
        self.assertEqual(cfg["hostname"], "owrt-main")
        self.assertIn("tag:router", cfg["flags"])
        self.assertEqual(cfg["authkey"], "@@TAILSCALE_AUTHKEY@@")

    def test_snat_script(self):
        text = SNAT.read_text(encoding="utf-8")
        self.assertTrue(text.startswith("#!/bin/sh"))
        self.assertIn("inet fw4 srcnat", text)
        self.assertIn('oifname "br-lan"', text)
        self.assertIn("100.64.0.0/10 masquerade", text)
        # 幂等：已存在则不加第二条
        self.assertIn("grep -q '100.64.0.0/10 masquerade' && exit 0", text)
        mode = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-s", "Files/etc/fw4-ts-snat.sh"],
                              capture_output=True, text=True).stdout.split()
        if mode:
            self.assertEqual(mode[0], "100755", "fw4 include 由 fw4 直接执行，必须带执行位")

    def test_first_boot_patch(self):
        text = FIX.read_text(encoding="utf-8")
        # 没装面板时不得报错（只是跳过）
        self.assertIn("[ -x /usr/sbin/tailscale_helper ] || exit 0", text)
        self.assertIn("sed -i '/^exit 0$/d' /usr/sbin/tailscale_helper", text)
        self.assertIn("TS_IP4=", text)
        self.assertIn("uci set firewall.ts_snat=include", text)
        self.assertIn("/etc/fw4-ts-snat.sh", text)
        self.assertIn('"/sbin/logread": [ "read" ]', text)
        self.assertNotIn("bypass_gateway", text)
        for script in (SNAT, FIX):
            result = subprocess.run([shutil.which("sh"), "-n", str(script)], capture_output=True)
            self.assertEqual(result.returncode, 0, script.name)

    def test_packages_and_secret_wiring(self):
        general = GENERAL.read_text(encoding="utf-8")
        for pkg in ("CONFIG_PACKAGE_tailscale=y", "CONFIG_PACKAGE_luci-app-tailscale=y",
                    "CONFIG_PACKAGE_luci-i18n-tailscale-zh-cn=y"):
            self.assertIn(pkg, general)
        # 占位符必须全链路接线，否则构建期留空/报错
        self.assertIn('inject_secret "TAILSCALE_AUTHKEY"', SETTINGS.read_text(encoding="utf-8"))
        core = CORE.read_text(encoding="utf-8")
        self.assertIn("TAILSCALE_AUTHKEY:", core)
        self.assertIn("TAILSCALE_AUTHKEY: ${{secrets.TAILSCALE_AUTHKEY}}", core)
        self.assertIn("TAILSCALE_AUTHKEY: ${{secrets.TAILSCALE_AUTHKEY}}", ALL.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
