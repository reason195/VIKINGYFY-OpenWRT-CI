"""校验 Files/ 里不会出现「非占位符的裸 @@」——CI 的残留检查用 grep -rl "@@"，
任何注释里写了两个 @ 都会导致固件构建失败（26.11.22 实机事故：
Files/etc/config/tailscale 的注释里写了「@@ 占位符」，injected 成功后仍报
「仍有未替换的占位符残留」而构建失败）。

规则：Files/ 里每一处 @@ 都必须是一个完整的 @@NAME@@ 占位符，且 NAME 由
Settings.sh 的 inject_secret 处理（test_secret_wiring 覆盖）。
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "Files"


class PlaceholderSyntaxTest(unittest.TestCase):
    def test_no_stray_double_at(self):
        stray = []
        for path in FILES.rglob("*"):
            if not path.is_file():
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            # 去掉所有合法的 @@NAME@@ 后，剩余文本不应含 @@
            cleaned = re.sub(r"@@[A-Z0-9_]+@@", "", text)
            if "@@" in cleaned:
                for i, line in enumerate(text.splitlines(), 1):
                    if "@@" in re.sub(r"@@[A-Z0-9_]+@@", "", line):
                        stray.append(f"{path.relative_to(ROOT)}:{i}: {line.strip()[:80]}")
        self.assertEqual(stray, [], "发现非占位符的裸 @@（会导致 CI 残留检查失败）")


if __name__ == "__main__":
    unittest.main()
