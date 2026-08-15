#!/bin/sh
# cert_check.sh - Let's Encrypt 证书健康检查与失败告警
# 每日运行（cron 20 0 * * *）：
#   - 证书缺失：尝试签发；连续失败 >=3 次推送告警
#   - 证书临期（<=14 天）：尝试续期；续期失败推送告警
# 告警通道：Telegram（token/chat_id 由构建 Secret 注入，见 /etc/buffy-notify.conf）。

. /usr/share/buffy/lib-buffy.sh

DOMAIN="reason195.duckdns.org"
LEAF="/etc/acme/${DOMAIN}_ecc/${DOMAIN}.cer"
FULLCHAIN="/etc/ssl/acme/${DOMAIN}.fullchain.crt"
KEY="/etc/ssl/acme/${DOMAIN}.key"
FAIL_CNT_FILE="/tmp/acme_fail_count"
RENEW_WINDOW=1209600   # 14 天（秒）

mkdir -p /etc/ssl/acme 2>/dev/null

if [ ! -f "$LEAF" ]; then
	# 证书缺失：尝试签发
	/etc/init.d/acme renew >/tmp/acme_renew.log 2>&1
	if [ ! -f "$LEAF" ]; then
		CNT=$(( $(cat $FAIL_CNT_FILE 2>/dev/null || echo 0) + 1 ))
		echo $CNT > $FAIL_CNT_FILE
		if [ $CNT -ge 3 ]; then
			notify "LE证书签发失败($CNT次)" "$DOMAIN 证书连续 $CNT 次签发失败。请检查网络 / DuckDNS Token / acme 日志（/tmp/acme_renew.log）。"
		fi
		exit 1
	fi
	rm -f $FAIL_CNT_FILE
	# 签发成功：切换 uhttpd 到 LE 证书
	uci set uhttpd.main.cert="$FULLCHAIN"
	uci set uhttpd.main.key="$KEY"
	uci commit uhttpd
	/etc/init.d/uhttpd restart >/dev/null 2>&1
	notify "LE证书已签发" "$DOMAIN 已获取 Let's Encrypt 证书并启用 HTTPS（有效期 90 天，每日自动续期）。"
	exit 0
fi

# 已有证书：临期（<=14 天）则尝试续期
if cert_expires_within "$LEAF" "$RENEW_WINDOW"; then
	/etc/init.d/acme renew >/tmp/acme_renew.log 2>&1
	if cert_expires_within "$LEAF" "$RENEW_WINDOW"; then
		notify "LE证书即将过期" "$DOMAIN 证书剩余 <=14 天，自动续期失败。详情见 /tmp/acme_renew.log。"
	fi
else
	echo "cert_check: $DOMAIN 证书有效（剩余 >14 天），状态正常。"
fi
exit 0
