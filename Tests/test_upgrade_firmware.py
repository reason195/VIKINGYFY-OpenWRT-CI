#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_upgrade_firmware.py — upgrade_firmware.py 的离线单测。
# 只 mock GitHub API / SSH / 下载 / 时间，不发真实网络请求、不连路由器。
#
# 运行：python3 -m unittest discover -s Tests -p 'test_*.py' -v
#   或：python3 Tests/test_upgrade_firmware.py

import hashlib
import os
import sys
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Scripts"))

import upgrade_firmware as uf  # noqa: E402


def make_asset(name, digest=None, size=1):
    a = {"name": name, "size": size, "browser_download_url": "https://x/" + name}
    if digest:
        a["digest"] = digest
    return a


def make_releases():
    return [
        {
            "tag_name": "IPQ60XX-WIFI-NO-VIKINGYFY-main-26.08.17-00.13.34",
            "assets": [
                make_asset("qualcommax-ipq60xx-jdcloud_re-cs-07-squashfs-factory-26.08.17.bin",
                           "sha256:" + "a" * 64),
                make_asset("qualcommax-ipq60xx-jdcloud_re-cs-07-squashfs-sysupgrade-26.08.17.bin",
                           "sha256:" + "b" * 64),
            ],
        },
        {
            "tag_name": "IPQ60XX-WIFI-NO-VIKINGYFY-main-26.08.15-21.46.59",
            "assets": [
                make_asset("qualcommax-ipq60xx-jdcloud_re-cs-07-squashfs-sysupgrade-26.08.15.bin",
                           "sha256:" + "c" * 64),
            ],
        },
        {
            "tag_name": "OTHER-CONFIG-VIKINGYFY-main-26.08.17-00.13.34",
            "assets": [
                make_asset("some-other-device-sysupgrade.bin", "sha256:" + "d" * 64),
            ],
        },
    ]


class PickAssetTest(unittest.TestCase):
    def test_picks_sysupgrade_of_latest_matching_release(self):
        rel, a = uf.pick_asset(make_releases(), None, "IPQ60XX-WIFI-NO-", "jdcloud_re-cs-07")
        self.assertEqual(rel["tag_name"], "IPQ60XX-WIFI-NO-VIKINGYFY-main-26.08.17-00.13.34")
        self.assertIn("sysupgrade", a["name"])
        self.assertNotIn("factory", a["name"])

    def test_respects_explicit_tag(self):
        rel, a = uf.pick_asset(make_releases(), "IPQ60XX-WIFI-NO-VIKINGYFY-main-26.08.15-21.46.59",
                                "IPQ60XX-WIFI-NO-", "jdcloud_re-cs-07")
        self.assertIn("26.08.15", a["name"])

    def test_returns_none_when_no_match(self):
        self.assertEqual(uf.pick_asset(make_releases(), None, "NOPE-", "jdcloud_re-cs-07"), (None, None))
        self.assertEqual(uf.pick_asset(make_releases(), None, "IPQ60XX-WIFI-NO-", "nonexistent_device"), (None, None))


class ParseDigestTest(unittest.TestCase):
    def test_valid_lowercase(self):
        d = "sha256:" + "ab" * 32
        self.assertEqual(uf.parse_digest({"digest": d}), "ab" * 32)

    def test_uppercase_is_normalized(self):
        d = "sha256:" + "AB" * 32
        self.assertEqual(uf.parse_digest({"digest": d}), "ab" * 32)

    def test_invalid_or_missing(self):
        self.assertIsNone(uf.parse_digest({"digest": "md5:" + "ab" * 32}))
        self.assertIsNone(uf.parse_digest({"digest": "sha256:short"}))
        self.assertIsNone(uf.parse_digest({"digest": ""}))
        self.assertIsNone(uf.parse_digest({}))


class FakeResponse:
    def __init__(self, data):
        self._buf = data
        self.headers = {"Content-Length": str(len(data))}

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self, n=-1):
        if n is None or n < 0 or n >= len(self._buf):
            out, self._buf = self._buf, b""
        else:
            out, self._buf = self._buf[:n], self._buf[n:]
        return out


class DownloadTest(unittest.TestCase):
    def test_sha256_matches_streamed_content(self):
        data = b"hello firmware " * 100000
        with patch.object(uf.urllib.request, "urlopen", return_value=FakeResponse(data)):
            got = uf.download("https://x/fw.bin", os.path.join(os.environ.get("TEMP", "/tmp"), "fw-test.bin"))
        self.assertEqual(got, hashlib.sha256(data).hexdigest())

    def test_retries_then_succeeds(self):
        data = b"payload"
        with patch.object(uf.time, "sleep", return_value=None), \
             patch.object(uf.urllib.request, "urlopen",
                          side_effect=[RuntimeError("boom"), FakeResponse(data)]) as mock_urlopen:
            got = uf.download("https://x/fw.bin", os.path.join(os.environ.get("TEMP", "/tmp"), "fw-test2.bin"))
        self.assertEqual(got, hashlib.sha256(data).hexdigest())
        self.assertEqual(mock_urlopen.call_count, 2)


