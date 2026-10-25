#!/system/bin/sh
# ============================================================================
# dtbo_charge_unlock 充电状态采集（只读）
#
# 输出 key=value，每行一个，供 webroot 的页面解析。
# 本脚本不写任何文件、不碰任何分区，最多读 sysfs / proc / 模块自己的 state。
#
# 性能注意（重要）：
#   实时页面每 2 秒调用一次本脚本，所以「每读一个 sysfs 节点就 fork 几个进程」
#   的写法会让手机持续处于 fork 风暴里，页面点击明显发卡。因此这里全部改用
#   内建 read + 参数展开，读文件不再 fork；整个实时采集只有十来个 fork。
#
# 用法：
#   monitor.sh            实时采集（页面轮询用）
#   monitor.sh --full     实时采集 + 回读分区头部哈希（判断是否需要重新应用）
#   monitor.sh --logs     只列充电日志会话（不采集 sysfs，切标签页用）
#   monitor.sh --log NAME 只导出某个会话的采样点
#
# 可通过环境变量覆盖路径（PC 上用假目录自测）：
#   SYSFS_ROOT  代替 /sys
#   MODDIR      模块目录
#   CHARGELOG_DIR  代替 config.conf 里的日志目录
# ============================================================================

SYS="${SYSFS_ROOT:-/sys}"
MODDIR="${MODDIR:-/data/adb/modules/dtbo_charge_unlock}"

emit() { printf '%s=%s\n' "$1" "$2"; }

# 行尾 CR（配置/状态文件可能在 Windows 上被编辑过）。取一次，之后用参数展开去掉，
# 免得每次比较都 fork 一个 tr。
_CR=$(printf '\r')

# 把文件第一行读进 $_RV。不存在/不可读就留空。
rv() {
	_RV=""
	[ -r "$1" ] || return 0
	IFS= read -r _RV 2>/dev/null < "$1" || :
	_RV=${_RV%"$_CR"}
}

# 取配置文件里 key=value 的值，结果放 $_KV。
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
MODE="${1:-}"

# ------------------------------------------------------------ 充电日志目录 ---
# 日志放在模块目录之外，升级模块不会丢历史。
kv "$CFG" CHARGELOG_DIR
LOGDIR="${CHARGELOG_DIR:-$_KV}"
[ -n "$LOGDIR" ] || LOGDIR=/data/adb/dtbo_charge_unlock/chargelog

kv "$CFG" CHARGELOG_INTERVAL
LOG_INTERVAL="$_KV"
case "$LOG_INTERVAL" in ''|*[!0-9]*) LOG_INTERVAL=10 ;; esac

