#!/system/bin/sh
# ============================================================================
# dtbo_charge_unlock 充电状态采集（只读）
#
# 输出 key=value，每行一个，供 webroot 的页面解析。
# 本脚本不写任何文件、不碰任何分区，最多读 sysfs / proc / 模块自己的 state。
#
# 可通过环境变量覆盖路径（PC 上用假目录自测）：
#   SYSFS_ROOT  代替 /sys
#   MODDIR      模块目录
# ============================================================================

SYS="${SYSFS_ROOT:-/sys}"
MODDIR="${MODDIR:-/data/adb/modules/dtbo_charge_unlock}"

emit() { printf '%s=%s\n' "$1" "$2"; }

# 读一个小文件，去掉换行。不存在/不可读就输出空。
rd() {
	[ -r "$1" ] || return 0
	cat "$1" 2>/dev/null | head -n 1 | tr -d '\r'
}

# 取模块目录下某个文件里 key=value 的值
kv() {  # kv <文件> <键>
	[ -r "$1" ] || return 0
	grep "^$2=" "$1" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '\r'
}

# ------------------------------------------------------------------ 基础信息 ---
emit time "$(date +%s 2>/dev/null)"
emit module_version "$(kv "$MODDIR/module.prop" version)"
emit module_author "$(kv "$MODDIR/module.prop" author)"

if command -v getprop >/dev/null 2>&1; then
	emit device_model "$(getprop ro.product.model 2>/dev/null | tr -d '\r')"
	emit device_slot "$(getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r')"
fi

# -------------------------------------------------------------------- 电池 ---
PS="$SYS/class/power_supply"
BATT=""
for d in battery Battery bms; do
	if [ -d "$PS/$d" ]; then
		BATT="$PS/$d"
		break
	fi
done

emit batt_dir "$BATT"

if [ -n "$BATT" ]; then
	emit capacity        "$(rd "$BATT/capacity")"
	emit status          "$(rd "$BATT/status")"
	emit present         "$(rd "$BATT/present")"
	emit health          "$(rd "$BATT/health")"
	emit technology      "$(rd "$BATT/technology")"
	emit temp_raw        "$(rd "$BATT/temp")"
	emit current_now     "$(rd "$BATT/current_now")"
	emit voltage_now     "$(rd "$BATT/voltage_now")"
	emit power_now       "$(rd "$BATT/power_now")"
	emit charge_counter  "$(rd "$BATT/charge_counter")"
	emit charge_full     "$(rd "$BATT/charge_full")"
	emit charge_full_design "$(rd "$BATT/charge_full_design")"
	emit cycle_count     "$(rd "$BATT/cycle_count")"
	emit current_avg     "$(rd "$BATT/current_avg")"
	emit voltage_avg     "$(rd "$BATT/voltage_avg")"
	emit batt_temp_level "$(rd "$BATT/system_temp_level")"

	# 充电上限（部分机型由 thermal / 充电策略写入）
	emit input_current_limit "$(rd "$BATT/input_current_limit")"
	emit ccc_max             "$(rd "$BATT/constant_charge_current_max")"
	emit ccv_max             "$(rd "$BATT/constant_charge_voltage_max")"
	emit charge_control_limit "$(rd "$BATT/charge_control_limit")"
	emit step_charging_status "$(rd "$BATT/step_charging_status")"
	emit charge_done          "$(rd "$BATT/charge_done")"
	emit charging_enabled     "$(rd "$BATT/battery_charging_enabled")"
fi

# ------------------------------------------------------------------ 电源类型 ---
_srcs=""
for s in usb ac wireless dc pc_port; do
	[ -d "$PS/$s" ] || continue
	_srcs="$_srcs $s"
	emit "src.${s}.online" "$(rd "$PS/$s/online")"
	emit "src.${s}.type"   "$(rd "$PS/$s/type")"
	emit "src.${s}.vnow"   "$(rd "$PS/$s/voltage_now")"
	emit "src.${s}.imax"   "$(rd "$PS/$s/current_max")"
	emit "src.${s}.vmax"   "$(rd "$PS/$s/voltage_max")"
