#!/bin/sh

set -e

export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

TABLE_FAMILY="inet"
TABLE_NAME="netspeedcontrol"
CHAIN_PREROUTING_NAME="prerouting"
CHAIN_NAME="forward"
CHAIN_INPUT_NAME="input"
CONFIG_NAME="netspeedcontrol"
LEASE_FILE="/tmp/dhcp.leases"
STATE_DIR="/var/run/netspeedcontrol"
NFT_BIN="/usr/sbin/nft"
IP_BIN="/sbin/ip"
LOGGER_BIN="/usr/bin/logger"
CONNTRACK_BIN="/usr/sbin/conntrack"
EVENT_LOG_ENABLED="0"
EVENT_LOG_FILE="/tmp/netspeedcontrol-events.log"
EVENT_LOG_MAX_LINES="200"

DNSMASQ_CONF_DIR="/tmp/dnsmasq.d"
DNSMASQ_CONF_FILE="$DNSMASQ_CONF_DIR/netspeedcontrol.conf"

DOMAINS_SHORT_VIDEO="douyin.com snssdk.com amemv.com toutiaovod.com kuaishou.com yximgs.com bilibili.com hdslb.com"
DOMAINS_GAMING="qq.com pvp.qq.com tgpa.qq.com mihoyo.com genshinimpact.com 163.com netease.com epicgames.com steamcommunity.com"
DOMAINS_VIDEO="iqiyi.com qiyi.com v.qq.com youku.com mgtv.com bspapp.com"
DOMAINS_SOCIAL="weixin.qq.com wechat.com weibo.com sinaimg.cn"

get_category_domains() {
	local cat="$1"
	case "$cat" in
		short_video) echo "$DOMAINS_SHORT_VIDEO" ;;
		gaming) echo "$DOMAINS_GAMING" ;;
		video) echo "$DOMAINS_VIDEO" ;;
		social) echo "$DOMAINS_SOCIAL" ;;
		*) echo "" ;;
	esac
}

[ -x "$LOGGER_BIN" ] || LOGGER_BIN="/bin/logger"
[ -x "$CONNTRACK_BIN" ] || CONNTRACK_BIN="/usr/bin/conntrack"
[ -x "$CONNTRACK_BIN" ] || CONNTRACK_BIN=""

. /lib/functions.sh

mkdir -p "$STATE_DIR"

log() {
	"$LOGGER_BIN" -t netspeedcontrol "$*" 2>/dev/null || echo "netspeedcontrol: $*" >&2
}

get_lan_ip() {
	local ip
	ip="$(uci -q get network.lan.ipaddr)"
	if [ -z "$ip" ] && [ -x "$IP_BIN" ]; then
		ip="$("$IP_BIN" -4 addr show dev br-lan 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)"
	fi
	if [ -z "$ip" ] && [ -x "$IP_BIN" ]; then
		ip="$("$IP_BIN" -4 addr show dev eth0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)"
	fi
	echo "${ip:-192.168.1.1}"
}

get_lan_ip6() {
	local ip6
	if [ -x "$IP_BIN" ]; then
		ip6="$("$IP_BIN" -6 addr show scope global dev br-lan 2>/dev/null | awk '/inet6/ {print $2}' | cut -d/ -f1 | head -n1)"
		[ -z "$ip6" ] && ip6="$("$IP_BIN" -6 addr show scope global 2>/dev/null | awk '/inet6/ {print $2}' | cut -d/ -f1 | head -n1)"
	fi
	echo "$ip6"
}

require_tools() {
	[ -x "$NFT_BIN" ] || {
		log "nft command not found at $NFT_BIN"
		return 1
	}

	[ -x "$IP_BIN" ] || {
		log "ip command not found at $IP_BIN"
		return 1
	}
}

