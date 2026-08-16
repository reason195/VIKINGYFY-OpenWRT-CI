#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# upgrade_firmware.py — 一键下载 GitHub latest release 的 sysupgrade 固件、校验 sha256、sysupgrade 刷入。
#
# 用法：
#   python3 Scripts/upgrade_firmware.py                     # 默认 192.168.1.1 root/root，保留配置升级
#   python3 Scripts/upgrade_firmware.py --dry-run           # 只下载+校验，不连路由器、不刷机
#   python3 Scripts/upgrade_firmware.py --reset --yes       # 重置配置(sysupgrade -n)升级，跳过确认
#   python3 Scripts/upgrade_firmware.py --tag IPQ60XX-WIFI-NO-VIKINGYFY-main-26.08.17-00.13.34
#   ROUTER_HOST=10.0.0.1 ROUTER_PASSWORD=xxx python3 Scripts/upgrade_firmware.py
#
# 依赖：pip install paramiko（同 verify_flash.py，仅本地运行）。release 元数据优先用 gh 拉取
#（避免 GitHub 匿名 API 60 次/小时限流），未安装/未登录时回退匿名 API（可设 GH_TOKEN 提升限额）。
#
# 安全：刷机前校验路由器 board_name 与固件设备段一致；sha256 以 GitHub 资产 digest 为准，
# 下载后本地校验 + 上传后路由器侧 sha256sum 双重校验，任一不一致即中止，绝不强行刷入。

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

import paramiko

try:
    sys.stdout.reconfigure(encoding="utf-8")  # 避免 Windows GBK 控制台崩溃
except Exception:
    pass

DEFAULT_REPO = "reason195/VIKINGYFY-OpenWRT-CI"
DEFAULT_TAG_PREFIX = "IPQ60XX-WIFI-NO-"
DEFAULT_DEVICE = "jdcloud_re-cs-07"  # release 资产文件名中的设备段
DEFAULT_BOARD = "jdcloud,re-cs-07"   # 路由器 /tmp/sysinfo/board_name

UA = "upgrade_firmware.py"


def log(msg=""):
    print(msg, flush=True)


def progress(msg):
    sys.stdout.write("\r" + msg)
    sys.stdout.flush()


def fetch_releases(repo):
    """拉取最近的 release 列表（优先 gh，回退匿名 API）。"""
    if shutil.which("gh"):
        try:
            r = subprocess.run(
                ["gh", "api", f"repos/{repo}/releases?per_page=10"],
                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30,
            )
            if r.returncode == 0 and (r.stdout or "").strip():
                return json.loads(r.stdout)
            log(f"[warn] gh api 失败（rc={r.returncode}），回退匿名 API：{r.stderr.strip()[:160]}")
        except Exception as ex:
            log(f"[warn] 无法调用 gh，回退匿名 API：{ex}")
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    req = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/releases?per_page=10",
        headers={"Accept": "application/vnd.github+json", "User-Agent": UA},
    )
    if token:
        req.add_header("Authorization", f"token {token}")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def pick_asset(releases, tag, tag_prefix, device):
    """按（可选）指定 tag 或前缀 + 设备段挑选 sysupgrade 资产。"""
    for rel in releases:
        name = rel.get("tag_name") or ""
        if tag and name != tag:
            continue
        if not tag and not name.startswith(tag_prefix):
            continue
        for a in rel.get("assets", []):
            an = a["name"]
            if an.endswith(".bin") and device in an and "sysupgrade" in an:
                return rel, a
    return None, None


def parse_digest(asset):
    """GitHub 资产 digest 形如 sha256:<hex>，取出小写 hex；缺失返回 None。"""
    m = re.fullmatch(r"sha256:([0-9a-fA-F]{64})", (asset.get("digest") or "").strip())
    return m.group(1).lower() if m else None


