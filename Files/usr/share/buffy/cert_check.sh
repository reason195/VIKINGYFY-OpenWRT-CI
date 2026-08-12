#!/bin/sh
# cert_check.sh - Let's Encrypt 证书健康检查与失败告警
# 每日运行（cron 20 0 * * *）：
#   - 证书缺失：尝试签发；连续失败 >=3 次推送告警
#   - 证书 <14 天：尝试续期；续期失败推送告警
# 告警通道：ntfy.sh（手机 App / 网页可订阅）。改 NTFY 变量即可切换 Bark / ServerChan 等。

DOMAIN="reason195.duckdns.org"
LEAF="/etc/acme/${DOMAIN}_ecc/${DOMAIN}.cer"
FULLCHAIN="/etc/ssl/acme/${DOMAIN}.fullchain.crt"
KEY="/etc/ssl/acme/${DOMAIN}.key"
NTFY="https://ntfy.sh/buffy-reason195-cert"
FAIL_CNT_FILE="/tmp/acme_fail_count"

notify() { # $1=标题 $2=正文
	curl -fsS -m 10 -H "Title: $1" -H "Priority: high" -d "$2" "$NTFY" >/dev/null 2>&1
}

days_left() { # $1=cert path, echo 剩余天数
	END=$(openssl x509 -enddate -noout -in "$1" 2>/dev/null | cut -d= -f2- | sed 's/  */ /g; s/ GMT//')
	[ -z "$END" ] && { echo 0; return; }
	EPOCH=$(date -u -D "%b %e %T %Y" -d "$END" +%s 2>/dev/null)
	[ -z "$EPOCH" ] && { echo 0; return; }
	echo $(( (EPOCH - $(date +%s)) / 86400 ))
}

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

# 已有证书：检查剩余天数，临期则尝试续期
LEFT=$(days_left "$LEAF")
if [ "$LEFT" -lt 14 ]; then
	/etc/init.d/acme renew >/tmp/acme_renew.log 2>&1
	LEFT2=$(days_left "$LEAF")
	if [ "$LEFT2" -lt 14 ]; then
		notify "LE证书即将过期" "$DOMAIN 证书剩余 ${LEFT2} 天，自动续期失败。详情见 /tmp/acme_renew.log。"
	fi
else
	echo "cert_check: $DOMAIN 证书剩余 $LEFT 天，状态正常。"
fi
exit 0