ensure_table() {
	local cat
	"$NFT_BIN" list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1 && return 0
	"$NFT_BIN" add table "$TABLE_FAMILY" "$TABLE_NAME"
	"$NFT_BIN" add chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PREROUTING_NAME" "{ type filter hook prerouting priority raw - 10; policy accept; }"
	"$NFT_BIN" add chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" "{ type filter hook forward priority filter - 10; policy accept; }"
	"$NFT_BIN" add chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_INPUT_NAME" "{ type filter hook input priority filter - 10; policy accept; }"

	for cat in short_video gaming video social custom; do
		"$NFT_BIN" add set "$TABLE_FAMILY" "$TABLE_NAME" "app_${cat}_v4" "{ type ipv4_addr; flags timeout; timeout 2h; }" 2>/dev/null || true
		"$NFT_BIN" add set "$TABLE_FAMILY" "$TABLE_NAME" "app_${cat}_v6" "{ type ipv6_addr; flags timeout; timeout 2h; }" 2>/dev/null || true
	done
}

flush_rules() {
	if "$NFT_BIN" list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; then
		"$NFT_BIN" flush chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PREROUTING_NAME"
		"$NFT_BIN" flush chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME"
		"$NFT_BIN" flush chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_INPUT_NAME"
	fi
}

clear_all() {
	flush_state_conntrack
	if "$NFT_BIN" list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; then
		"$NFT_BIN" delete table "$TABLE_FAMILY" "$TABLE_NAME"
	fi
	if [ -f "$DNSMASQ_CONF_FILE" ]; then
		rm -f "$DNSMASQ_CONF_FILE"
		/etc/init.d/dnsmasq reload >/dev/null 2>&1 || killall -HUP dnsmasq >/dev/null 2>&1 || true
	fi
	rm -f "$STATE_DIR"/* 2>/dev/null || true
}

normalize_mac() {
	echo "$1" | tr '[:lower:]' '[:upper:]'
}

resolve_ipv4_from_mac() {
	local mac ip
	mac="$(normalize_mac "$1")"

	if [ -f "$LEASE_FILE" ]; then
		ip="$(awk -v target="$mac" 'toupper($2) == target { print $3; exit }' "$LEASE_FILE")"
		[ -n "$ip" ] && {
			echo "$ip"
			return 0
		}
	fi

	"$IP_BIN" neigh show 2>/dev/null | awk -v target="$mac" '
		toupper($0) ~ toupper(target) {
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
					print $i
					exit
				}
			}
		}
	'
}

resolve_ipv6_from_mac() {
	local mac
	mac="$(normalize_mac "$1")"

	"$IP_BIN" -6 neigh show 2>/dev/null | awk -v target="$mac" '
		toupper($0) ~ toupper(target) {
			addr = $1
			if (addr ~ /^fe80:/ || addr ~ /^ff/) {
				next
			}
			if (!(addr in seen)) {
				print addr
				seen[addr] = 1
			}
		}
	'
}

rate_to_nft_bytes() {
	local raw_rate rate
	raw_rate="${1:-0}"

	# 提取纯数字（支持带 k/K/m/M 的单位输入）
	rate="$(echo "$raw_rate" | tr -cd '0-9')"
	[ -n "$rate" ] || return 1

	if [ "$rate" -le 0 ]; then
		echo ""
		return 1
	fi

	if echo "$raw_rate" | grep -qi "m"; then
		echo "${rate} mbytes/second"
	else
		echo "${rate} kbytes/second"
	fi
}

is_weekday_match() {
	local rule_days current_day token
	rule_days="${1:-}"
	current_day="$(date +%u)"

	[ -z "$rule_days" ] && return 0

	for token in $rule_days; do
		[ "$token" = "$current_day" ] && return 0
	done

	return 1
}

is_time_match() {
	local start stop now s_val e_val n_val
	start="${1:-00:00}"
	stop="${2:-23:59}"
	now="$(date +%H:%M)"

	[ "$start" = "$stop" ] && return 0

	s_val="$(echo "$start" | tr -d ':')"
	e_val="$(echo "$stop" | tr -d ':')"
	n_val="$(echo "$now" | tr -d ':')"

	# 兼容 BusyBox ash 去掉前导零，进行安全整数比较
	s_val="$(echo "$s_val" | sed 's/^0*//')"
	e_val="$(echo "$e_val" | sed 's/^0*//')"
	n_val="$(echo "$n_val" | sed 's/^0*//')"
	s_val="${s_val:-0}"
	e_val="${e_val:-0}"
	n_val="${n_val:-0}"

	if [ "$s_val" -lt "$e_val" ]; then
		[ "$n_val" -ge "$s_val" ] && [ "$n_val" -lt "$e_val" ] && return 0
		return 1
	else
		if [ "$n_val" -ge "$s_val" ] || [ "$n_val" -lt "$e_val" ]; then
			return 0
		fi
		return 1
	fi
}

