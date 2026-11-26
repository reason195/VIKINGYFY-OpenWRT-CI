"""us_failover.sh 行为校验：死节点切换 / 存活不打扰 / 策略组回切（全部走 mock curl，无网络）。"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Files/usr/share/buffy/us_failover.sh"
CRON = ROOT / "Files/etc/crontabs/root"

AUTO = "%E7%BE%8E%E5%9B%BD%E8%87%AA%E5%8A%A8"
POLICY = "%E7%BE%8E%E5%9B%BD%E7%AD%96%E7%95%A5"

MOCK_CURL = """#!/bin/sh
printf '%s\n' "$*" >> "$SBX/curl.log"
case "$*" in
*"-X PUT"*) printf '204'; exit 0 ;;
*/group/*delay*) cat "$SBX/delay.json"; exit 0 ;;
*@AUTO@*) cat "$SBX/auto.json"; exit 0 ;;
*@POLICY@*) cat "$SBX/policy.json"; exit 0 ;;
esac
exit 22
""".replace("@AUTO@", AUTO).replace("@POLICY@", POLICY)


@unittest.skipUnless(shutil.which("sh"), "requires a POSIX shell")
class UsFailoverTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.sbx = Path(self.tmp.name)
        (self.sbx / "bin").mkdir()
        (self.sbx / "tmp").mkdir()
        self.sandbox("pidof", "#!/bin/sh\nexit 0\n")
        self.sandbox("uci", "#!/bin/sh\nprintf 'panel-pass\\n'\n")
        self.sandbox("curl", MOCK_CURL.replace("$SBX", self.sbx.as_posix()))
        source = SCRIPT.read_text(encoding="utf-8").replace("/tmp/", self.sbx.as_posix() + "/tmp/")
        (self.sbx / "us_failover.sh").write_text(source, encoding="utf-8")
        self.log = self.sbx / "tmp/us_failover.log"

    def tearDown(self):
        self.tmp.cleanup()

    def run_script_file(self):
        # 必须在 sh 启动后再前置 PATH：Git for Windows 的 sh 启动时会把 /ucrt64/bin
        # 等目录插到最前，从进程环境传入的 PATH 会被压到它们后面，mock 的 curl 就输给
        # 系统 curl.exe（本测试只在本地 Windows 上踩到这个坑，Linux CI 无此问题）。
        sh = shutil.which("sh")
        wrapper = ('d=$(cd "$(dirname "$1")" && pwd) || exit 1; '
                   'export PATH="$d/bin:$PATH"; exec sh "$d/us_failover.sh"')
        return subprocess.run([sh, "-c", wrapper, "--", (self.sbx / "us_failover.sh").as_posix()],
                              capture_output=True, timeout=60)

    def sandbox(self, name, text):
        path = self.sbx / "bin" / name
        path.write_text(text, encoding="utf-8")
        path.chmod(0o755)

    def run_script(self, auto_now, auto_all, delay, policy_now=None):
        (self.sbx / "auto.json").write_text(
            '{"now":"%s","all":[%s]}' % (auto_now, ",".join('"%s"' % n for n in auto_all)),
            encoding="utf-8")
        (self.sbx / "delay.json").write_text(delay, encoding="utf-8")
        (self.sbx / "policy.json").write_text(
            '{"now":"%s"}' % (policy_now or auto_now), encoding="utf-8")
        result = self.run_script_file()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        log = self.log.read_text(encoding="utf-8") if self.log.exists() else ""
        puts = [l for l in (self.sbx / "curl.log").read_text(encoding="utf-8").splitlines()
                if "-X PUT" in l]
        return log, puts

    def test_dead_node_switches_to_alive_member(self):
        log, puts = self.run_script("US-1", ["US-1", "US-2", "US-3"],
                                    '{"US-2":120,"US-3":210}', policy_now="US-2")
        self.assertIn("美国自动: 切换 US-1 -> US-2", log)
        self.assertEqual(len(puts), 1)
        self.assertIn('{"name":"US-2"}', puts[0])

    def test_alive_node_untouched(self):
        log, puts = self.run_script("US-2", ["US-1", "US-2"],
                                    '{"US-1":90,"US-2":120}')
        self.assertNotIn("切换", log)
        self.assertEqual(puts, [])

    def test_zero_delay_counts_as_dead(self):
        log, puts = self.run_script("US-1", ["US-1", "US-2"], '{"US-1":0,"US-2":150}')
        self.assertIn("美国自动: 切换 US-1 -> US-2", log)

    def test_policy_pinned_to_dead_us_node_falls_back(self):
        # 美国自动 当前节点存活，但「美国策略」被钉在同样属于美国自动的死节点 US-3 上
        log, puts = self.run_script("US-2", ["US-1", "US-2", "US-3"],
                                    '{"US-2":120,"US-3":0}', policy_now="US-3")
        self.assertIn("美国策略: 节点 US-3 已死，切回 美国自动", log)
        self.assertEqual(len(puts), 1)
        self.assertIn('{"name":"美国自动"}', puts[0])

    def test_policy_on_non_us_node_untouched(self):
        log, puts = self.run_script("US-2", ["US-1", "US-2"], '{"US-2":120}',
                                    policy_now="香港-01")
        self.assertNotIn("美国策略", log)
        self.assertEqual(puts, [])

    def test_missing_group_is_silent(self):
        (self.sbx / "auto.json").write_text('{"msg":"Resource not found"}', encoding="utf-8")
        result = self.run_script_file()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertFalse(self.log.exists())

    def test_static_expectations(self):
        sh = shutil.which("sh")
        self.assertEqual(subprocess.run([sh, "-n", str(SCRIPT)], capture_output=True).returncode, 0)
        text = SCRIPT.read_text(encoding="utf-8")
        for needle in (AUTO, POLICY, "美国自动", "美国策略", 'mkdir "$LOCK"', "pidof clash"):
            self.assertIn(needle, text)
        self.assertIn("* * * * * /usr/share/buffy/us_failover.sh", CRON.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
