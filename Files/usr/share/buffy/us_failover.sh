#!/bin/sh
# 美国线路兜底切换（原旁路由项目 26.11.15 实机：机场 4 个美国节点全掉线后，
# 「美国自动」仍停在已死的节点上，[备] 节点健康却不被选中；「美国策略」被手动钉在
# 死节点上同理）。每分钟由 cron 触发，只改这两个组的选中项，不动订阅、不动规则。
# 核心未运行 / 取不到面板密码 / 订阅里没有这两个组时直接退出。日志：/tmp/us_failover.log
#
# 判断依据只有一条：mihomo 的 /group/<组>/delay 只会为测试成功的节点返回延迟。
# 当前节点不在该结果里（或延迟为 0）即视为死节点。

API='http://127.0.0.1:9090'
LOG='/tmp/us_failover.log'
TEST_URL='https%3A%2F%2Fwww.cp.cloudflare.com%2Fgenerate_204'
# 组名 URL 编码（中文必须转义，否则 API 返回 404）
G_AUTO='%E7%BE%8E%E5%9B%BD%E8%87%AA%E5%8A%A8'   # 美国自动（url-test）
G_POLICY='%E7%BE%8E%E5%9B%BD%E7%AD%96%E7%95%A5' # 美国策略（select）

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

# 防重入：上一轮延迟测试（最长 25s）没结束时跳过本轮，避免 cron 任务叠加
LOCK='/tmp/us_failover.lock'
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

pidof clash >/dev/null 2>&1 || exit 0
P="$(uci -q get openclash.config.dashboard_password 2>/dev/null)"
[ -n "$P" ] || P="$(uci -q get openclash.@openclash[0].dashboard_password 2>/dev/null)"
[ -n "$P" ] || exit 0
A="Authorization: Bearer $P"

# 组不存在时 curl 会拿到 404/空，统一按「本订阅没有该组」跳过
_auto="$(curl -s -m4 -H "$A" "$API/proxies/$G_AUTO" 2>/dev/null)"
case "$_auto" in *'"now"'*) ;; *) exit 0 ;; esac
_now="$(printf '%s' "$_auto" | sed -n 's/.*"now":"\([^"]*\)".*/\1/p')"
[ -n "$_now" ] || exit 0

# 单次延迟测试同时服务两个组：「美国自动」的成员就是全部美国节点
_map="$(curl -s -m25 -H "$A" "$API/group/$G_AUTO/delay?url=$TEST_URL&timeout=4000" 2>/dev/null)"
if [ -z "$_map" ]; then
	log "美国自动: 延迟测试无结果，保持 $_now"
	exit 0
fi

# 存活节点列表（正延迟），排除当前节点
_alive() {
	printf '%s' "$_map" | tr -d '{}' | tr ',' '\n' \
		| sed -n 's/^"\([^"]*\)":\([1-9][0-9]*\)$/\1/p' \
		| grep -vxF "$_now"
}

if ! printf '%s' "$_map" | grep -Fq "\"$_now\":" \
	|| printf '%s' "$_map" | grep -Fq "\"$_now\":0"; then
	# 1) 美国自动：当前节点已死 → 切到组内任一存活节点（url-test 会重新排序）
	_target="$(_alive | head -n1)"
	if [ -n "$_target" ]; then
		if curl -s -m5 -o /dev/null -w '%{http_code}' -X PUT -H "$A" \
			-H 'Content-Type: application/json' --data "{\"name\":\"$_target\"}" \
			"$API/proxies/$G_AUTO" | grep -q '^204$'; then
			log "美国自动: 切换 $_now -> $_target"
		else
			log "美国自动: 切换失败 $_now -> $_target"
		fi
	else
		log "美国自动: 无存活节点，保持 $_now"
	fi
fi

# 2) 美国策略：被钉在一个属于「美国自动」、但已经死掉的节点上 → 切回「美国自动」
_policy="$(curl -s -m4 -H "$A" "$API/proxies/$G_POLICY" 2>/dev/null)"
_pnow="$(printf '%s' "$_policy" | sed -n 's/.*"now":"\([^"]*\)".*/\1/p')"
if [ -n "$_pnow" ] && [ "$_pnow" != "美国自动" ]; then
	if printf '%s' "$_auto" | grep -Fq "\"$_pnow\"" \
		&& ! printf '%s' "$_map" | grep -Eq "\"$_pnow\":[1-9]"; then
		if curl -s -m5 -o /dev/null -w '%{http_code}' -X PUT -H "$A" \
			-H 'Content-Type: application/json' --data '{"name":"美国自动"}' \
			"$API/proxies/$G_POLICY" | grep -q '^204$'; then
			log "美国策略: 节点 $_pnow 已死，切回 美国自动"
		else
			log "美国策略: 切换失败 $_pnow -> 美国自动"
		fi
	fi
fi

exit 0
