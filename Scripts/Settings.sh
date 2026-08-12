#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#移除luci-app-attendedsysupgrade
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
#添加编译日期标识
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	#修改WIFI名称
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
	#修改WIFI密码
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
elif [ -f "$WIFI_UC" ]; then
	#修改WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#修改WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#引入私有扩展配置
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	echo "Applying private configurations from PRIVATE.txt..."
	cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
fi

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#无WIFI配置标志
if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
	echo "WRT_WIFI=wifi-no" >> $GITHUB_ENV
fi

#高通平台调整
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#无WIFI配置调整Q6大小
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi
fi

#引入自定义文件（路由器配置覆盖，合并进固件根文件系统）
if [ -d "$GITHUB_WORKSPACE/Files" ]; then
	echo "Copying custom files to rootfs overlay..."
	mkdir -p ./files
	cp -rf $GITHUB_WORKSPACE/Files/. ./files/
	#敏感文件权限修正（git 只保留可执行位，需恢复 0600）
	chmod 600 ./files/etc/shadow ./files/etc/ppp/chap-secrets 2>/dev/null
	chmod 600 ./files/etc/dropbear/*_host_key 2>/dev/null
fi

#==== 敏感配置注入（GitHub Secrets，占位符见 Files/ 内 @@XXX@@）====
#注：未设置的 secret 会直接中断构建，避免产出带占位符的坏固件
inject_secret() {
	local PLACEHOLDER="$1" VALUE="$2"
	[ -n "$VALUE" ] || { echo "ERROR: 缺少必需的 GitHub Secret: $PLACEHOLDER（请在仓库 Settings → Secrets 中配置）"; exit 1; }
	# 用 python3 做字面替换（无正则/转义陷阱，密码可含任意特殊字符）
	PLACEHOLDER="$PLACEHOLDER" VALUE="$VALUE" python3 - <<'PYEOF'
import os, pathlib
ph = os.environ["PLACEHOLDER"]
val = os.environ["VALUE"]
for p in pathlib.Path("./files").rglob("*"):
    if not p.is_file():
        continue
    try:
        s = p.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        continue  # 二进制文件（如 dropbear 密钥）跳过
    if ("@@" + ph + "@@") in s:
        p.write_text(s.replace("@@" + ph + "@@", val), encoding="utf-8")
        print(f"injected {ph} -> {p}")
PYEOF
}

inject_secret "PPPOE_USERNAME" "$PPPOE_USERNAME"
inject_secret "PPPOE_PASSWORD" "$PPPOE_PASSWORD"
inject_secret "DDNS_TOKEN" "$DDNS_TOKEN"
inject_secret "HP_ADDRESS" "$HP_ADDRESS"
inject_secret "HP_UUID" "$HP_UUID"

#root 密码：生成 crypt 哈希写入 shadow（与 OpenWrt 默认 $5$ 格式一致）
if [ -n "$ROUTER_ROOT_PASSWORD" ]; then
	ROOT_HASH=$(openssl passwd -5 "$ROUTER_ROOT_PASSWORD")
	if [ -n "$ROOT_HASH" ]; then
		python3 - "$ROOT_HASH" <<'PYEOF'
import sys, pathlib
h = sys.argv[1]
p = pathlib.Path("./files/etc/shadow")
s = p.read_text(encoding="utf-8")
out = []
for line in s.splitlines():
    if line.startswith("root:"):
        parts = line.split(":")
        # parts[0]=root, parts[1]=旧哈希, parts[2:]=:20646:0:99999:7:::
        out.append("root:" + h + ":" + ":".join(parts[2:]))
    else:
        out.append(line)
p.write_text("\n".join(out) + "\n", encoding="utf-8")
print("injected ROUTER_ROOT_PASSWORD -> shadow")
PYEOF
	fi
else
	echo "ERROR: 缺少必需的 GitHub Secret: ROUTER_ROOT_PASSWORD（请在仓库 Settings → Secrets 中配置）"
	exit 1
fi

#残留占位符检查（应无输出）
LEFT=$(grep -rl "@@" ./files/ 2>/dev/null)
if [ -n "$LEFT" ]; then
	echo "ERROR: 仍有未替换的占位符残留于: $LEFT"
	exit 1
fi

echo "Secrets injected successfully!"
