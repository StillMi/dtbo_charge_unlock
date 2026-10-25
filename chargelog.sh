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
# 采样行格式（v2，逗号分隔 11 列）：
#   0 epoch            采样时刻
#   1 capacity         电量 %
#   2 temp_raw         电池温度原始值（0.1℃，页面负责换算）
#   3 current_now      电流 uA（带符号）
#   4 voltage_now      电压 uV
#   5 charge_counter   累计充入 uAh
#   6 status           电池状态字符串
#   7 power_now        功率 uW（节点不存在时为空，页面用 I*V 兜底）
#   8 usb_vnow         充电器电压 uV
#   9 usb_imax         充电器限流 uA
#  10 chg_temp_raw     充电器/主板温度原始值（0.1℃，取第一个非电池温度区）
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

_CR=$(printf '\r')

# 文件第一行 → $_RV（不 fork）
rv() {
	_RV=""
	[ -r "$1" ] || return 0
	IFS= read -r _RV 2>/dev/null < "$1" || :
	_RV=${_RV%"$_CR"}
}

# config.conf 里 key=value 的值 → $_KV（不 fork）
kv() {
	_KV=""
	[ -r "$1" ] || return 0
	while IFS= read -r _l || [ -n "$_l" ]; do
		case "$_l" in
			"$2="*) _KV=${_l#*=}; _KV=${_KV%"$_CR"}; break ;;
		esac
	done < "$1"
}

CFG="$MODDIR/config.conf"

kv "$CFG" CHARGELOG_DIR
LOGDIR="${CHARGELOG_DIR:-$_KV}"
[ -n "$LOGDIR" ] || LOGDIR=/data/adb/dtbo_charge_unlock/chargelog

kv "$CFG" CHARGELOG_INTERVAL
INTERVAL="$_KV"
case "$INTERVAL" in
	''|*[!0-9]*) INTERVAL=10 ;;
esac
[ "$INTERVAL" -ge 5 ] || INTERVAL=5

kv "$CFG" CHARGELOG_MAX
MAXN="$_KV"
case "$MAXN" in
	''|*[!0-9]*) MAXN=40 ;;
esac
[ "$MAXN" -ge 1 ] || MAXN=1

kv "$CFG" CHARGELOG
ENABLED="$_KV"
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
		rv "$SYS/class/power_supply/$s/online"
		[ "$_RV" = "1" ] && _on=1
	done
	if [ "$_on" = "0" ]; then
		rv "$(batt_dir)/status"
		case "$_RV" in
			Charging|Full) _on=1 ;;
		esac
	fi
	printf '%s' "$_on"
}

# 第一个非电池的充电相关温度区（充电器 / 主板），取不到就留空
chg_temp() {
	for z in "$SYS"/class/thermal/thermal_zone*; do
		[ -d "$z" ] || continue
		rv "$z/type"
		case "$_RV" in
			*batt*|*BATT*|'') continue ;;
		esac
		rv "$z/temp"
		if [ -n "$_RV" ]; then
			printf '%s' "$_RV"
			return 0
		fi
	done
	printf ''
}

# --------------------------------------------------------------- 会话文件 ---

# 只保留最近 MAXN 个会话
prune() {
	_cnt=0
	for _f in "$LOGDIR"/*.log; do
		[ -f "$_f" ] && _cnt=$((_cnt + 1))
	done
	[ "$_cnt" -le "$MAXN" ] && return 0
	ls -1t "$LOGDIR"/*.log 2>/dev/null \
		| tail -n "+$((MAXN + 1))" \
		| while IFS= read -r _old; do
			[ -n "$_old" ] && rm -f "$_old"
		done
}

begin_session() {
	_base=$(date '+%Y%m%d-%H%M%S')
	_name="$_base.log"
	# 同一秒内先结束一个会话、紧接着又开一个（插拔很快）时，文件名会撞上，
	# 用 > 写入就把上一个会话截断了。加后缀避开重名，绝不覆盖已有会话。
	_n=1
	while [ -f "$LOGDIR/$_name" ]; do
		_name="$_base-$_n.log"
		_n=$((_n + 1))
		[ "$_n" -gt 99 ] && break
	done
	_f="$LOGDIR/$_name"
	{
		printf '#dtbo-chargelog v2\n'
		printf '#start=%s\n' "$(date +%s)"
	} > "$_f" 2>/dev/null || return 1
	printf '%s\n' "$_name" > "$CURF"
	prune
}

# append_sample <cap> <temp> <cur> <volt> <counter> <status> <power> <usbv> <usbi> <chgtemp>
append_sample() {
	[ -f "$CURF" ] || return 0
	_name=$(cat "$CURF" 2>/dev/null)
	[ -n "$_name" ] || return 0
	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$(date +%s)" "$1" "$2" "$3" "$4" "$5" "$6" \
		"$7" "$8" "$9" "${10}" \
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

		rv "$_b/capacity";       _cap="$_RV"
		rv "$_b/temp";           _tmp="$_RV"
		rv "$_b/current_now";    _cur="$_RV"
		rv "$_b/voltage_now";    _vol="$_RV"
		rv "$_b/charge_counter"; _cnt="$_RV"
		rv "$_b/status";         _sts="$_RV"
		rv "$_b/power_now";      _pow="$_RV"
		rv "$SYS/class/power_supply/usb/voltage_now"; _uv="$_RV"
		rv "$SYS/class/power_supply/usb/current_max"; _ui="$_RV"
		_ct=$(chg_temp)

		append_sample "$_cap" "$_tmp" "$_cur" "$_vol" "$_cnt" "$_sts" \
			"$_pow" "$_uv" "$_ui" "$_ct"
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
