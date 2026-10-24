#!/system/bin/sh
# ============================================================================
# dtbo_charge_unlock · 充电日志后台记录
#
# 每隔一段时间采一次电池状态。检测到「插上充电器」就开一个新的会话文件，
# 一直往里记，直到拔出充电器（或者掉电关机/进程被杀 —— 那种情况会留下
# 没有 #end 的残缺文件，页面标成「未正常结束」）。
#
# 只读 /sys，只往自己的日志目录写文件，不碰任何分区、不改任何配置。
#
# 用法:
#   sh chargelog.sh start    后台启动（已经在跑就跳过）
#   sh chargelog.sh stop     停止
#   sh chargelog.sh status   在跑就打印 pid
#   sh chargelog.sh loop     前台循环（内部用）
#   sh chargelog.sh once     只跑一轮就退出（自测用）
#
# 环境变量覆盖路径（PC 上用假目录自测）:
#   SYSFS_ROOT      代替 /sys
#   MODDIR          模块目录
#   CHARGELOG_DIR   日志目录
# ============================================================================

SYS="${SYSFS_ROOT:-/sys}"
MODDIR="${MODDIR:-/data/adb/modules/dtbo_charge_unlock}"

# 被 copy 到别处执行时 $0 可能不是模块目录，优先用自身位置
HERE="${0%/*}"
[ -f "$HERE/module.prop" ] && MODDIR="$HERE"