done
emit src.list "$_srcs"

# USB 细节（PD/协议、实际功率）
if [ -d "$PS/usb" ]; then
	emit usb_real_type   "$(rd "$PS/usb/real_type")"
	emit usb_voltage_max "$(rd "$PS/usb/voltage_max")"
	emit usb_current_max "$(rd "$PS/usb/current_max")"
	emit usb_pd_active   "$(rd "$PS/usb/pd_active")"
	emit usb_typec_cc_orientation "$(rd "$PS/usb/typec_cc_orientation")"
fi

# -------------------------------------------------------------------- 温度 ---
_n=0
for z in "$SYS"/class/thermal/thermal_zone*; do
	[ -d "$z" ] || continue
	_t=$(rd "$z/type")
	[ -n "$_t" ] || continue
	case "$_t" in
		*batt*|*BATT*|*charg*|*CHAR*|*usb*|*USB*|*typec*|*TYPEC*|*pmic*|*PMIC*|*pm[0-9]*|*bcl*|*chg*|*CHG*) ;;
		*) continue ;;
	esac
	emit "thermal.$_n" "$_t|$(rd "$z/temp")"
	_n=$((_n + 1))
	[ "$_n" -ge 10 ] && break
done
emit thermal.count "$_n"

# ---------------------------------------------------------------- 模块状态 ---
S="$MODDIR/state"

emit state_last_sha  "$(rd "$S/last_sha")"
emit state_orig_sha  "$(rd "$S/orig_sha")"
emit state_part      "$(rd "$S/part")"
emit state_last_head "$(rd "$S/last_head")"
emit state_pending   "$(rd "$S/pending")"
emit state_pending_id "$(rd "$S/pending_id")"
emit state_pending_tries "$(rd "$S/pending_tries")"
emit state_confirmed "$(rd "$S/confirmed")"
emit state_last_flash "$(stat -c %Y "$S/last_sha" 2>/dev/null)"

if [ -f "$S/halted" ]; then
	emit state_halted 1
else
	emit state_halted 0
fi

# 最近一次备份
_bk=$(ls -1t "$MODDIR/backup/"*.img 2>/dev/null | head -n 1)
if [ -n "$_bk" ]; then
	emit backup_file "$_bk"
	emit backup_size "$(stat -c %s "$_bk" 2>/dev/null)"
	emit backup_time "$(stat -c %Y "$_bk" 2>/dev/null)"
fi
emit backup_count "$(ls -1 "$MODDIR/backup/" 2>/dev/null | grep -c '\.img$')"

# 目标温度窗口（配置里的，不是 dtbo 里的实际值）
_cfg_low=$(kv "$MODDIR/config.conf" FFC_TEMP_LOW)
_cfg_high=$(kv "$MODDIR/config.conf" FFC_TEMP_HIGH)
emit cfg_ffc_low       "$_cfg_low"
emit cfg_ffc_high      "$_cfg_high"
emit cfg_dry_run       "$(kv "$MODDIR/config.conf" DRY_RUN)"

# ------------------------------------------------------------ 充电日志 ---
# 日志放在模块目录之外，升级模块不会丢历史。
LOGDIR="${CHARGELOG_DIR:-$(kv "$MODDIR/config.conf" CHARGELOG_DIR)}"
[ -n "$LOGDIR" ] || LOGDIR=/data/adb/dtbo_charge_unlock/chargelog

_interval=$(kv "$MODDIR/config.conf" CHARGELOG_INTERVAL)
case "$_interval" in ''|*[!0-9]*) _interval=30 ;; esac
emit log_dir      "$LOGDIR"
emit log_interval "$_interval"
emit log_count    "$(ls -1 "$LOGDIR"/*.log 2>/dev/null | wc -l | tr -d ' \t\r\n')"
emit log_current  "$(rd "$LOGDIR/.current")"