def download(url, dest, retries=3):
    """流式下载并返回本地 sha256；Content-Length 存在时打印进度。"""
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    last_err = None
    for attempt in range(1, retries + 1):
        h = hashlib.sha256()
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                total = int(r.headers.get("Content-Length") or 0)
                done = 0
                last_mark = 0
                with open(dest, "wb") as f:
                    while True:
                        chunk = r.read(256 * 1024)
                        if not chunk:
                            break
                        f.write(chunk)
                        h.update(chunk)
                        done += len(chunk)
                        if total and (done - last_mark >= 1024 * 1024 or done >= total):
                            last_mark = done
                            progress(f"  下载中 {done/1048576:.1f}/{total/1048576:.1f} MB ({100*done/total:.0f}%)")
                log("")
            return h.hexdigest().lower()
        except Exception as ex:
            last_err = ex
            log(f"  [warn] 第 {attempt} 次下载失败：{ex}")
            if attempt < retries:
                time.sleep(2)
    raise RuntimeError(f"下载失败（重试 {retries} 次后）：{last_err}")


def ssh_run(cli, cmd, timeout=30):
    _, out, err = cli.exec_command(cmd, timeout=timeout)
    return out.read().decode("utf-8", "replace").strip(), err.read().decode("utf-8", "replace").strip()


def connect(host, user, password):
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(host, username=user, password=password, timeout=10, banner_timeout=10, auth_timeout=10)
    return cli


def upload(sftp, local, remote):
    total = os.path.getsize(local)
    state = {"done": 0, "mark": 0}

    def cb(sent, _total):
        state["done"] = sent
        if sent - state["mark"] >= 1024 * 1024 or sent >= total:
            state["mark"] = sent
            progress(f"  上传中 {sent/1048576:.1f}/{total/1048576:.1f} MB ({100*sent/total:.0f}%)")

    sftp.put(local, remote, callback=cb)
    log("")


def trigger_sysupgrade(cli, remote, reset):
    """后台触发 sysupgrade（nohup 防 SSH 断开 SIGHUP），随后读取其日志。"""
    flag = "-n " if reset else ""
    cmd = f"nohup sysupgrade {flag}{remote} >/tmp/sysupgrade.log 2>&1 &"
    try:
        _, _, _ = cli.exec_command(cmd, timeout=10)
    except Exception:
        pass  # 后台执行，通道立即返回
    time.sleep(3)
    try:
        o, _ = ssh_run(cli, "cat /tmp/sysupgrade.log 2>/dev/null", timeout=10)
        return o
    except Exception as ex:
        return f"(SSH 已断开，升级应已进入刷写阶段：{ex})"


def router_uptime(cli):
    """读 /proc/uptime 首字段（秒）。"""
    o, _ = ssh_run(cli, "cat /proc/uptime 2>/dev/null", timeout=10)
    try:
        return float(o.split()[0])
    except Exception:
        return None


def wait_for_reboot(host, user, password, uptime_before, timeout):
    """轮询 SSH 直到路由器重启完成（新 uptime < 重启前 uptime），返回新 SSHClient；超时返回 None。"""
    deadline = time.time() + timeout
    last_err = "未连接"
    while time.time() < deadline:
        try:
            cli = connect(host, user, password)
            up = router_uptime(cli)
            if uptime_before is None or (up is not None and up < uptime_before):
                return cli
            last_err = f"uptime 未下降（{up} >= {uptime_before}，可能未真正重启）"
            cli.close()
        except Exception as ex:
            last_err = str(ex)
        sys.stdout.write(".")
        sys.stdout.flush()
        time.sleep(5)
    log("")
    log(f"  [warn] 最后状态：{last_err}")
    return None