# 绝对路径，避免 setsid 之后 cwd 变了找不到自己
SELF="$0"
case "$SELF" in
	/*) ;;
	*) SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
esac

rd() {
	[ -r "$1" ] || return 0
	cat "$1" 2>/dev/null | head -n 1 | tr -d '\r'
}

kv() {
	[ -r "$1" ] || return 0
	grep "^$2=" "$1" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '\r'
}

CFG="$MODDIR/config.conf"

LOGDIR="${CHARGELOG_DIR:-$(kv "$CFG" CHARGELOG_DIR)}"
[ -n "$LOGDIR" ] || LOGDIR=/data/adb/dtbo_charge_unlock/chargelog

INTERVAL=$(kv "$CFG" CHARGELOG_INTERVAL)
case "$INTERVAL" in
	''|*[!0-9]*) INTERVAL=30 ;;
esac
[ "$INTERVAL" -ge 5 ] || INTERVAL=5

MAXN=$(kv "$CFG" CHARGELOG_MAX)
case "$MAXN" in
	''|*[!0-9]*) MAXN=40 ;;
esac
[ "$MAXN" -ge 1 ] || MAXN=1

ENABLED=$(kv "$CFG" CHARGELOG)
[ -n "$ENABLED" ] || ENABLED=1

PIDF="$LOGDIR/.pid"
CURF="$LOGDIR/.current"

# --------------------------------------------------------------- 电池节点 ---

batt_dir() {
	for d in battery Battery bms; do
		if [ -d "$SYS/class/power_supply/$d" ]; then
			printf '%s' "$SYS/class/power_supply/$d"
			return 0
		fi
	done
	return 0
}

# 有没有插着电：任一供电源 online=1 就算。识别不到供电源时退回看电池状态。
plugged_in() {
	_on=0
	for s in usb ac wireless dc pc_port; do
		[ "$(rd "$SYS/class/power_supply/$s/online")" = "1" ] && _on=1
	done
	if [ "$_on" = "0" ]; then
		case "$(rd "$(batt_dir)/status")" in
			Charging|Full) _on=1 ;;
		esac
	fi
	printf '%s' "$_on"
}

# --------------------------------------------------------------- 会话文件 ---

# 只保留最近 MAXN 个会话
prune() {
	_cnt=$(ls -1 "$LOGDIR"/*.log 2>/dev/null | wc -l | tr -d ' \t\r\n')
	case "$_cnt" in ''|*[!0-9]*) return 0 ;; esac
	[ "$_cnt" -le "$MAXN" ] && return 0
	ls -1t "$LOGDIR"/*.log 2>/dev/null \
		| tail -n "+$((MAXN + 1))" \
		| while IFS= read -r _old; do
			[ -n "$_old" ] && rm -f "$_old"
		done
}

begin_session() {
	_name=$(date '+%Y%m%d-%H%M%S').log
	_f="$LOGDIR/$_name"
	{
		printf '#dtbo-chargelog v1\n'
		printf '#start=%s\n' "$(date +%s)"
	} > "$_f" 2>/dev/null || return 1
	printf '%s\n' "$_name" > "$CURF"
	prune
}

append_sample() {
	[ -f "$CURF" ] || return 0
	_name=$(cat "$CURF" 2>/dev/null)
	[ -n "$_name" ] || return 0
	printf '%s,%s,%s,%s,%s,%s,%s\n' \
		"$(date +%s)" "$1" "$2" "$3" "$4" "$5" "$6" \
		>> "$LOGDIR/$_name" 2>/dev/null
}

end_session() {
	[ -f "$CURF" ] || return 0
	_name=$(cat "$CURF" 2>/dev/null)
	if [ -n "$_name" ] && [ -f "$LOGDIR/$_name" ]; then
		printf '#end=%s\n' "$(date +%s)" >> "$LOGDIR/$_name" 2>/dev/null
	fi
	rm -f "$CURF"
}

# 上次没正常收尾就留下的文件（掉电关机、进程被杀）
mark_stale() {
	[ -f "$CURF" ] || return 0
	_name=$(cat "$CURF" 2>/dev/null)
	if [ -n "$_name" ] && [ -f "$LOGDIR/$_name" ]; then
		grep -q '^#end=' "$LOGDIR/$_name" 2>/dev/null \
			|| printf '#aborted=1\n' >> "$LOGDIR/$_name" 2>/dev/null
	fi
	rm -f "$CURF"
}

# --------------------------------------------------------------- 一轮采集 ---

step() {
	mkdir -p "$LOGDIR" 2>/dev/null

	if [ "$(plugged_in)" = "1" ]; then
		[ -f "$CURF" ] || begin_session
		_b=$(batt_dir)
		append_sample \
			"$(rd "$_b/capacity")" \
			"$(rd "$_b/temp")" \
			"$(rd "$_b/current_now")" \
			"$(rd "$_b/voltage_now")" \
			"$(rd "$_b/charge_counter")" \
			"$(rd "$_b/status")"
	else
		end_session
	fi
}

# ------------------------------------------------------------------- 入口 ---

case "$1" in
start)
	[ "$ENABLED" = "1" ] || exit 0
	mkdir -p "$LOGDIR" 2>/dev/null
	mark_stale

	if [ -f "$PIDF" ]; then
		_p=$(cat "$PIDF" 2>/dev/null)
		[ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && exit 0
	fi

	if command -v setsid >/dev/null 2>&1; then
		setsid sh "$SELF" loop < /dev/null > /dev/null 2>&1 &
	else
		sh "$SELF" loop < /dev/null > /dev/null 2>&1 &
	fi
	printf '%s\n' "$!" > "$PIDF"
	exit 0
	;;

stop)
	if [ -f "$PIDF" ]; then
		_p=$(cat "$PIDF" 2>/dev/null)
		[ -n "$_p" ] && kill "$_p" 2>/dev/null
		rm -f "$PIDF"
	fi
	end_session
	exit 0
	;;

status)
	if [ -f "$PIDF" ]; then
		_p=$(cat "$PIDF" 2>/dev/null)
		[ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && printf '%s\n' "$_p"
	fi
	exit 0
	;;

once)
	step
	exit 0
	;;

loop)
	mkdir -p "$LOGDIR" 2>/dev/null
	printf '%s\n' "$$" > "$PIDF"
	trap 'rm -f "$PIDF"' EXIT INT TERM HUP
	while :; do
		step
		sleep "$INTERVAL"
	done
	;;

*)
	echo "用法: sh $0 {start|stop|status|once|loop}"
	exit 2
	;;
esac