is_rule_active() {
	is_weekday_match "$1" || return 1
	is_time_match "$2" "$3"
}

trim_event_log() {
	[ -f "$EVENT_LOG_FILE" ] || return 0
	# 限制最大行数，防止 BusyBox date 不支持 24 hours ago 导致脚本崩溃
	tail -n "$EVENT_LOG_MAX_LINES" "$EVENT_LOG_FILE" > "$EVENT_LOG_FILE.tmp" 2>/dev/null || return 0
	mv "$EVENT_LOG_FILE.tmp" "$EVENT_LOG_FILE"
}

sum_addr_stats() {
	local table_dump addr
	table_dump="$1"
	addr="$2"

	printf '%s\n' "$table_dump" | awk -v target="$addr" '
		index($0, target) > 0 {
			if (match($0, /packets [0-9]+/)) {
				p += substr($0, RSTART + 8, RLENGTH - 8) + 0
			}
			if (match($0, /bytes [0-9]+/)) {
				b += substr($0, RSTART + 6, RLENGTH - 6) + 0
			}
		}
		END {
			print (p + 0) " " (b + 0)
		}
	'
}

log_event_line() {
	local line
	line="$1"

	[ -n "$line" ] || return 0
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line" >> "$EVENT_LOG_FILE"
	trim_event_log
}

flush_conntrack_addr() {
	local family addr
	family="$1"
	addr="$2"

	[ -n "$CONNTRACK_BIN" ] || return 0
	[ -n "$addr" ] || return 0

	"$CONNTRACK_BIN" -D -f "$family" -s "$addr" >/dev/null 2>&1 || true
	"$CONNTRACK_BIN" -D -f "$family" -d "$addr" >/dev/null 2>&1 || true
}