class WaitForRebootTest(unittest.TestCase):
    def test_returns_immediately_on_uptime_drop(self):
        with patch.object(uf.time, "sleep", return_value=None), \
             patch.object(uf, "connect", return_value=MagicMock()), \
             patch.object(uf, "router_uptime", return_value=10.0):
            cli = uf.wait_for_reboot("h", "u", "p", uptime_before=100.0, timeout=30)
        self.assertIsNotNone(cli)

    def test_polls_until_uptime_drops(self):
        mock_connect = MagicMock(return_value=MagicMock())
        with patch.object(uf.time, "sleep", return_value=None), \
             patch.object(uf, "connect", mock_connect), \
             patch.object(uf, "router_uptime", side_effect=[200.0, 200.0, 5.0]) as mock_uptime:
            cli = uf.wait_for_reboot("h", "u", "p", uptime_before=100.0, timeout=30)
        self.assertIsNotNone(cli)
        self.assertEqual(mock_uptime.call_count, 3)
        self.assertEqual(mock_connect.call_count, 3)

    def test_times_out_returning_none(self):
        with patch.object(uf.time, "sleep", return_value=None), \
             patch.object(uf, "connect", return_value=MagicMock()), \
             patch.object(uf, "router_uptime", return_value=200.0), \
             patch.object(uf.time, "time", side_effect=[0.0, 5.0, 1e9]):
            cli = uf.wait_for_reboot("h", "u", "p", uptime_before=100.0, timeout=10)
        self.assertIsNone(cli)

    def test_fallback_when_uptime_unknown(self):
        with patch.object(uf.time, "sleep", return_value=None), \
             patch.object(uf, "connect", return_value=MagicMock()), \
             patch.object(uf, "router_uptime", return_value=None):
            cli = uf.wait_for_reboot("h", "u", "p", uptime_before=None, timeout=30)
        self.assertIsNotNone(cli)


class WaitForBootSelfcheckTest(unittest.TestCase):
    def _run(self, log_text, side_effect=None):
        with patch.object(uf.time, "sleep", return_value=None), \
             patch.object(uf, "connect", return_value=MagicMock()), \
             patch.object(uf, "ssh_run", side_effect=side_effect or [(log_text, "")]):
            return uf.wait_for_boot_selfcheck("h", "u", "p", 30)

    def test_detects_pass(self):
        self.assertEqual(self._run("controller ready\n=== boot_selfcheck: PASS ==="), "PASS")

    def test_detects_fail(self):
        self.assertEqual(self._run("ERROR: proxy 204\n=== boot_selfcheck: FAIL ==="), "FAIL")

    def test_detects_skip(self):
        self.assertEqual(self._run("OpenClash 已手动停用（enable=0），跳过自检"), "跳过")

    def test_times_out_returning_none(self):
        with patch.object(uf.time, "sleep", return_value=None), \
             patch.object(uf, "connect", return_value=MagicMock()), \
             patch.object(uf, "ssh_run", return_value=("still running", "")), \
             patch.object(uf.time, "time", side_effect=[0.0, 5.0, 1e9]):
            self.assertIsNone(uf.wait_for_boot_selfcheck("h", "u", "p", 30))


class RunVerifyTest(unittest.TestCase):
    def test_passes_env_and_returns_rc(self):
        with patch.object(uf.os.path, "isfile", return_value=True), \
             patch.object(uf.subprocess, "run", return_value=MagicMock(returncode=0)) as mock_run:
            rc = uf.run_verify("1.2.3.4", "root", "s3cret")
        self.assertEqual(rc, 0)
        argv, kwargs = mock_run.call_args
        self.assertNotIn("s3cret", argv[0])  # 密码不得出现在 argv
        self.assertEqual(kwargs["env"]["ROUTER_HOST"], "1.2.3.4")
        self.assertEqual(kwargs["env"]["ROUTER_USER"], "root")
        self.assertEqual(kwargs["env"]["ROUTER_PASSWORD"], "s3cret")

    def test_missing_script_returns_minus1(self):
        with patch.object(uf.os.path, "isfile", return_value=False):
            self.assertEqual(uf.run_verify("h", "u", "p"), -1)


if __name__ == "__main__":
    unittest.main()