def wait_for_boot_selfcheck(host, user, password, timeout):
    """轮询 /tmp/boot_selfcheck.log 直到开机自检完成（PASS/FAIL/跳过）；超时返回 None。

    开机自检由 rc.local 延迟 120s 拉起，核心/代理 204 各可等 5 分钟，最长约 12 分钟；
    复验前等它结束，避免刚重启时 OpenClash 进程/端口/204 尚未就绪造成运行时状态误报。
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        o = ""
        try:
            cli = connect(host, user, password)
            o, _ = ssh_run(cli, "cat /tmp/boot_selfcheck.log 2>/dev/null", timeout=10)
            cli.close()
        except Exception:
            pass
        if "boot_selfcheck: PASS" in o:
            return "PASS"
        if "boot_selfcheck: FAIL" in o:
            return "FAIL"
        if any(k in o for k in ("跳过自检", "未检测到 OpenClash 配置", "已手动停用")):
            return "跳过"
        sys.stdout.write(".")
        sys.stdout.flush()
        time.sleep(10)
    log("")
    return None


def run_verify(host, user, password):
    """以环境变量传凭据（避免出现在 argv），子进程运行 verify_flash.py 并透传输出。"""
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "verify_flash.py")
    if not os.path.isfile(script):
        log(f"[warn] 找不到 {script}，跳过复验")
        return -1
    env = dict(os.environ)
    env.update({"ROUTER_HOST": host, "ROUTER_USER": user, "ROUTER_PASSWORD": password})
    return subprocess.run([sys.executable, script], env=env).returncode


def main():
    ap = argparse.ArgumentParser(description="一键下载 GitHub latest release 固件并 sysupgrade 刷入")
    ap.add_argument("--host", default=os.environ.get("ROUTER_HOST", "192.168.1.1"))
    ap.add_argument("--user", default=os.environ.get("ROUTER_USER", "root"))
    ap.add_argument("--password", default=os.environ.get("ROUTER_PASSWORD", "root"))
    ap.add_argument("--repo", default=os.environ.get("UPGRADE_REPO", DEFAULT_REPO))
    ap.add_argument("--tag-prefix", default=DEFAULT_TAG_PREFIX, help="release 标签前缀（默认 IPQ60XX-WIFI-NO-）")
    ap.add_argument("--tag", default=None, help="指定 release 标签（默认取最新匹配前缀的 release）")
    ap.add_argument("--device", default=DEFAULT_DEVICE, help="release 资产文件名中的设备段")
    ap.add_argument("--board", default=DEFAULT_BOARD, help="路由器 /tmp/sysinfo/board_name（刷机前校验）")
    ap.add_argument("--reset", action="store_true", help="sysupgrade -n：不保留配置（重新应用固件内置配置）")
    ap.add_argument("--yes", action="store_true", help="跳过刷机确认")
    ap.add_argument("--dry-run", action="store_true", help="只下载+校验 sha256，不连路由器、不刷机")
    ap.add_argument("--wait-timeout", type=int, default=300, help="重启等待上限（秒，默认 300）")
    ap.add_argument("--selfcheck-timeout", type=int, default=720, help="开机自检等待上限（秒，默认 720）")
    ap.add_argument("--no-verify", action="store_true", help="刷机后不等待重启、不运行 verify_flash.py 复验")
    args = ap.parse_args()

    log(f"== 查询 {args.repo} 最新 release ==")
    try:
        releases = fetch_releases(args.repo)
    except urllib.error.HTTPError as ex:
        log(f"ERROR: 拉取 release 失败：HTTP {ex.code}（匿名 API 可能被限流，请安装并登录 gh，或设 GH_TOKEN）")
        return 2
    rel, asset = pick_asset(releases, args.tag, args.tag_prefix, args.device)
    if not rel:
        log(f"ERROR: 未找到匹配的 release（tag 前缀 {args.tag_prefix}，设备段 {args.device}）")
        return 2
    expected = parse_digest(asset)
    if not expected:
        log("ERROR: 该资产无 GitHub digest（sha256），无法校验，拒绝刷入。请改用 --tag 指定带 digest 的 release")
        return 2

    log(f"  release : {rel['tag_name']}")
    log(f"  资产    : {asset['name']} ({asset['size']/1048576:.1f} MB)")
    log(f"  sha256  : {expected}")

    if args.dry_run:
        log("\n== 下载并校验 sha256（dry-run，不刷机） ==")
    else:
        log("\n== 连接路由器并校验设备 ==")
        try:
            cli = connect(args.host, args.user, args.password)
        except Exception as ex:
            log(f"ERROR: SSH 连接失败：{ex}")
            return 2
        board, _ = ssh_run(cli, "cat /tmp/sysinfo/board_name 2>/dev/null")
        log(f"  路由器 board_name: {board}")
        if board != args.board:
            log(f"ERROR: 设备不匹配（期望 {args.board}，实际 {board}），拒绝刷入！")
            cli.close()
            return 1

    with tempfile.TemporaryDirectory(prefix="fwupgrade-") as tmp:
        local = os.path.join(tmp, asset["name"])
        if not args.dry_run:
            log("\n== 下载固件 ==")
        try:
            got = download(asset["browser_download_url"], local)
        except Exception as ex:
            log(f"ERROR: {ex}")
            return 1
        log(f"  本地 sha256: {got}")
        if got != expected:
            log("ERROR: 本地 sha256 与 GitHub digest 不一致，已丢弃，拒绝刷入！")
            return 1
        log("✅ sha256 校验通过")

        if args.dry_run:
            flag = "-n " if args.reset else ""
            log(f"\n[dry-run] 将执行：sysupgrade {flag}/tmp/fw-upgrade.bin（{'重置' if args.reset else '保留'}配置）")
            log("[dry-run] 未连接路由器、未刷机。去掉 --dry-run 即可一键升级。")
            return 0

        log("\n== 上传固件到路由器 /tmp ==")
        sftp = cli.open_sftp()
        remote = "/tmp/fw-upgrade.bin"
        try:
            # 空间检查：/tmp 为 tmpfs，需留 10MB 余量
            avail, _ = ssh_run(cli, "df -m /tmp | awk 'NR==2{print $4}'")
            try:
                if int(avail) < asset["size"] // 1048576 + 10:
                    log(f"ERROR: /tmp 可用空间不足（{avail}MB），需 {asset['size']//1048576 + 10}MB")
                    return 1
            except ValueError:
                pass  # 读不到可用空间时跳过，上传自然失败会报错
            upload(sftp, local, remote)
        finally:
            sftp.close()
        rsha, _ = ssh_run(cli, f"sha256sum {remote}")
        rsha = rsha.split()[0].lower() if rsha else ""
        log(f"  路由器侧 sha256: {rsha}")
        if rsha != expected:
            log("ERROR: 路由器侧 sha256 不一致，已中止，未刷机！")
            return 1
        log("✅ 路由器侧 sha256 校验通过")

        log("\n== 刷机 ==")
        log(f"  命令: sysupgrade {'-n ' if args.reset else ''}{remote}")
        log("  说明: " + ("重置配置（-n），重刷后重新应用固件内置配置" if args.reset else "保留当前配置升级（不重新应用固件内置配置）"))
        if not args.yes:
            ans = input("  确认刷机？路由器将重启并断网约 1-3 分钟 [y/N]: ").strip().lower()
            if ans not in ("y", "yes"):
                log("已取消。")
                return 0
        uptime_before = router_uptime(cli)
        log("  触发 sysupgrade ...")
        out = trigger_sysupgrade(cli, remote, args.reset)
        if out:
            log(out)
        cli.close()

        if args.no_verify:
            log("\n✅ 已触发刷机，路由器重启中。已跳过重启等待与复验（--no-verify）。")
            return 0

        log(f"\n== 等待路由器重启（最长 {args.wait_timeout}s） ==")
        new_cli = wait_for_reboot(args.host, args.user, args.password, uptime_before, args.wait_timeout)
        if new_cli is None:
            log("❌ 等待重启超时，路由器尚未上线；请稍后手动运行 verify_flash.py 复验。")
            return 1
        board, _ = ssh_run(new_cli, "cat /tmp/sysinfo/board_name 2>/dev/null")
        log(f"✅ 路由器已重启上线（board_name={board}）")
        new_cli.close()

        log(f"\n== 等待 OpenClash 开机自检完成（最长 {args.selfcheck_timeout}s） ==")
        sc = wait_for_boot_selfcheck(args.host, args.user, args.password, args.selfcheck_timeout)
        if sc is None:
            log("⚠️ 等待自检超时，继续复验（运行时状态可能尚未就绪，仅供提示）")
        else:
            log(f"✅ 开机自检完成：{sc}")

        log("\n== 复验一致性：verify_flash.py ==")
        rc = run_verify(args.host, args.user, args.password)
        if rc == 0:
            log("\n✅ 刷机完成，固件一致性复验通过。")
        else:
            log(f"\n⚠️ verify_flash.py 退出码 {rc}，存在不一致项，请查看上方输出。")
        return rc
    return 0


if __name__ == "__main__":
    sys.exit(main())