flush_state_conntrack() {
	local file line

	[ -d "$STATE_DIR" ] || return 0

	for file in "$STATE_DIR"/*.ip; do
		[ -f "$file" ] || continue
		line="$(cat "$file" 2>/dev/null)"
		flush_conntrack_addr ipv4 "$line"
	done

	for file in "$STATE_DIR"/*.ip6; do
		[ -f "$file" ] || continue
		while IFS= read -r line; do
			flush_conntrack_addr ipv6 "$line"
		done < "$file"
	done
}

collect_event_logs() {
	local table_dump name_file section name mac mode ipv4 stats packets bytes ip6 first_ip addr

	[ "$EVENT_LOG_ENABLED" = "1" ] || return 0
	"$NFT_BIN" list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1 || return 0

	table_dump="$("$NFT_BIN" list table "$TABLE_FAMILY" "$TABLE_NAME" 2>/dev/null || true)"
	[ -n "$table_dump" ] || return 0

	for name_file in "$STATE_DIR"/*.name; do
		[ -f "$name_file" ] || continue

		section="${name_file##*/}"
		section="${section%.name}"
		name="$(cat "$STATE_DIR/$section.name" 2>/dev/null)"
		mac="$(cat "$STATE_DIR/$section.mac" 2>/dev/null)"
		mode="$(cat "$STATE_DIR/$section.mode" 2>/dev/null)"
		ipv4="$(cat "$STATE_DIR/$section.ip" 2>/dev/null)"
		packets=0
		bytes=0
		first_ip="$ipv4"

		if [ -n "$ipv4" ]; then
			stats="$(sum_addr_stats "$table_dump" "$ipv4")"
			packets=$((packets + ${stats%% *}))
			bytes=$((bytes + ${stats##* }))
		fi

		if [ -f "$STATE_DIR/$section.ip6" ]; then
			while IFS= read -r ip6; do
				[ -n "$ip6" ] || continue
				[ -n "$first_ip" ] || first_ip="$ip6"
				stats="$(sum_addr_stats "$table_dump" "$ip6")"
				packets=$((packets + ${stats%% *}))
				bytes=$((bytes + ${stats##* }))
			done < "$STATE_DIR/$section.ip6"
		fi

		[ "$packets" -gt 0 ] || [ "$bytes" -gt 0 ] || continue

		if [ "$mode" = "limit" ]; then
			log_event_line "设备【${name:-未命名设备}】（MAC：${mac:-未知}，地址：${first_ip:-未知}）流量超出限制，已处理 ${packets} 个数据包 / ${bytes} 字节。"
		else
			log_event_line "设备【${name:-未命名设备}】（MAC：${mac:-未知}，地址：${first_ip:-未知}）尝试上网，已拦截 ${packets} 个数据包 / ${bytes} 字节。"
		fi
	done
}

append_block_rule() {
	local ip name set_v4 mac norm_mac lan_ip
	ip="$1"
	name="$2"
	set_v4="$3"
	mac="$4"
	lan_ip="$(get_lan_ip)"

	if [ -n "$lan_ip" ]; then
		[ -n "$ip" ] && "$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PREROUTING_NAME" ip saddr "$ip" ip daddr "$lan_ip" meta l4proto tcp tcp dport { 80, 443 } counter accept
		[ -n "$ip" ] && "$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_INPUT_NAME" ip saddr "$ip" ip daddr "$lan_ip" meta l4proto tcp tcp dport { 80, 443 } counter accept
	fi

	if [ -n "$mac" ]; then
		norm_mac="$(normalize_mac "$mac")"
		if [ -z "$set_v4" ]; then
			"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PREROUTING_NAME" ether saddr "$norm_mac" counter drop 2>/dev/null || true
			"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ether saddr "$norm_mac" counter drop 2>/dev/null || true
		else
			"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PREROUTING_NAME" ether saddr "$norm_mac" ip daddr "@$set_v4" counter drop 2>/dev/null || true
			"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ether saddr "$norm_mac" ip daddr "@$set_v4" counter drop 2>/dev/null || true
		fi
	fi

	if [ -n "$ip" ]; then
		if [ -n "$set_v4" ]; then
			"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PREROUTING_NAME" ip saddr "$ip" ip daddr "@$set_v4" counter drop
			"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip saddr "$ip" ip daddr "@$set_v4" counter drop
		else
			"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PREROUTING_NAME" ip saddr "$ip" counter drop
			"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip saddr "$ip" counter drop
			"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip daddr "$ip" counter drop
			"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_INPUT_NAME" ip saddr "$ip" meta l4proto { tcp, udp } counter drop
		fi
	fi
}

append_block_rule6() {
	local ip6 name lan_ip6 set_v6
	ip6="$1"
	name="$2"
	set_v6="$3"
	lan_ip6="$(get_lan_ip6)"

	if [ -n "$lan_ip6" ]; then
		"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PREROUTING_NAME" ip6 saddr "$ip6" ip6 daddr "$lan_ip6" meta l4proto tcp tcp dport { 80, 443 } counter accept
		"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_INPUT_NAME" ip6 saddr "$ip6" ip6 daddr "$lan_ip6" meta l4proto tcp tcp dport { 80, 443 } counter accept
	fi

	if [ -n "$set_v6" ]; then
		"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PREROUTING_NAME" ip6 saddr "$ip6" ip6 daddr "@$set_v6" counter drop
		"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip6 saddr "$ip6" ip6 daddr "@$set_v6" counter drop
	else
		"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PREROUTING_NAME" ip6 saddr "$ip6" counter drop
		"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip6 saddr "$ip6" counter drop
		"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip6 daddr "$ip6" counter drop
		"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_INPUT_NAME" ip6 saddr "$ip6" meta l4proto { tcp, udp } counter drop
	fi
}

append_limit_rule() {
	local ip name up_rate down_rate set_v4 mac norm_mac
	ip="$1"
	name="$2"
	up_rate="$3"
	down_rate="$4"
	set_v4="$5"
	mac="$6"

	if [ -n "$mac" ]; then
		norm_mac="$(normalize_mac "$mac")"
		if [ -n "$up_rate" ]; then
			"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ether saddr "$norm_mac" limit rate over "$up_rate" counter drop 2>/dev/null || true
		fi
	fi

	if [ -n "$ip" ]; then
		if [ -n "$set_v4" ]; then
			if [ -n "$up_rate" ]; then
				"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip saddr "$ip" ip daddr "@$set_v4" limit rate over "$up_rate" counter drop 2>/dev/null || true
			fi
			if [ -n "$down_rate" ]; then
				"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip saddr "@$set_v4" ip daddr "$ip" limit rate over "$down_rate" counter drop 2>/dev/null || true
			fi
		else
			if [ -n "$up_rate" ]; then
				"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip saddr "$ip" limit rate over "$up_rate" counter drop 2>/dev/null || true
			fi
			if [ -n "$down_rate" ]; then
				"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip daddr "$ip" limit rate over "$down_rate" counter drop 2>/dev/null || true
			fi
		fi
	fi
}

append_limit_rule6() {
	local ip6 name up_rate down_rate set_v6
	ip6="$1"
	name="$2"
	up_rate="$3"
	down_rate="$4"
	set_v6="$5"

	if [ -n "$set_v6" ]; then
		if [ -n "$up_rate" ]; then
			# 上传：设备 -> 应用服务器
			"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip6 saddr "$ip6" ip6 daddr "@$set_v6" limit rate over "$up_rate" counter drop
		fi
		if [ -n "$down_rate" ]; then
			# 下载：应用服务器 -> 设备
			"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip6 saddr "@$set_v6" ip6 daddr "$ip6" limit rate over "$down_rate" counter drop
		fi
	else
		if [ -n "$up_rate" ]; then
			"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip6 saddr "$ip6" limit rate over "$up_rate" counter drop
		fi
		if [ -n "$down_rate" ]; then
			"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip6 daddr "$ip6" limit rate over "$down_rate" counter drop
		fi
	fi
}

handle_rule() {
	local section enabled name ip mac mode weekdays start_time stop_time up_kbit down_kbit target_scope app_category custom_domains resolved_ip resolved_ip6 ip6_list up_rate down_rate has_any set_v4 set_v6
	section="$1"

	config_get enabled "$section" enabled "0"
	[ "$enabled" = "1" ] || return 0

	config_get name "$section" name "$section"
	config_get ip "$section" ip ""
	config_get mac "$section" mac ""
	config_get mode "$section" mode "block"
	config_get weekdays "$section" weekdays ""
	config_get start_time "$section" start_time "00:00"
	config_get stop_time "$section" stop_time "23:59"
	config_get up_kbit "$section" up_kbit "0"
	config_get down_kbit "$section" down_kbit "0"
	config_get target_scope "$section" target_scope "all"
	config_get app_category "$section" app_category "short_video"
	config_get custom_domains "$section" custom_domains ""

	is_rule_active "$weekdays" "$start_time" "$stop_time" || return 0

	resolved_ip=""
	resolved_ip6=""
	ip6_list=""
	if [ -n "$mac" ]; then
		resolved_ip="$(resolve_ipv4_from_mac "$mac" || true)"
		[ -n "$resolved_ip" ] || resolved_ip="$ip"
		ip6_list="$(resolve_ipv6_from_mac "$mac" || true)"
	elif [ -n "$ip" ]; then
		resolved_ip="$ip"
	else
		log "skip rule [$name]: missing MAC address or IP"
		return 0
	fi

	has_any=0

	if [ -n "$resolved_ip" ]; then
		echo "$resolved_ip" > "$STATE_DIR/$section.ip"
		has_any=1
	else
		rm -f "$STATE_DIR/$section.ip" 2>/dev/null || true
	fi

	if [ -n "$ip6_list" ]; then
		printf '%s\n' "$ip6_list" > "$STATE_DIR/$section.ip6"
		has_any=1
	else
		rm -f "$STATE_DIR/$section.ip6" 2>/dev/null || true
	fi

	if [ -n "$mac" ]; then
		printf '%s\n' "$(normalize_mac "$mac")" > "$STATE_DIR/$section.mac"
		has_any=1
	fi

	[ "$has_any" -eq 1 ] || return 0
	printf '%s\n' "$name" > "$STATE_DIR/$section.name"
	printf '%s\n' "$mode" > "$STATE_DIR/$section.mode"

	set_v4=""
	set_v6=""
	if [ "$target_scope" = "app" ]; then
		set_v4="app_${app_category}_v4"
		set_v6="app_${app_category}_v6"
	elif [ "$target_scope" = "custom_domain" ]; then
		set_v4="app_custom_v4"
		set_v6="app_custom_v6"
	fi

	case "$mode" in
		block)
			append_block_rule "$resolved_ip" "$name" "$set_v4" "$mac"
			for resolved_ip6 in $ip6_list; do
				append_block_rule6 "$resolved_ip6" "$name" "$set_v6"
			done
		;;
		limit)
			up_rate="$(rate_to_nft_bytes "$up_kbit" || true)"
			down_rate="$(rate_to_nft_bytes "$down_kbit" || true)"
			if [ -z "$up_rate" ] && [ -z "$down_rate" ]; then
				log "skip rule [$name]: no valid rate configured"
				return 0
			fi
			append_limit_rule "$resolved_ip" "$name" "$up_rate" "$down_rate" "$set_v4" "$mac"
			for resolved_ip6 in $ip6_list; do
				append_limit_rule6 "$resolved_ip6" "$name" "$up_rate" "$down_rate" "$set_v6"
			done
		;;
		*)
			log "skip rule [$name]: unsupported mode $mode"
		;;
	esac
}

check_dnsmasq_nftset_support() {
	local cache_file="$STATE_DIR/dnsmasq_nftset_support"
	# 使用缓存避免每次轮询都 fork dnsmasq 进程
	if [ -f "$cache_file" ]; then
		local cached
		cached="$(cat "$cache_file" 2>/dev/null)"
		[ "$cached" = "1" ] && return 0 || return 1
	fi

	local opts result
	opts="$(dnsmasq -v 2>&1 || true)"
	if echo "$opts" | grep -q "no-nftset"; then
		result=0
	elif echo "$opts" | grep -q "nftset"; then
		result=1
	else
		result=0
	fi
	echo "$result" > "$cache_file"
	[ "$result" -eq 1 ] && return 0 || return 1
}

update_dnsmasq_nftsets() {
	local tmp_conf has_app_rule
	tmp_conf="/tmp/netspeedcontrol_dnsmasq.tmp"
	has_app_rule=0

	: > "$tmp_conf"

	_check_dnsmasq_rule() {
		local s="$1"
		local e scope cat doms dlist slash_doms
		config_get e "$s" enabled "0"
		[ "$e" = "1" ] || return 0

		config_get scope "$s" target_scope "all"
		config_get cat "$s" app_category "short_video"
		config_get doms "$s" custom_domains ""

		dlist=""
		if [ "$scope" = "app" ]; then
			has_app_rule=1
			dlist="$(get_category_domains "$cat")"
			if [ -n "$dlist" ]; then
				slash_doms="$(echo "$dlist" | tr ' ' '/')"
				echo "nftset=/$slash_doms/4#inet#netspeedcontrol#app_${cat}_v4,6#inet#netspeedcontrol#app_${cat}_v6" >> "$tmp_conf"
			fi
		elif [ "$scope" = "custom_domain" ]; then
			has_app_rule=1
			if [ -n "$doms" ]; then
				# 过滤非域名字符（只允许字母、数字、连字符、点、空格），防止破坏 dnsmasq 配置
				doms="$(echo "$doms" | tr -cd 'a-zA-Z0-9.\- ')"
				slash_doms="$(echo "$doms" | tr ' ' '/')"
				[ -n "$slash_doms" ] && echo "nftset=/$slash_doms/4#inet#netspeedcontrol#app_custom_v4,6#inet#netspeedcontrol#app_custom_v6" >> "$tmp_conf"
			fi
		fi
	}

	config_load "$CONFIG_NAME"
	config_foreach _check_dnsmasq_rule rule

	if [ "$has_app_rule" -eq 1 ] && ! check_dnsmasq_nftset_support; then
		log "警告：当前 dnsmasq 未编译 nftset 支持(no-nftset)，域名与应用分类控制无法生效。请在终端执行 'opkg update && opkg install dnsmasq-full' 替换为完整版 dnsmasq。"
		rm -f "$tmp_conf"
		if [ -f "$DNSMASQ_CONF_FILE" ]; then
			rm -f "$DNSMASQ_CONF_FILE"
			/etc/init.d/dnsmasq reload >/dev/null 2>&1 || killall -HUP dnsmasq >/dev/null 2>&1 || true
		fi
		return 0
	fi

	mkdir -p "$DNSMASQ_CONF_DIR"
	if [ -s "$tmp_conf" ]; then
		if ! cmp -s "$tmp_conf" "$DNSMASQ_CONF_FILE" 2>/dev/null; then
			mv "$tmp_conf" "$DNSMASQ_CONF_FILE"
			/etc/init.d/dnsmasq reload >/dev/null 2>&1 || killall -HUP dnsmasq >/dev/null 2>&1 || true
			log "dnsmasq nftset rules updated"
		else
			rm -f "$tmp_conf"
		fi
	else
		rm -f "$tmp_conf"
		if [ -f "$DNSMASQ_CONF_FILE" ]; then
			rm -f "$DNSMASQ_CONF_FILE"
			/etc/init.d/dnsmasq reload >/dev/null 2>&1 || killall -HUP dnsmasq >/dev/null 2>&1 || true
			log "dnsmasq nftset rules cleared"
		fi
	fi
}

apply_rules() {
	local enabled

	require_tools || return 1

	config_load "$CONFIG_NAME"
	config_get enabled globals enabled "1"
	config_get EVENT_LOG_ENABLED globals log_enabled "0"

	if [ "$enabled" != "1" ]; then
		clear_all
		return 0
	fi

	update_dnsmasq_nftsets
	collect_event_logs
	ensure_table
	flush_rules
	rm -f "$STATE_DIR"/* 2>/dev/null || true
	config_foreach handle_rule rule
	flush_state_conntrack
}

run_apply() {
	local rc

	set +e
	apply_rules
	rc="$?"
	set -e

	if [ "$rc" -ne 0 ]; then
		log "apply failed with code $rc"
	fi

	return "$rc"
}

daemon_loop() {
	while true; do
		run_apply || true
		sleep 60
	done
}

clear_event_log() {
	: > "$EVENT_LOG_FILE"
	log "event log cleared"
}

get_github_proxy() {
	local proxy="${GITHUB_PROXY:-}"
	if [ -z "$proxy" ]; then
		proxy="$(uci -q get netspeedcontrol.globals.github_proxy || true)"
	fi
	if [ -n "$proxy" ]; then
		proxy="${proxy%/}/"
	fi
	echo "$proxy"
}

check_update() {
	local repo="iamxiaojianzheng/netspeedcontrol"
	local api_url="https://api.github.com/repos/${repo}/releases/latest"
	local proxy="$(get_github_proxy)"
	local json tag_name download_url

	if command -v curl >/dev/null 2>&1; then
		json="$(curl -sL --connect-timeout 8 "$api_url" 2>/dev/null || true)"
	elif command -v wget >/dev/null 2>&1; then
		json="$(wget -qO- --timeout=8 "$api_url" 2>/dev/null || true)"
	fi

	tag_name="$(echo "$json" | awk -F'"' '/"tag_name":/ {print $4}' | head -n1)"
	download_url="$(echo "$json" | grep "browser_download_url.*\.ipk" | head -n1 | cut -d '"' -f 4 || true)"

	if [ -n "$tag_name" ] && [ -n "$download_url" ]; then
		[ -n "$proxy" ] && download_url="${proxy}${download_url}"
		printf '{"status":"ok","tag_name":"%s","download_url":"%s"}\n' "$tag_name" "$download_url"
	else
		printf '{"status":"error","message":"无法连接 GitHub API 获取更新信息"}\n'
	fi
}

do_update() {
	local download_url="$2"
	local tmp_ipk="/tmp/netspeedcontrol_update.ipk"
	local proxy="$(get_github_proxy)"

	if [ -z "$download_url" ]; then
		local repo="iamxiaojianzheng/netspeedcontrol"
		local api_url="https://api.github.com/repos/${repo}/releases/latest"
		if command -v curl >/dev/null 2>&1; then
			download_url="$(curl -sL --connect-timeout 8 "$api_url" | grep "browser_download_url.*\.ipk" | head -n1 | cut -d '"' -f 4 || true)"
		fi
		if [ -n "$download_url" ] && [ -n "$proxy" ]; then
			download_url="${proxy}${download_url}"
		fi
	fi

	if [ -z "$download_url" ]; then
		log "更新失败：未找到有效安装包链接"
		echo "ERROR: Missing download URL"
		return 1
	fi

	log "开始在线升级，下载包: $download_url"
	if command -v curl >/dev/null 2>&1; then
		curl -sL "$download_url" -o "$tmp_ipk"
	else
		wget -qO "$tmp_ipk" "$download_url"
	fi

	if [ ! -s "$tmp_ipk" ] || grep -qi "<html" "$tmp_ipk" 2>/dev/null; then
		rm -f "$tmp_ipk"
		log "更新失败：下载的 IPK 文件无效（可能是代理拦截或 404 网页）"
		echo "ERROR: Downloaded file is invalid (HTML response or empty)"
		return 1
	fi

	log "正在安装更新包..."
	if opkg install --force-reinstall "$tmp_ipk" >/tmp/netspeedcontrol_update.log 2>&1; then
		rm -f "$tmp_ipk"
		log "应用一键更新升级成功！"
		echo "SUCCESS"
		return 0
	else
		log "opkg 安装失败，详见 /tmp/netspeedcontrol_update.log"
		echo "ERROR: opkg install failed"
		return 1
	fi
}

show_status() {
	local table_dump section name mac mode ip ip6
	echo "=== Netspeedcontrol Service Status ==="
	if pgrep -f "netspeedcontrol.sh daemon" >/dev/null 2>&1; then
		echo "Daemon Service: Running (PID: $(pgrep -f "netspeedcontrol.sh daemon" | head -n1))"
	else
		echo "Daemon Service: Stopped"
	fi
	echo "Event Log Enabled: ${EVENT_LOG_ENABLED}"
	echo ""
	echo "=== Active Rules & Resolved IPs ==="
	if [ -d "$STATE_DIR" ]; then
		for name_file in "$STATE_DIR"/*.name; do
			[ -f "$name_file" ] || continue
			section="${name_file##*/}"
			section="${section%.name}"
			name="$(cat "$STATE_DIR/$section.name" 2>/dev/null)"
			mac="$(cat "$STATE_DIR/$section.mac" 2>/dev/null)"
			mode="$(cat "$STATE_DIR/$section.mode" 2>/dev/null)"
			ip="$(cat "$STATE_DIR/$section.ip" 2>/dev/null)"
			echo "Rule [$name] (MAC: ${mac:-N/A}, Mode: $mode):"
			echo "  IPv4: ${ip:-Not Resolved}"
			if [ -f "$STATE_DIR/$section.ip6" ]; then
				echo "  IPv6 Addresses:"
				while IFS= read -r ip6; do
					[ -n "$ip6" ] && echo "    - $ip6"
				done < "$STATE_DIR/$section.ip6"
			fi
		done
	fi
	echo ""
	echo "=== Nftables Rule Statistics ==="
	if "$NFT_BIN" list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; then
		"$NFT_BIN" list table "$TABLE_FAMILY" "$TABLE_NAME" 2>/dev/null
	else
		echo "No nftables rules currently active."
	fi
}

case "${1:-apply}" in
	apply)
		run_apply
	;;
	clear)
		clear_all
	;;
	clear_log)
		clear_event_log
	;;
	check_update)
		check_update
	;;
	do_update)
		do_update "$@"
	;;
	status)
		show_status
	;;
	daemon)
		daemon_loop
	;;
	*)
		echo "Usage: $0 {apply|clear|clear_log|check_update|do_update|status|daemon}" >&2
		exit 1
	;;
esac