log_state() {
	emit log_dir      "$LOGDIR"
	emit log_interval "$LOG_INTERVAL"

	_c=0
	for _x in "$LOGDIR"/*.log; do
		[ -f "$_x" ] && _c=$((_c + 1))
	done
	emit log_count "$_c"

	rv "$LOGDIR/.current"
	emit log_current "$_RV"

	_running=0
	if [ -f "$LOGDIR/.pid" ]; then
		rv "$LOGDIR/.pid"
		_p="$_RV"
		if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null; then
			_running=1
		fi
	fi
	emit log_running "$_running"
}

# ------------------------------------------------------------------ 会话列表 ---
# 一个 awk 扫完全部会话（一次 fork），字段用 | 分隔回传给 shell 再 emit。
# 采样行格式（v2，11 列；v1 只有前 7 列）：
#   0 epoch  1 cap  2 temp_raw  3 current_now  4 voltage_now  5 charge_counter
#   6 status 7 power_now 8 usb_vnow 9 usb_imax 10 chg_temp_raw
list_sessions() {
	log_state

	_files=""
	_ln=0
	for _f in $(ls -1t "$LOGDIR"/*.log 2>/dev/null); do
		[ -f "$_f" ] || continue
		_files="$_files $_f"
		_ln=$((_ln + 1))
		[ "$_ln" -ge 40 ] && break
	done

	if [ "$_ln" -eq 0 ]; then
		emit log.list_count 0
		return 0
	fi

	# shellcheck disable=SC2086
	awk -F, '
		function reset() {
			st = ""; en = ""; ab = 0; cnt = 0
			c0 = ""; c1 = ""; cf = ""; cl = ""
			tm = 0; im = 0; vm = 0; pm = 0
		}
		function flush() {
			if (nm == "") return
			printf "%s|%s|%s|%d|%d|%s|%s|%d|%d|%d|%d|%s|%s\n", \
				nm, st, en, ab, cnt, c0, c1, tm, im, vm, pm, cf, cl
		}
		FNR == 1 {
			flush(); reset()
			nm = FILENAME; sub(/.*\//, "", nm)
		}
		/^#start=/   { st = $0; sub(/^#start=/, "", st); next }
		/^#end=/     { en = $0; sub(/^#end=/, "", en);   next }
		/^#aborted=1/ { ab = 1; next }
		/^#/         { next }
		NF < 2       { next }
		{
			cnt++
			if (cnt == 1) c0 = $2
			c1 = $2
			if ($3 + 0 > tm) tm = $3 + 0
			i = $4 + 0; if (i < 0) i = -i
			v = $5 + 0
			if (i > im) im = i
			if (v > vm) vm = v
			p = 0
			if (NF >= 8 && $8 != "") p = ($8 + 0) / 1000      # uW -> mW
			if (p <= 0 && v > 0 && i > 0) p = (i / 1000) * (v / 1000) / 1000  # mA*mV/1000
			if (p > pm) pm = p
			if (cnt == 1) cf = $6
			cl = $6
		}
		END { flush() }
	' $_files 2>/dev/null | {
		_i=0
		while IFS= read -r _l; do
			case "$_l" in
				*'|'*) ;;
				*) continue ;;
			esac
			# 拆 13 段
			_r="$_l"
			_nm=${_r%%|*}; _r=${_r#*|}
			_st=${_r%%|*}; _r=${_r#*|}
			_en=${_r%%|*}; _r=${_r#*|}
			_ab=${_r%%|*}; _r=${_r#*|}
			_cn=${_r%%|*}; _r=${_r#*|}
			_p0=${_r%%|*}; _r=${_r#*|}
			_p1=${_r%%|*}; _r=${_r#*|}
			_tm=${_r%%|*}; _r=${_r#*|}
			_im=${_r%%|*}; _r=${_r#*|}
			_vm=${_r%%|*}; _r=${_r#*|}
			_pm=${_r%%|*}; _r=${_r#*|}
			_cf=${_r%%|*}; _r=${_r#*|}
			_cl=${_r}

			emit "log.$_i.name"     "$_nm"
			emit "log.$_i.start"    "$_st"
			emit "log.$_i.end"      "$_en"
			emit "log.$_i.aborted"  "$_ab"
			emit "log.$_i.samples"  "$_cn"
			emit "log.$_i.cap0"     "$_p0"
			emit "log.$_i.cap1"     "$_p1"
			emit "log.$_i.temp_max" "$_tm"
			emit "log.$_i.cur_max"  "$_im"
			emit "log.$_i.volt_max" "$_vm"
			emit "log.$_i.pmax_mw"  "$_pm"
			emit "log.$_i.cnt0"     "$_cf"
			emit "log.$_i.cnt1"     "$_cl"
			_i=$((_i + 1))
		done
		emit log.list_count "$_i"
	}
}

# -------------------------------------------------------------- 单个会话导出 ---
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

	_st=""; _en=""; _ab=0; _i=0
	while IFS= read -r _l || [ -n "$_l" ]; do
		case "$_l" in
			'#start='*)   _st=${_l#*=} ;;
			'#end='*)     _en=${_l#*=} ;;
			'#aborted=1') _ab=1 ;;
			'#'*|'')      ;;
			*)
				emit "session.s.$_i" "$_l"
				_i=$((_i + 1))
				[ "$_i" -ge 4000 ] && break
				;;
		esac
	done < "$_f"

	# 顺序无所谓，页面按 key 取值
	emit session.name    "$_name"
	emit session.start   "$_st"
	emit session.end     "$_en"
	emit session.aborted "$_ab"
	emit session.count   "$_i"
}

case "$MODE" in
	--logs) list_sessions; exit 0 ;;
	--log)  dump_session "$@"; exit 0 ;;
esac

# ============================================================ 实时采集 =========
emit time "$(date +%s 2>/dev/null)"
kv "$MODDIR/module.prop" version; emit module_version "$_KV"
kv "$MODDIR/module.prop" author;  emit module_author  "$_KV"

if command -v getprop >/dev/null 2>&1; then
	emit device_model "$(getprop ro.product.model 2>/dev/null)"
	emit device_slot  "$(getprop ro.boot.slot_suffix 2>/dev/null)"
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
	rv "$BATT/capacity";        emit capacity        "$_RV"
	rv "$BATT/status";          emit status          "$_RV"
	rv "$BATT/present";         emit present         "$_RV"
	rv "$BATT/health";          emit health          "$_RV"
	rv "$BATT/technology";      emit technology      "$_RV"
	rv "$BATT/temp";            emit temp_raw        "$_RV"
	rv "$BATT/current_now";     emit current_now     "$_RV"
	rv "$BATT/voltage_now";     emit voltage_now     "$_RV"
	rv "$BATT/power_now";       emit power_now       "$_RV"
	rv "$BATT/charge_counter";  emit charge_counter  "$_RV"
	rv "$BATT/charge_full";     emit charge_full     "$_RV"
	rv "$BATT/charge_full_design"; emit charge_full_design "$_RV"
	rv "$BATT/cycle_count";     emit cycle_count     "$_RV"
	rv "$BATT/current_avg";     emit current_avg     "$_RV"
	rv "$BATT/voltage_avg";     emit voltage_avg     "$_RV"
	rv "$BATT/system_temp_level"; emit batt_temp_level "$_RV"

	# 充电上限（部分机型由 thermal / 充电策略写入）
	rv "$BATT/input_current_limit";     emit input_current_limit "$_RV"
	rv "$BATT/constant_charge_current_max"; emit ccc_max         "$_RV"
	rv "$BATT/constant_charge_voltage_max"; emit ccv_max         "$_RV"
	rv "$BATT/charge_control_limit";    emit charge_control_limit "$_RV"
	rv "$BATT/step_charging_status";    emit step_charging_status "$_RV"
	rv "$BATT/charge_done";             emit charge_done      "$_RV"
	rv "$BATT/battery_charging_enabled"; emit charging_enabled "$_RV"
fi

# ------------------------------------------------------------------ 电源类型 ---
_srcs=""
for s in usb ac wireless dc pc_port; do
	[ -d "$PS/$s" ] || continue
	_srcs="$_srcs $s"
	rv "$PS/$s/online";      emit "src.${s}.online" "$_RV"
	rv "$PS/$s/type";        emit "src.${s}.type"   "$_RV"
	rv "$PS/$s/voltage_now"; emit "src.${s}.vnow"   "$_RV"
	rv "$PS/$s/current_max"; emit "src.${s}.imax"   "$_RV"
	rv "$PS/$s/voltage_max"; emit "src.${s}.vmax"   "$_RV"
done
emit src.list "$_srcs"

# USB 细节（PD/协议、实际功率）
if [ -d "$PS/usb" ]; then
	rv "$PS/usb/real_type";            emit usb_real_type   "$_RV"
	rv "$PS/usb/voltage_max";          emit usb_voltage_max "$_RV"
	rv "$PS/usb/current_max";          emit usb_current_max "$_RV"
	rv "$PS/usb/pd_active";            emit usb_pd_active   "$_RV"
	rv "$PS/usb/typec_cc_orientation"; emit usb_typec_cc_orientation "$_RV"
fi

# -------------------------------------------------------------------- 温度 ---
_n=0
_chg_temp=""
for z in "$SYS"/class/thermal/thermal_zone*; do
	[ -d "$z" ] || continue
	rv "$z/type"
	_t="$_RV"
	[ -n "$_t" ] || continue
	case "$_t" in
		*batt*|*BATT*|*charg*|*CHAR*|*usb*|*USB*|*typec*|*TYPEC*|*pmic*|*PMIC*|*pm[0-9]*|*bcl*|*chg*|*CHG*) ;;
		*) continue ;;
	esac
	rv "$z/temp"
	emit "thermal.$_n" "$_t|$_RV"
	case "$_t" in
		*batt*|*BATT*) ;;
		*) [ -n "$_chg_temp" ] || _chg_temp="$_RV" ;;
	esac
	_n=$((_n + 1))
	[ "$_n" -ge 10 ] && break
done
emit thermal.count "$_n"
emit chg_temp_raw  "$_chg_temp"

# ---------------------------------------------------------------- 模块状态 ---
# 没有「等待开机确认」这类状态了：模块不做开机确认。
# 判断有没有生效只看 last_head 与当前分区头部是否一致（--full 时才算）。
S="$MODDIR/state"

rv "$S/last_sha";       emit state_last_sha  "$_RV"
rv "$S/orig_sha";       emit state_orig_sha  "$_RV"
rv "$S/part";           emit state_part      "$_RV"
rv "$S/last_head";      emit state_last_head "$_RV"
rv "$S/boot_time";      emit state_boot_time "$_RV"
emit state_last_flash "$(stat -c %Y "$S/last_sha" 2>/dev/null)"

# 最近一次备份
_bk=$(ls -1t "$MODDIR/backup/"*.img 2>/dev/null | head -n 1)
if [ -n "$_bk" ]; then
	emit backup_file "$_bk"
	emit backup_size "$(stat -c %s "$_bk" 2>/dev/null)"
	emit backup_time "$(stat -c %Y "$_bk" 2>/dev/null)"
fi
_bc=0
for _b in "$MODDIR/backup/"*.img; do
	[ -f "$_b" ] && _bc=$((_bc + 1))
done
emit backup_count "$_bc"

# 目标温度窗口（配置里的，不是 dtbo 里的实际值）
kv "$CFG" FFC_TEMP_LOW;  emit cfg_ffc_low  "$_KV"
kv "$CFG" FFC_TEMP_HIGH; emit cfg_ffc_high "$_KV"
kv "$CFG" DRY_RUN;       emit cfg_dry_run  "$_KV"

# 档位名由温度窗口反推 —— config.conf 是唯一事实来源，
# 不额外记状态文件，避免两边对不上。
case "$_KV" in
	'') ;;
esac
kv "$CFG" FFC_TEMP_HIGH
case "$_KV" in
	48) emit cfg_tier safe ;;
	56) emit cfg_tier max ;;
	"") emit cfg_tier ref ;;
	*)  emit cfg_tier custom ;;
esac

# ------------------------------------------------------------ 充电日志状态 ---
log_state

# ------------------------------------------- 可选：当前分区是否仍是刷入的那份 ---
# 只在带 --full 时做。要读分区开头 1MB 算哈希，轮询时不该反复读盘。
# 系统 OTA 会把 dtbo 换回原厂，页面靠这两项提示「需要重新运行一次」。
if [ "$MODE" = "--full" ]; then
	rv "$S/part"
	_prt="$_RV"
	if [ -n "$_prt" ] && [ -r "$_prt" ]; then
		_cur=$(dd if="$_prt" bs=1048576 count=1 2>/dev/null \
			| sha256sum 2>/dev/null | cut -d' ' -f1)
		[ -n "$_cur" ] && emit state_cur_head "$_cur"
	fi
fi

exit 0
