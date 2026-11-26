"""校验 Secrets 接线完整性：Files/ 里的每个 @@XXX@@ 占位符必须四层齐全。

背景（26.11.19 实机事故）：给 WRT-CORE.yml 加了 workflow_call.secrets 声明和
Custom Settings 步骤的 env，却漏了调用方 QCA-ALL.yml 的 secrets 映射——可复用
workflow 只接收调用方显式传递的 secret，结果 TAILSCALE_AUTHKEY 在构建里是空值，
Settings.sh 打印「未配置可选 Secret …占位符置空」，固件里的引导脚本拿到空密钥，
刷机后 Tailscale 不会自动登录。构建本身成功、无任何报错，只能靠日志发现。

四层：
  1. QCA-ALL.yml 调用 WRT-CORE 时的 secrets 映射（调用方显式传递）
  2. WRT-CORE.yml on.workflow_call.secrets 声明
  3. WRT-CORE.yml Custom Settings 步骤 env（传给 Settings.sh）
  4. Scripts/Settings.sh 的 inject_secret 调用

纯文本解析，不引入 YAML 依赖。
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CALLER = ROOT / ".github/workflows/QCA-ALL.yml"
CORE = ROOT / ".github/workflows/WRT-CORE.yml"
SETTINGS = ROOT / "Scripts/Settings.sh"


def placeholders():
    found = set()
    for path in (ROOT / "Files").rglob("*"):
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue  # 二进制文件（如 dropbear 密钥）跳过
        found.update(re.findall(r"@@([A-Z0-9_]+)@@", text))
    return found


def section(text, start_pattern, end_pattern):
    """截取 start_pattern 之后、end_pattern 之前的文本（按行匹配）。"""
    start = re.search(start_pattern, text, re.M)
    if not start:
        return ""
    rest = text[start.end():]
    end = re.search(end_pattern, rest, re.M)
    return rest[: end.start()] if end else rest


class SecretWiringTest(unittest.TestCase):
    def setUp(self):
        self.names = placeholders()
        self.assertTrue(self.names, "Files/ 里应至少有一个占位符")
        self.caller = CALLER.read_text(encoding="utf-8")
        self.core = CORE.read_text(encoding="utf-8")
        self.settings = SETTINGS.read_text(encoding="utf-8")

    def assertPass(self, block, name):
        self.assertNotEqual(block, "", "未能定位到对应的 YAML 区块")
        self.assertRegex(
            block,
            rf"(?m)^\s*{name}:\s*\$\{{\{{secrets\.{name}\}}\}}\s*$",
            f"{name} 未在该区块显式传递",
        )

    def test_caller_passes_secret(self):
        block = section(self.caller,
                        r"uses:\s*\./\.github/workflows/WRT-CORE\.yml",
                        r"^    with:")
        block = section(block, r"^    secrets:\s*$", r"^    [a-z]")
        for name in sorted(self.names):
            with self.subTest(secret=name):
                self.assertPass(block, name)

    def test_core_declares_secret(self):
        block = section(self.core, r"^    secrets:\s*$", r"^permissions:")
        for name in sorted(self.names):
            with self.subTest(secret=name):
                self.assertNotEqual(block, "", "未找到 workflow_call.secrets 区块")
                self.assertRegex(block, rf"(?m)^\s+{name}:\s*$",
                                 f"{name} 未在 workflow_call.secrets 声明")

    def test_core_step_env_passes_secret(self):
        block = section(self.core, r"-\s*name:\s*Custom Settings", r"^      - name:")
        block = section(block, r"^        env:\s*$", r"^      - name:")
        for name in sorted(self.names):
            with self.subTest(secret=name):
                self.assertPass(block, name)

    def test_settings_injects_secret(self):
        for name in sorted(self.names):
            with self.subTest(secret=name):
                self.assertIn(f'inject_secret "{name}"', self.settings)


if __name__ == "__main__":
    unittest.main()