if [ -f "$LOGDIR/.pid" ] && kill -0 "$(cat "$LOGDIR/.pid" 2>/dev/null)" 2>/dev/null; then
	emit log_running 1
else
	emit log_running 0
fi

# 会话列表：只输出元信息，统计量留给页面算，省得在设备上 fork 一堆 awk
list_sessions() {
	_i=0
	for _f in $(ls -1t "$LOGDIR"/*.log 2>/dev/null); do
		[ -f "$_f" ] || continue
		[ "$_i" -ge 40 ] && break
		_n=${_f##*/}
		emit "log.$_i.name"    "$_n"
		emit "log.$_i.start"   "$(sed -n 's/^#start=//p' "$_f" 2>/dev/null | head -n 1)"
		emit "log.$_i.end"     "$(sed -n 's/^#end=//p' "$_f" 2>/dev/null | head -n 1)"
		emit "log.$_i.aborted" "$(grep -c '^#aborted=1' "$_f" 2>/dev/null)"
		emit "log.$_i.samples" "$(grep -vc '^#' "$_f" 2>/dev/null)"
		emit "log.$_i.cap0"    "$(grep -v '^#' "$_f" 2>/dev/null | head -n 1 | cut -d, -f2)"
		emit "log.$_i.cap1"    "$(grep -v '^#' "$_f" 2>/dev/null | tail -n 1 | cut -d, -f2)"
		emit "log.$_i.temp_max" "$(grep -v '^#' "$_f" 2>/dev/null | cut -d, -f3 | sort -n | tail -n 1)"
		_i=$((_i + 1))
	done
	emit log.list_count "$_i"
}

# 单个会话的采样点。每行原样带出去，单位换算交给页面。
dump_session() {
	_name="$2"
	case "$_name" in
		''|*/*|*..*) emit log_err "会话名不合法"; exit 1 ;;
	esac
	_f="$LOGDIR/$_name"
	if [ ! -r "$_f" ]; then
		emit log_err "找不到会话 $2"
		exit 1
	fi
	emit session.name    "$_name"
	emit session.start   "$(sed -n 's/^#start=//p' "$_f" 2>/dev/null | head -n 1)"
	emit session.end     "$(sed -n 's/^#end=//p' "$_f" 2>/dev/null | head -n 1)"
	emit session.aborted "$(grep -c '^#aborted=1' "$_f" 2>/dev/null)"
	_i=0
	while IFS= read -r _l; do
		case "$_l" in
			'#'*) continue ;;
			'') continue ;;
		esac
		emit "session.s.$_i" "$_l"
		_i=$((_i + 1))
		[ "$_i" -ge 4000 ] && break
	done < "$_f"
	emit session.count "$_i"
}

case "${1:-}" in
	--logs) list_sessions ;;
	--log)  dump_session "$@" ;;
esac

# 档位名由温度窗口反推 —— config.conf 是唯一事实来源，
# 不额外记状态文件，避免两边对不上。
case "$_cfg_high" in
	48) emit cfg_tier safe ;;
	56) emit cfg_tier max ;;
	"") emit cfg_tier ref ;;
	*)  emit cfg_tier custom ;;
esac

# ------------------------------------------- 可选：当前分区是否仍是刷入的那份 ---
# 只在带 --full 时做。要读分区开头 1MB 算哈希，轮询时不该反复读盘。
# 系统 OTA 会把 dtbo 换回原厂，页面靠这两项提示「需要重新运行一次」。
if [ "${1:-}" = "--full" ]; then
	_prt=$(rd "$S/part")
	if [ -n "$_prt" ] && [ -r "$_prt" ]; then
		_cur=$(dd if="$_prt" bs=1048576 count=1 2>/dev/null \
			| sha256sum 2>/dev/null | cut -d' ' -f1)
		[ -n "$_cur" ] && emit state_cur_head "$_cur"
	fi
fi

exit 0
