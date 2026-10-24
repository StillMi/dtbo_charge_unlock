#!/system/bin/sh
# ============================================================================
# DTBO 有线充电限制解锁 —— 公共逻辑
#
# 流程:
#   1) 识别当前系统所在 A/B 槽位
#   2) 读取当前槽位的 dtbo 分区镜像，用内置 dtc 解包成 dts
#   3) 用 ref/patch.sed 改写有线充电限制（安全档 0~48℃ / 极限档 0~56℃ 全速），
#      并关闭 mca_charger_thermal
#   4) 重新打包成 dtbo 镜像，多重复核后刷回该槽位的 dtbo 分区
#
# 依赖: 只用设备自带的基础命令（sed/grep/cut/dd/od/cmp/sha256sum），
#       外加模块自带的静态 aarch64 dtc。不需要 awk、不需要 busybox。
#
# 什么时候写分区:
#   * 只有两个入口：安装时（customize.sh）、用户手动触发
#     （KernelSU 的「操作」按钮 / WebUI 的「运行修改」）
#   * 开机阶段**不会**自动刷写；系统 OTA 后 dtbo 回到原厂，需要手动再跑一次
#
# 安全机制:
#   * 刷写前把原始分区镜像备份到 backup/，并校验备份完整性
#   * 刷写前先「重新打包 -> 反编译 -> 逐条比对」，任何一条不通过就中止，
#     分区保持原样
#   * 刷写后回读分区比对 sha256，不一致立即回滚
#   * 记录「刷入后尚未确认开机成功」标记；若连续两次开机都没走完，
#     自动回滚原始镜像并停用本模块（防变砖循环）
#   * 已刷过的镜像按哈希识别，重复手动运行不会多刷一遍
# ============================================================================

MODDIR="${MODDIR:-${0%/*}}"
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/dtbo_charge_unlock

# ---------------------------------------------------------------- 默认配置 --
# FFC（全速充电）温度窗口，单位 ℃。置空表示沿用参考表原始数值（0~55）。
FFC_TEMP_LOW=0
FFC_TEMP_HIGH=56
# 参考表里使用的高温/低温边界值，用于把参考数值换算成上面的配置值。
FFC_REF_HIGH=55
FFC_REF_LOW=0
# 1 = 忽略「已刷过」判断，强制重新执行一次
FORCE=0
# 1 = 只解包/改写/打包/复核，不写分区（演练）
DRY_RUN=0
# 强制指定槽位：留空=自动识别；填 a 或 b=强制该槽位（恢复模式安装等识别不出时用）
FORCE_SLOT=
# 安装阶段刷写失败时是否中止安装：0=继续安装（下次开机再试），1=直接中止
ABORT_ON_INSTALL_FAIL=0
# 安装时跳过音量键选档、强制指定档位：留空=按键选；safe=0~48℃；max=0~56℃
FORCE_TIER=
# 安装时是否用音量键询问档位；1=询问（默认），0=不问（自动化测试用）
TIER_PROMPT="${TIER_PROMPT:-1}"

[ -f "$MODDIR/config.conf" ] && . "$MODDIR/config.conf"

STATE="$MODDIR/state"
BACKUP="$MODDIR/backup"
LOGDIR="$MODDIR/logs"
REF="$MODDIR/ref"
BINDIR="$MODDIR/bin"

INTERACTIVE="${INTERACTIVE:-0}"
# 安装阶段由 customize.sh 设为 1：日志同时打印到安装界面
INSTALL_MODE="${INSTALL_MODE:-0}"
# 只有开机脚本（post-fs-data.sh）会把它设为 1。
# 它决定 run_main 是否执行「开机确认 / 计数 / 自动回滚」这套状态机 ——
# 手动运行时不该碰这些，否则手动重刷会被「尚未确认开机成功」挡住。
BOOT_PHASE="${BOOT_PHASE:-0}"

# 对外展示用的模块路径：安装阶段实际目录是 modules_update/<id>，
# 重启后才会变成 modules/<id>。提示用户时统一用最终路径。
SHOWDIR="$MODDIR"
case "$MODDIR" in
	*/modules_update/*) SHOWDIR="/data/adb/modules/${MODDIR##*/}" ;;
esac

# ------------------------------------------------------------------- 工具 ---
# 日志一律写 stderr：函数的返回值（路径、数量）走 stdout，避免被日志污染。
log() {
	_msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
	[ -n "$LOGFILE" ] && echo "$_msg" >> "$LOGFILE" 2>/dev/null
	echo "$_msg" >&2
	if [ "$INSTALL_MODE" = "1" ]; then
		if command -v ui_print >/dev/null 2>&1; then
			ui_print "$_msg"
		fi
	fi
}

die() {
	log "错误: $*"
	log "已中止；dtbo 分区未被修改。"
	return 1
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" 2>/dev/null | cut -d' ' -f1
	else
		echo ""
	fi
}

file_size() {
	wc -c < "$1" 2>/dev/null | tr -d ' \t\r\n'
}

# 生成一个一次性令牌，用来把「某次刷写」和「某次开机确认」对应起来。
# 不用 boot_id 做这件事：某些环境（恢复模式、部分内核）读不到 boot_id，
# 空值会导致确认永远匹配不上，从而把正常开机误判成启动失败。
gen_token() {
	_t=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \t\r\n')
	[ -n "$_t" ] || _t=$(date +%s 2>/dev/null)$$
	echo "$_t"
}

# 本次开机的起始时刻（epoch 秒）= 当前时间 - 开机时长
boot_epoch() {
	_now=$(date +%s 2>/dev/null)
	case "$_now" in ''|*[!0-9]*) echo 0; return 0 ;; esac
	_up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
	_up=${_up%.*}
	case "$_up" in ''|*[!0-9]*) _up=0 ;; esac
	echo $((_now - _up))
}

# 判断某个状态文件是不是「本次开机内」写下的。
#   是  -> 说明刷写发生在本轮开机之后，新 dtbo 还没被加载
#   否  -> 说明刷写发生在更早的开机，本轮开机加载的就是新 dtbo
# 优先用 mtime 比较；拿不到 mtime 时退回 boot_id 比较。
flashed_this_boot() {
	_f="$1"
	[ -f "$_f" ] || return 1

	_ft=$(stat -c %Y "$_f" 2>/dev/null | tr -d ' \t\r\n')
	case "$_ft" in ''|*[!0-9]*) _ft=0 ;; esac
	if [ "$_ft" -gt 0 ] 2>/dev/null && [ "$BOOT_EPOCH" -gt 0 ] 2>/dev/null; then
		[ "$_ft" -ge "$BOOT_EPOCH" ] && return 0
		return 1
	fi

	# 退路：用 boot_id 比较
	_pb=$(cat "$STATE/pending_boot" 2>/dev/null)
	_cb=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
	[ -n "$_pb" ] && [ -n "$_cb" ] && [ "$_pb" = "$_cb" ] && return 0
	return 1
}

# 选一个可执行、可写的临时工作目录（tmpfs 优先，减少闪存写入）。
# 某些机型会对 /dev 或 /data/local/tmp 设 noexec，所以最后回退到模块目录。
pick_workdir() {
	# 需要放下 orig.img + new.img 两份分区镜像，外加 dtb 与 dtc，
	# 再留一点余量。分区是 32MB 时这里要 70MB 以上。
	_need_kb=0
	case "$PSIZE" in
		''|*[!0-9]*) ;;
		*) _need_kb=$(( PSIZE / 1024 * 2 + 16384 )) ;;
	esac

	for d in /dev/dtbo_charge_unlock /data/local/tmp/dtbo_charge_unlock "$MODDIR/tmp"; do
		mkdir -p "$d" 2>/dev/null || continue
		[ -w "$d" ] || continue
		printf '#!/system/bin/sh\nexit 0\n' > "$d/.wtest" 2>/dev/null || continue
		chmod 755 "$d/.wtest" 2>/dev/null
		if "$d/.wtest" >/dev/null 2>&1; then
			rm -f "$d/.wtest"
			if [ "$_need_kb" -gt 0 ]; then
				_avail=$(df -k "$d" 2>/dev/null | tail -n 1 \
					| tr -s ' \t' ' ' | cut -d' ' -f4 2>/dev/null)
				case "$_avail" in
					''|*[!0-9]*) ;;
					*)
						if [ "$_avail" -lt "$_need_kb" ]; then
							log "  $d 空间不足（可用 ${_avail}KB，需要 ${_need_kb}KB），换下一个"
							continue
						fi
						;;
				esac
			fi
			echo "$d"
			return 0
		fi
		rm -f "$d/.wtest"
	done
	return 1
}

# --------------------------------------------------------------- 槽位识别 ---
detect_slot() {
	_s=""

	# 配置里强制指定槽位（恢复模式安装等识别不出时用）
	case "$FORCE_SLOT" in
		a|A) _s="_a" ;;
		b|B) _s="_b" ;;
	esac
	if [ -n "$_s" ]; then
		log "使用 config.conf 指定的槽位: ${_s#_}"
	else
		_s=$(getprop ro.boot.slot_suffix 2>/dev/null)
		if [ -z "$_s" ]; then
			_v=$(getprop ro.boot.slot 2>/dev/null)
			case "$_v" in
				a|b) _s="_$_v" ;;
			esac
		fi
		if [ -z "$_s" ] && [ -r /proc/cmdline ]; then
			_s=$(tr ' ' '\n' < /proc/cmdline 2>/dev/null | sed -n 's/^androidboot\.slot_suffix=//p' | head -n1)
		fi
	fi

	case "$_s" in
		_a|_b) SLOT="$_s" ;;
		*)     SLOT="" ;;
	esac

	if [ -n "$SLOT" ]; then
		SLOTNAME="dtbo$SLOT"
		log "A/B 槽位: ${SLOT#_}（目标分区 $SLOTNAME）"
	else
		SLOTNAME="dtbo"
		log "未检测到 A/B 槽位，按单分区设备处理（目标分区 dtbo）"
	fi
}

# ------------------------------------------------------------- 定位分区 ---
resolve_partition() {
	_p=""
	for base in /dev/block/by-name /dev/block/bootdevice/by-name; do
		[ -d "$base" ] || continue
		if [ -e "$base/$SLOTNAME" ]; then
			_p="$base/$SLOTNAME"
			break
		fi
	done

	# A/B 设备上若当前槽位节点不存在，绝不回退去刷另一个槽位
	if [ -z "$_p" ] && [ -z "$SLOT" ] && [ -e /dev/block/by-name/dtbo ]; then
		_p=/dev/block/by-name/dtbo
	fi

	[ -n "$_p" ] || { die "找不到分区 $SLOTNAME 的设备节点"; return 1; }
	PART="$_p"

	REAL=$(readlink -f "$PART" 2>/dev/null)
	[ -n "$REAL" ] || REAL="$PART"
	DEVNAME=$(basename "$REAL")

	# 用 uevent 里的 PARTNAME 二次确认，防止刷错分区
	if [ -r "/sys/class/block/$DEVNAME/uevent" ]; then
		_pn=$(sed -n 's/^PARTNAME=//p' "/sys/class/block/$DEVNAME/uevent" 2>/dev/null | head -n1)
		if [ -n "$_pn" ] && [ "$_pn" != "$SLOTNAME" ]; then
			die "分区名校验失败：期望 $SLOTNAME，实际 $_pn（$PART）"
			return 1
		fi
		[ -n "$_pn" ] && log "分区名校验通过: $_pn"
	fi

	if [ -r "/sys/class/block/$DEVNAME/size" ]; then
		PSIZE=$(($(cat "/sys/class/block/$DEVNAME/size" 2>/dev/null) * 512))
	else
		PSIZE=$(blockdev --getsize64 "$PART" 2>/dev/null)
	fi
	if [ -z "$PSIZE" ] || [ "$PSIZE" -le 0 ] 2>/dev/null; then
		die "无法获取分区大小"
		return 1
	fi

	log "分区节点: $PART -> $REAL ($DEVNAME)"
	log "分区大小: $PSIZE 字节"
	return 0
}

# ------------------------------------------------------- 环境信息（仅记录）---
# 刻意不检查 bootloader 锁定状态 / verified boot 状态。
# KernelSU 会伪造这些属性（例如把 ro.boot.verifiedbootstate 报成 green），
# 按它们判断只会把正常设备误判成「已锁定」而拒绝刷写，纯属添乱。
# 实际能不能写分区，由下面 dd 的返回值说了算。
log_boot_state() {
	_locked=$(getprop ro.boot.flash.locked 2>/dev/null)
	_vb=$(getprop ro.boot.verifiedbootstate 2>/dev/null)
	log "bootloader 属性（仅供参考，不据此拦截）: flash.locked=${_locked:-?} verifiedbootstate=${_vb:-?}"
	return 0
}

# --------------------------------------------------------------- 解包工具 ---
prepare_dtc() {
	DTC="$WORK/dtc"
	cp "$BINDIR/dtc-aarch64" "$DTC" 2>/dev/null || { die "复制 dtc 失败"; return 1; }
	chmod 755 "$DTC" 2>/dev/null
	"$DTC" --version >/dev/null 2>&1 || { die "内置 dtc 无法执行（$DTC）"; return 1; }
	log "dtc: $("$DTC" --version 2>&1 | head -n1)"
	return 0
}

# --------------------------------------------------------- 二进制小工具 ---
# DTBO 表的字节序有两种实际存在：
#   le —— 官方 mkdtimg 的标准输出（magic 在文件里是 1e ab b7 d7）
#   be —— 少数厂商/工具的输出（magic 在文件里是 d7 b7 ab 1e）
# 由 detect_format 设置 DT_ENDIAN，下面几个函数都按它解释/写出整数。

# 取文件指定偏移处 N 字节的十六进制串（按文件顺序，去空格）
# 用 tail -c 定位：busybox/GNU 的 tail 会 seek，比 dd bs=1 skip=大偏移快得多
hex_at() {
	if [ "${2:-0}" -eq 0 ]; then
		head -c "${3:-16}" "$1" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \t\r\n'
	else
		tail -c +$(($2 + 1)) "$1" 2>/dev/null \
			| head -c "${3:-16}" | od -An -tx1 2>/dev/null | tr -d ' \t\r\n'
	fi
}

# 取文件前 N 字节的十六进制串
hex_head() {
	hex_at "$1" 0 "${2:-16}"
}

# 读文件某处 4 字节，按 DT_ENDIAN 解释成无符号整数
u32_at() {
	_h=$(hex_at "$1" "$2" 4)
	[ ${#_h} -eq 8 ] || { echo ""; return 1; }
	if [ "$DT_ENDIAN" = "be" ]; then
		echo $((0x$_h))
	else
		# 文件里是 LSB 在前，拼成便于 $((0x..)) 的大端顺序
		_b1=${_h%??????}
		_t=${_h#??}; _b2=${_t%????}
		_t=${_h#????}; _b3=${_t%??}
		_b4=${_h#??????}
		echo $((0x$_b4$_b3$_b2$_b1))
	fi
}

# 把 4 字节整数（按 DT_ENDIAN）写到 stdout
put_u32() {
	_v=$1
	_b0=$((_v & 255)); _b1=$(((_v >> 8) & 255))
	_b2=$(((_v >> 16) & 255)); _b3=$(((_v >> 24) & 255))
	if [ "$DT_ENDIAN" = "be" ]; then
		_esc=$(printf '\\0%03o\\0%03o\\0%03o\\0%03o' "$_b3" "$_b2" "$_b1" "$_b0")
	else
		_esc=$(printf '\\0%03o\\0%03o\\0%03o\\0%03o' "$_b0" "$_b1" "$_b2" "$_b3")
	fi
	printf '%b' "$_esc"
}

# 把 4 字节整数就地写到文件指定偏移
poke_u32() {
	put_u32 "$3" | dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null
}

align_up() {
	echo $(( ($1 + $2 - 1) / $2 * $2 ))
}

# 读 FDT 头，输出 "magic totalsize"（FDT 内部固定大端）
fdt_head() {
	_h=$(hex_at "$1" "$2" 8)
	if [ ${#_h} -ne 16 ]; then
		echo "none 0"
		return 0
	fi
	echo "${_h%????????} $((0x${_h#????????}))"
}

# ------------------------------------------------------------ 镜像格式 ---
#   fdt  : 裸 DTB 串接（少数老设备 / 早期方案），每个 DTB 以 d00dfeed 开头
#   dtbo : Android DTBO 表，结构为 dt_table_header（32 字节）
#            u32 magic = 0xd7b7ab1e
#            u32 total_size
#            u32 header_size
#            u32 dt_entry_size
#            u32 dt_entry_count
#            u32 dt_entries_offset
#            u32 page_size
#            u32 version
#          紧跟 dt_entry_count 个 dt_table_entry（每个 32 字节）
#            u32 dt_size
#            u32 dt_offset
#            u32 id
#            u32 rev
#            u32 custom[4]
# 字节序：官方 mkdtimg 用小端，但也有设备用大端，两种都要认。
detect_format() {
	_h=$(hex_head "$1" 4)
	case "$_h" in
		d00dfeed) IMG_FORMAT="fdt";  DT_ENDIAN="le" ;;
		1eabb7d7) IMG_FORMAT="dtbo"; DT_ENDIAN="le" ;;
		d7b7ab1e) IMG_FORMAT="dtbo"; DT_ENDIAN="be" ;;
		*)        IMG_FORMAT="";     DT_ENDIAN="le" ;;
	esac
	[ -n "$IMG_FORMAT" ]
}

# 解析 DTBO 表头，结果放在 DT_* 变量里
parse_dtbo_header() {
	_img="$1"
	DT_TOTAL=$(u32_at "$_img" 4)
	DT_HDRSZ=$(u32_at "$_img" 8)
	DT_ENTSZ=$(u32_at "$_img" 12)
	DT_CNT=$(u32_at "$_img" 16)
	DT_EOFF=$(u32_at "$_img" 20)
	DT_PAGE=$(u32_at "$_img" 24)
	DT_VER=$(u32_at "$_img" 28)

	log "DTBO 表: 条目 $DT_CNT 个，表头 $DT_HDRSZ 字节，条目 $DT_ENTSZ 字节，页 $DT_PAGE 字节，version $DT_VER，字节序 $DT_ENDIAN"

	case "$DT_HDRSZ" in ''|*[!0-9]*) log "表头长度非法"; return 1 ;; esac
	case "$DT_ENTSZ" in ''|*[!0-9]*) log "条目长度非法"; return 1 ;; esac
	case "$DT_CNT"   in ''|*[!0-9]*) log "条目数非法";   return 1 ;; esac
	case "$DT_EOFF"  in ''|*[!0-9]*) log "条目表偏移非法"; return 1 ;; esac
	case "$DT_PAGE"  in ''|*[!0-9]*) log "页大小非法";   return 1 ;; esac
	case "$DT_TOTAL" in ''|*[!0-9]*) log "total_size 非法"; return 1 ;; esac

	[ "$DT_TOTAL" -le "$PSIZE" ] \
		|| { log "total_size $DT_TOTAL 超过分区 $PSIZE"; return 1; }

	[ "$DT_HDRSZ" -ge 32 ] || { log "表头长度 $DT_HDRSZ < 32"; return 1; }
	[ "$DT_ENTSZ" -ge 32 ] || { log "条目长度 $DT_ENTSZ < 32"; return 1; }
	[ "$DT_CNT" -ge 1 ] && [ "$DT_CNT" -le 64 ] || { log "条目数 $DT_CNT 不合理"; return 1; }
	[ "$DT_EOFF" -ge "$DT_HDRSZ" ] || { log "条目表偏移 $DT_EOFF < 表头长度 $DT_HDRSZ"; return 1; }
	[ "$DT_PAGE" -ge 1 ] || { log "页大小 $DT_PAGE 不合理"; return 1; }
	[ $((DT_EOFF % 4)) -eq 0 ] || { log "条目表偏移 $DT_EOFF 不是 4 字节对齐"; return 1; }
	[ $((DT_ENTSZ % 4)) -eq 0 ] || { log "条目长度 $DT_ENTSZ 不是 4 字节对齐"; return 1; }

	_base=$((DT_EOFF + DT_CNT * DT_ENTSZ))
	[ "$_base" -le "$PSIZE" ] || { log "条目表超出分区（$_base > $PSIZE）"; return 1; }
	return 0
}

# 把分区镜像拆成若干 dtb：$WORK/dtb.0 ... $WORK/dtb.$((CNT-1))
# 结果放在全局变量 CNT 里（不能用 $(...) 调用：子 shell 会丢掉
# IMG_FORMAT / DT_* 这些后续打包要用的变量）
split_dtbs() {
	_img="$1"
	CNT=0
	if ! detect_format "$_img"; then
		log "分区开头不是可识别的镜像格式（既不是 DTB 的 d00dfeed，也不是 DTBO 表的 0xd7b7ab1e 大/小端表示），前 16 字节: $(hex_head "$_img" 16)"
		return 1
	fi

	if [ "$IMG_FORMAT" = "dtbo" ]; then
		split_dtbo_table "$_img"
		return $?
	fi

	_off=0
	_idx=0
	while [ "$_off" -lt "$PSIZE" ] && [ "$_idx" -lt 16 ]; do
		_head=$(fdt_head "$_img" "$_off")
		_magic=${_head% *}
		_total=${_head#* }
		[ "$_magic" = "d00dfeed" ] || break
		if [ -z "$_total" ] || [ "$_total" -lt 40 ] 2>/dev/null; then
			break
		fi
		[ $((_off + _total)) -le "$PSIZE" ] || break

		tail -c +$((_off + 1)) "$_img" 2>/dev/null | head -c "$_total" > "$WORK/dtb.$_idx"
		[ "$(file_size "$WORK/dtb.$_idx")" = "$_total" ] || break
		log "  DTB #$_idx：偏移 $_off，长度 $_total 字节"

		_idx=$((_idx + 1))
		_off=$((_off + _total))
	done
	CNT=$_idx
	[ "$CNT" -ge 1 ]
}

# DTBO 表格式的拆分
split_dtbo_table() {
	_img="$1"
	parse_dtbo_header "$_img" || return 1

	_idx=0
	while [ "$_idx" -lt "$DT_CNT" ]; do
		_eo=$((DT_EOFF + _idx * DT_ENTSZ))
		_sz=$(u32_at "$_img" "$_eo")
		_dof=$(u32_at "$_img" $((_eo + 4)))

		case "$_sz"  in ''|*[!0-9]*) log "条目 #$_idx 长度非法"; return 1 ;; esac
		case "$_dof" in ''|*[!0-9]*) log "条目 #$_idx 偏移非法"; return 1 ;; esac
		[ "$_sz" -ge 40 ] || { log "条目 #$_idx 长度 $_sz 太小"; return 1; }
		[ $((_dof + _sz)) -le "$PSIZE" ] \
			|| { log "条目 #$_idx 超出分区（$_dof+$_sz > $PSIZE）"; return 1; }

		tail -c +$((_dof + 1)) "$_img" 2>/dev/null | head -c "$_sz" > "$WORK/dtb.$_idx"
		[ "$(file_size "$WORK/dtb.$_idx")" = "$_sz" ] \
			|| { log "条目 #$_idx 截取失败"; return 1; }

		# 原样留一份 32 字节条目，打包时只改前 8 字节（长度/偏移），
		# id / rev / custom 全部保持原值
		dd if="$_img" bs=4 skip=$((_eo / 4)) count=$((DT_ENTSZ / 4)) \
			of="$WORK/ent.$_idx" 2>/dev/null

		_m=$(hex_head "$WORK/dtb.$_idx" 4)
		if [ "$_m" != "d00dfeed" ]; then
			log "条目 #$_idx 的内容不是 DTB（magic $_m）"
			return 1
		fi
		log "  DTB #$_idx：表偏移 $_dof，长度 $_sz 字节（id=$(u32_at "$_img" $((_eo + 8))) rev=$(u32_at "$_img" $((_eo + 12)))）"

		_idx=$((_idx + 1))
	done
	CNT=$_idx
	[ "$CNT" -ge 1 ]
}

# 把若干 dtb 拼成一个正好 PSIZE 字节的分区镜像
pack_image() {
	_out="$1"
	shift
	if [ "$IMG_FORMAT" = "dtbo" ]; then
		pack_dtbo_table "$_out" "$@"
		return $?
	fi
	: > "$_out" || return 1
	for _f in "$@"; do
		cat "$_f" >> "$_out" || return 1
	done
	pad_to_partition "$_out"
}

# DTBO 表格式的打包：沿用原表头与条目，只更新 total_size 与每个条目的
# 长度/偏移，再按原镜像的布局风格重新铺开。
pack_dtbo_table() {
	_out="$1"
	shift

	_base=$((DT_EOFF + DT_CNT * DT_ENTSZ))
	head -c "$_base" "$ORIG" > "$_out" 2>/dev/null || return 1
	[ "$(file_size "$_out")" = "$_base" ] || return 1

	# ---- 判断原镜像用的布局风格 ----
	#   page : 每个 dtb 都按 page_size 对齐（标准 mkdtimg）
	#   gap  : 条目之间不留对齐填充，紧挨着排（部分厂商，例如小米这台）
	# 两种都按原样复现，生成的表结构与原厂保持一致。
	DT_LAYOUT="gap"
	_chk=$_base
	_i=0
	_page_ok=1
	while [ "$_i" -lt "$DT_CNT" ]; do
		_eo=$((DT_EOFF + _i * DT_ENTSZ))
		_osz=$(u32_at "$ORIG" "$_eo")
		_oof=$(u32_at "$ORIG" $((_eo + 4)))
		[ -n "$_osz" ] && [ -n "$_oof" ] || { _page_ok=0; break; }
		[ "$(align_up "$_chk" "$DT_PAGE")" = "$_oof" ] || { _page_ok=0; break; }
		_chk=$((_oof + _osz))
		_i=$((_i + 1))
	done
	[ "$_page_ok" = "1" ] && DT_LAYOUT="page"
	log "  条目布局: $DT_LAYOUT"

	# 第一遍：算出每个 dtb 的新偏移并写回条目表
	_ocur=$_base
	_ncur=$_base
	_i=0
	for _f in "$@"; do
		[ "$_i" -lt "$DT_CNT" ] || return 1
		_sz=$(file_size "$_f")
		[ -n "$_sz" ] && [ "$_sz" -ge 40 ] || return 1
		_eo=$((DT_EOFF + _i * DT_ENTSZ))

		_osz=$(u32_at "$ORIG" "$_eo")
		_oof=$(u32_at "$ORIG" $((_eo + 4)))
		[ -n "$_osz" ] && [ -n "$_oof" ] || return 1

		if [ "$DT_LAYOUT" = "page" ]; then
			_off=$(align_up "$_ncur" "$DT_PAGE")
		else
			# 保留原镜像在该条目之前的填充量，内容大小变化时后续条目顺移
			_gap=$((_oof - _ocur))
			[ "$_gap" -ge 0 ] || _gap=0
			_off=$((_ncur + _gap))
		fi

		poke_u32 "$_out" "$_eo" "$_sz"      || return 1
		poke_u32 "$_out" $((_eo + 4)) "$_off" || return 1

		_ocur=$((_oof + _osz))
		_ncur=$((_off + _sz))
		_i=$((_i + 1))
	done
	[ "$_i" -eq "$DT_CNT" ] || { log "条目数与 dtb 个数不一致（$DT_CNT vs $_i）"; return 1; }
	[ "$_ncur" -le "$PSIZE" ] || { log "新镜像 $_ncur 字节，超过分区 $PSIZE"; return 1; }

	poke_u32 "$_out" 4 "$_ncur" || return 1

	# 第二遍：按偏移铺开 dtb，空隙补零
	_i=0
	for _f in "$@"; do
		_eo=$((DT_EOFF + _i * DT_ENTSZ))
		_off=$(u32_at "$_out" $((_eo + 4)))
		_cursz=$(file_size "$_out")
		_pad=$((_off - _cursz))
		if [ "$_pad" -gt 0 ]; then
			dd if=/dev/zero bs=4096 count=$((_pad / 4096 + 1)) 2>/dev/null \
				| head -c "$_pad" >> "$_out" || return 1
		fi
		cat "$_f" >> "$_out" || return 1
		_i=$((_i + 1))
	done

	pad_to_partition "$_out"
}

# 补零到分区末尾
pad_to_partition() {
	_out="$1"
	_cursz=$(file_size "$_out")
	[ -n "$_cursz" ] && [ "$_cursz" -le "$PSIZE" ] || return 1
	_pad=$((PSIZE - _cursz))
	if [ "$_pad" -gt 0 ]; then
		dd if=/dev/zero bs=4096 count=$((_pad / 4096 + 1)) 2>/dev/null \
			| head -c "$_pad" >> "$_out" || return 1
	fi
	[ "$(file_size "$_out")" = "$PSIZE" ] || return 1
	return 0
}

# 打包后再拆一遍，确认每个 dtb 都能原样取出来
verify_image() {
	_img="$1"
	shift
	split_dtbs "$_img" || return 1
	[ "$CNT" = "$#" ] || { log "回拆数量 $CNT != $#"; return 1; }
	_i=0
	for _f in "$@"; do
		cmp -s "$WORK/dtb.$_i" "$_f" \
			|| { log "回拆的第 $_i 个 DTB 与写入内容不一致"; return 1; }
		_i=$((_i + 1))
	done
	return 0
}

# 直接流式读取分区算 sha256：不落地一份 PSIZE 大小的副本。
# 分区动辄 32MB，加上 orig.img / new.img，临时目录（/dev 是 tmpfs）
# 一次要吃掉三份，能省一份是一份。
read_partition_sha() {
	dd if="$PART" bs=1048576 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1
}

# ------------------------------------------------------- 安装时选择温度档位 ---
# 安装阶段用音量键选：音量下 = 安全档 0~48℃，音量上 = 极限档 0~56℃。
# 选择结果直接改写 config.conf 的 FFC_TEMP_HIGH，作为唯一事实来源 ——
# 这样开机重刷、OTA 后自动重应用都会沿用同一档位，不会两边对不上。
TIER_SAFE_HIGH=48
TIER_MAX_HIGH=56

# 从 getevent -l 的一行输出里认出音量键。输出 volumeup / volumedown / none
key_name_from_event() {
	while IFS= read -r _line; do
		case "$_line" in
			*KEY_VOLUMEDOWN*) echo volumedown; return 0 ;;
			*KEY_VOLUMEUP*)   echo volumeup;   return 0 ;;
		esac
	done
	echo none
}

# 等一次音量键。没有 getevent / timeout / 权限都返回 none，绝不卡住流程。
read_volume_key() {
	_secs="${1:-10}"
	command -v getevent >/dev/null 2>&1 || { echo none; return 0; }
	command -v timeout  >/dev/null 2>&1 || { echo none; return 0; }
	timeout "$_secs" getevent -ql 2>/dev/null | key_name_from_event
}

# 把高温边界写回 config.conf
set_ffc_high() {
	[ -f "$MODDIR/config.conf" ] || return 1
	if grep -q '^FFC_TEMP_HIGH=' "$MODDIR/config.conf" 2>/dev/null; then
		sed -i "s|^FFC_TEMP_HIGH=.*|FFC_TEMP_HIGH=$1|" "$MODDIR/config.conf"
	else
		printf 'FFC_TEMP_HIGH=%s\n' "$1" >> "$MODDIR/config.conf"
	fi
}

# 安装时选档位。成功返回 0；写配置失败返回 1（调用方决定是否中止）
tier_pick() {
	case "$FORCE_TIER" in
		safe|max)
			log "config.conf 指定了 FORCE_TIER=$FORCE_TIER，跳过按键选择"
			_tier="$FORCE_TIER"
			;;
		"")
			if [ "$TIER_PROMPT" = "1" ]; then
				log "----------------------------------------------"
				log " 选择充电温度档位（10 秒内按音量键）"
				log "   音量下键 -> 安全档 0~${TIER_SAFE_HIGH}℃ 全速"
				log "   音量上键 -> 极限档 0~${TIER_MAX_HIGH}℃ 全速"
				log "   不按     -> 保持 config.conf 当前值"
				log "等待按键…"
				_key=$(read_volume_key 10)
				log "按键结果: $_key"
				case "$_key" in
					volumedown) _tier=safe ;;
					volumeup)   _tier=max ;;
					*)          _tier=keep ;;
				esac
			else
				_tier=keep
			fi
			;;
		*)
			log "FORCE_TIER=$FORCE_TIER 无法识别（只支持 safe / max），保持当前设置"
			_tier=keep
			;;
	esac

	case "$_tier" in
		safe)
			if set_ffc_high "$TIER_SAFE_HIGH"; then
				FFC_TEMP_HIGH="$TIER_SAFE_HIGH"
				log "已选【安全档】：0~${TIER_SAFE_HIGH}℃ 全速"
			else
				log "无法写入 config.conf，安全档未生效"
				return 1
			fi
			;;
		max)
			if set_ffc_high "$TIER_MAX_HIGH"; then
				FFC_TEMP_HIGH="$TIER_MAX_HIGH"
				log "已选【极限档】：0~${TIER_MAX_HIGH}℃ 全速"
			else
				log "无法写入 config.conf，极限档未生效"
				return 1
			fi
			;;
		*)
			log "使用 config.conf 当前设置：FFC_TEMP_HIGH=${FFC_TEMP_HIGH:-（空，沿用参考表 ${FFC_REF_HIGH}）}"
			;;
	esac
	return 0
}

# 一句话描述当前档位（从 FFC_TEMP_HIGH 反推，用于安装总结/日志）
tier_desc() {
	case "$FFC_TEMP_HIGH" in
		48) echo "安全档 0~48℃ 全速" ;;
		56) echo "极限档 0~56℃ 全速" ;;
		"") echo "参考表原始值（0~${FFC_REF_HIGH}℃ 全速）" ;;
		*)  echo "自定义 0~${FFC_TEMP_HIGH}℃ 全速" ;;
	esac
}

# --------------------------------------------------- 生成运行时改写/校验集 --
build_runtime_rules() {
	if [ -n "$FFC_TEMP_HIGH" ]; then
		HI="$FFC_TEMP_HIGH"
	else
		HI="$FFC_REF_HIGH"
	fi
	if [ -n "$FFC_TEMP_LOW" ]; then
		LO="$FFC_TEMP_LOW"
	else
		LO="$FFC_REF_LOW"
	fi
	HIHEX=$(printf '0x%02x' "$HI" 2>/dev/null)
	LOHEX=$(printf '0x%02x' "$LO" 2>/dev/null)
	[ -n "$HIHEX" ] || HIHEX="0x$(printf '%02x' "$HI")"
	[ -n "$LOHEX" ] || LOHEX="0x$(printf '%02x' "$LO")"

	sed -e "s/@FFC_HIGH_HEX@/$HIHEX/g" \
	    -e "s/@FFC_HIGH@/$HI/g" \
	    -e "s/@FFC_LOW_HEX@/$LOHEX/g" \
	    "$REF/patch.sed" > "$WORK/patch.sed" || return 1

	rm -rf "$WORK/expect"
	mkdir -p "$WORK/expect" || return 1
	for _f in "$REF"/expect/*.txt; do
		[ -f "$_f" ] || return 1
		_b=${_f##*/}
		sed -e "s/@FFC_HIGH_HEX@/$HIHEX/g" \
		    -e "s/@FFC_HIGH@/$HI/g" \
		    -e "s/@FFC_LOW_HEX@/$LOHEX/g" \
		    "$_f" > "$WORK/expect/$_b" || return 1
	done

	log "FFC 温度窗口: ${LO}~${HI} ℃（改写与校验规则已按此生成）"
	return 0
}

# 逐条核对：目标节点里每个属性都必须是我们期望的取值
verify_dts() {
	_dts="$1"
	_bad=0
	for _f in "$WORK"/expect/*.txt; do
		_node=${_f##*/}
		_node=${_node%.txt}
		sed -n "/^[[:space:]]*\([^[:space:]:]*:[[:space:]]*\)\{0,1\}${_node}[[:space:]]*{/,/^[[:space:]]*};/p" \
			"$_dts" > "$WORK/block.dts" 2>/dev/null
		if [ ! -s "$WORK/block.dts" ]; then
			echo "MISSING NODE $_node" >&2
			_bad=1
			continue
		fi
		while IFS= read -r _want; do
			[ -n "$_want" ] || continue
			if ! grep -qF "$_want" "$WORK/block.dts" 2>/dev/null; then
				echo "MISMATCH $_node: $_want" >&2
				_bad=1
			fi
		done < "$_f"
	done
	rm -f "$WORK/block.dts"
	return $_bad
}

# ---------------------------------------------------------------- 主流程 ---

# ------------------------------------------------- 开机守护（只判断不刷写） ---
# 只处理「上一次刷写是否成功启动过」，**绝不主动改写 dtbo**。
#
# 模块只在两种时候写分区：
#   1) 安装时      customize.sh
#   2) 用户手动触发 KernelSU 的「操作」按钮 / WebUI 的「运行修改」
# 开机阶段不自动重新应用 —— 系统 OTA 后 dtbo 回到原厂，需要用户自己再跑一次。
#
# 这里保留的只有安全兜底：
#   * 已确认启动 → 清掉 pending 标记
#   * 连续 3 次开机都没走到开机后期 → 写回备份并停用（防止变砖循环）
#
# 返回值: 0=可以继续  1=本次不刷写（刚刷过/等确认/已停用）  2=出错或已回滚
boot_guard() {
	[ -n "$BOOT_EPOCH" ] || BOOT_EPOCH=$(boot_epoch)
	[ -n "$CUR_BOOT" ] || CUR_BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)

	[ -f "$STATE/pending" ] || return 0

	_pid=$(cat "$STATE/pending_id" 2>/dev/null)
	_cf=$(cat "$STATE/confirmed" 2>/dev/null)

	if flashed_this_boot "$STATE/pending"; then
		log "本次开机内刚刷写过 dtbo，需重启后才生效，本次不做处理"
		return 1
	fi

	if [ -n "$_pid" ] && [ "$_cf" = "$_pid" ]; then
		log "上次刷入的 dtbo 已确认可正常开机"
		rm -f "$STATE/pending" "$STATE/pending_boot" "$STATE/pending_id" \
		      "$STATE/pending_tries" "$STATE/pending_tries_boot" "$STATE/confirmed"
		return 0
	fi

	_tries=$(cat "$STATE/pending_tries" 2>/dev/null)
	[ -n "$_tries" ] || _tries=0

	# 同一次开机里只计一次：post-fs-data 跑过之后，用户可能又手动运行了一次
	_tb=$(cat "$STATE/pending_tries_boot" 2>/dev/null)
	if [ -n "$CUR_BOOT" ] && [ -n "$_tb" ] && [ "$_tb" = "$CUR_BOOT" ]; then
		log "本次开机已计过一次（当前第 $_tries 次未确认），不重复计数"
		return 1
	fi

	_tries=$((_tries + 1))
	echo "$_tries" > "$STATE/pending_tries"
	[ -n "$CUR_BOOT" ] && echo "$CUR_BOOT" > "$STATE/pending_tries_boot"

	if [ "$_tries" -lt 3 ]; then
		log "上次刷入的 dtbo 尚未确认开机成功（刷写后第 $_tries 次开机），本次不刷写"
		return 1
	fi

	# ---- 连续没确认，回滚 ----
	_bk=$(cat "$STATE/pending" 2>/dev/null)
	log "刷写后连续 $_tries 次开机都没走到开机后期，判定新 dtbo 有问题，开始回滚"
	if [ -z "$_bk" ] || [ ! -f "$_bk" ]; then
		log "找不到备份文件，无法回滚"
		return 2
	fi

	# 只有真要写回分区时才去定位分区
	if [ -z "$PART" ]; then
		detect_slot
		resolve_partition || { log "无法定位分区，回滚失败"; return 2; }
	fi

	dd if="$_bk" of="$PART" bs=1048576 conv=fsync 2>/dev/null || log "回滚写入失败！"
	sync
	if [ "$(sha256_of "$_bk")" = "$(read_partition_sha)" ]; then
		log "回滚校验通过，原始 dtbo 已恢复"
		rm -f "$STATE/pending" "$STATE/pending_boot" "$STATE/pending_id" \
		      "$STATE/pending_tries" "$STATE/pending_tries_boot" "$STATE/confirmed"
		echo "rolled-back $(date '+%Y-%m-%d %H:%M:%S')" > "$STATE/halted"
		log "已回滚并停用本模块。确认无误后删除 $STATE/halted 可重新启用。"
		return 2
	fi
	log "回滚校验失败！请用 fastboot 手工刷回: $_bk"
	return 2
}

# 手动运行（安装 / 操作按钮 / WebUI）时的收尾：只清掉「已确认开机成功」的
# pending，不计数、不回滚、也不阻断 —— 手动刷写随时可以重新来一次，
# 新的刷写会把 pending 换成新的，重新开始等确认。
pending_housekeeping() {
	[ -f "$STATE/pending" ] || return 0
	_pid=$(cat "$STATE/pending_id" 2>/dev/null)
	_cf=$(cat "$STATE/confirmed" 2>/dev/null)
	if [ -n "$_pid" ] && [ "$_cf" = "$_pid" ]; then
		log "上次刷入的 dtbo 已确认可正常开机"
		rm -f "$STATE/pending" "$STATE/pending_boot" "$STATE/pending_id" \
		      "$STATE/pending_tries" "$STATE/pending_tries_boot" "$STATE/confirmed"
	fi
	return 0
}

run_main() {
	mkdir -p "$STATE" "$BACKUP" "$LOGDIR" 2>/dev/null
	if [ -z "$LOGFILE" ]; then
		LOGFILE="$LOGDIR/$(date '+%Y%m%d').log"
	fi

	log "=========== dtbo_charge_unlock 开始 ==========="

	for f in "$REF/patch.sed" "$BINDIR/dtc-aarch64"; do
		[ -f "$f" ] || { die "模块文件缺失: $f"; return 1; }
	done

	detect_slot
	resolve_partition || return 1
	log_boot_state

	WORK=$(pick_workdir)
	[ -n "$WORK" ] || { die "找不到可写且可执行的临时目录"; return 1; }
	log "工作目录: $WORK"
	rm -f "$WORK"/dtb.* "$WORK"/orig.img "$WORK"/new.img 2>/dev/null

	CUR_BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
	BOOT_EPOCH=$(boot_epoch)

	# ---- 上一次刷写后的开机确认 / 自动回滚 ----
	# 「新 dtbo 没问题」的唯一判据是 service.sh 在开机后期写入了 confirmed
	# （能走到开机后期就说明没卡在启动阶段）。
	# 刻意不用「距刷写已过 N 分钟」之类的兜底判据：安装阶段刷写时系统正跑在
	# 旧 dtbo 上，运行时长完全不能证明新 dtbo 可用，用时间兜底会把「刷完就
	# 起不来」误判成成功，反而丢掉自动回滚保护。
	if [ "$BOOT_PHASE" = "1" ]; then
		boot_guard
		case $? in
			0) ;;
			1) log "=========== 结束（跳过） ==========="; return 0 ;;
			*) return 1 ;;
		esac
	else
		pending_housekeeping
	fi

	if [ -f "$STATE/halted" ]; then
		log "模块处于停用状态（$STATE/halted）。删除该文件可重新启用。"
		return 0
	fi

	# ---- 读取当前分区镜像 ----
	ORIG="$WORK/orig.img"
	log "读取分区到 $ORIG ..."
	dd if="$PART" of="$ORIG" bs=1048576 2>/dev/null
	_rsz=$(file_size "$ORIG")
	if [ -z "$_rsz" ] || [ "$_rsz" -lt 40 ] 2>/dev/null; then
		die "读取分区失败（只读到 ${_rsz:-0} 字节）"
		return 1
	fi

	ORIG_SHA=$(sha256_of "$ORIG")
	log "当前镜像 sha256: ${ORIG_SHA:-<无 sha256sum>}"

	# ---- 已经是我们刷过的镜像？----
	# 注意不能只看分区哈希：手动触发的场景里，用户可能只改了 config.conf 的
	# 温度档位（48 ↔ 56），分区内容没变但目标已经不同，这时候必须重新刷。
	_hi_now="${FFC_TEMP_HIGH:-$FFC_REF_HIGH}"
	if [ "$FORCE" != "1" ] && [ -f "$STATE/last_sha" ]; then
		_last=$(cat "$STATE/last_sha" 2>/dev/null)
		if [ -n "$_last" ] && [ "$_last" = "$ORIG_SHA" ]; then
			_hi_prev=$(cat "$STATE/flash_high" 2>/dev/null)
			if [ "$_hi_prev" = "$_hi_now" ]; then
				log "当前 dtbo 已经是本模块刷入的版本，无需重复刷写。"
				log "=========== 结束（跳过） ==========="
				return 0
			fi
			if [ -n "$_hi_prev" ]; then
				log "温度档位变了（上次刷入 ${_hi_prev}℃，当前 ${_hi_now}℃），重新刷写。"
			else
				log "没有记录上次刷入的档位（旧版本留下的状态），重新刷写一次对齐。"
			fi
		fi
	fi

	build_runtime_rules || { die "生成运行时改写规则失败"; return 1; }

	# ---- 解包 / 改写 / 打包 ----
	prepare_dtc || return 1
	split_dtbs "$ORIG"
	if [ "$CNT" -lt 1 ] 2>/dev/null; then
		die "无法从分区里拆出 DTB（格式 $( [ -n "$IMG_FORMAT" ] && echo "$IMG_FORMAT" || echo 未知 )，前 16 字节 $(hex_head "$ORIG" 16)）"
		return 1
	fi
	log "共 $CNT 个 DTB 需要处理（格式 $IMG_FORMAT）"

	_i=0
	_outs=""
	_nopat=0
	while [ "$_i" -lt "$CNT" ]; do
		log "---- DTB #$_i ----"

		"$DTC" -I dtb -O dts -o "$WORK/$_i.dts" "$WORK/dtb.$_i" 2>"$WORK/$_i.dec.err" \
			|| { die "DTB #$_i 反编译失败：$(tail -n 3 "$WORK/$_i.dec.err" 2>/dev/null | tr '\n' ' ')"; return 1; }
		log "  反编译完成: $(wc -l < "$WORK/$_i.dts") 行"

		sed -f "$WORK/patch.sed" "$WORK/$_i.dts" > "$WORK/$_i.patched.dts" \
			|| { die "DTB #$_i 改写 dts 失败"; return 1; }

		# dtbo 表里通常有多个板型条目，只有当前机型的那个含这些充电节点。
		# 改写后与原文件完全相同 -> 这个条目不含目标节点，原样保留，不算错误。
		if cmp -s "$WORK/$_i.dts" "$WORK/$_i.patched.dts"; then
			log "  该条目不含目标充电节点（改写无变化），原样保留"
			_outs="$_outs $WORK/dtb.$_i"
			_nopat=$((_nopat + 1))
			_i=$((_i + 1))
			continue
		fi
		log "  改写完成: $(wc -l < "$WORK/$_i.patched.dts") 行"

		"$DTC" -@ -I dts -O dtb -o "$WORK/$_i.new" "$WORK/$_i.patched.dts" 2>"$WORK/$_i.comp.err" \
			|| { die "DTB #$_i 重新打包失败：$(grep -i 'error' "$WORK/$_i.comp.err" 2>/dev/null | head -n 2 | tr '\n' ' ')"; return 1; }
		log "  重新打包完成: $(file_size "$WORK/$_i.new") 字节"

		# 复核一：新镜像必须能反编译回来
		"$DTC" -I dtb -O dts -o "$WORK/$_i.check.dts" "$WORK/$_i.new" 2>"$WORK/$_i.chk.err" \
			|| { die "DTB #$_i 复核失败：新镜像无法反编译"; return 1; }

		# 复核二：目标属性全部存在且取值与预期一致
		if verify_dts "$WORK/$_i.check.dts"; then
			log "  复核通过：充电限制参数全部匹配"
		else
			die "DTB #$_i 复核失败：充电限制参数与预期不一致（详见上方 MISMATCH/MISSING）"
			return 1
		fi

		_outs="$_outs $WORK/$_i.new"
		_i=$((_i + 1))
	done

	_done=$((CNT - _nopat))
	if [ "$_done" -lt 1 ]; then
		die "全部 $CNT 个 DTB 条目都不含目标充电节点，当前 dtbo 与本模块的参考表不匹配，未做任何修改"
		return 1
	fi
	[ "$_nopat" -gt 0 ] && log "其中 $_nopat 个条目不含目标节点，已原样保留；实际改写 $_done 个"

	if ! pack_image "$WORK/new.img" $_outs; then
		die "拼装分区镜像失败（新镜像超过分区容量 $PSIZE 字节？）"
		return 1
	fi
	log "新镜像: $(file_size "$WORK/new.img") 字节（分区 $PSIZE 字节）"

	# 复核三：新镜像能按同样方式重新拆出全部 DTB，且内容与写入的一致
	if verify_image "$WORK/new.img" $_outs; then
		log "  新镜像结构复核通过：$CNT 个 DTB 均可原样取出"
	else
		die "新镜像结构复核失败"
		return 1
	fi

	NEW_SHA=$(sha256_of "$WORK/new.img")
	log "新镜像 sha256: ${NEW_SHA:-<无 sha256sum>}"

	if [ "$DRY_RUN" = "1" ]; then
		log "DRY_RUN=1：仅演练，不写分区。产物在 $WORK/new.img"
		log "=========== 结束（演练） ==========="
		return 0
	fi

	[ -n "$NEW_SHA" ] || { die "无法计算 sha256，拒绝刷写"; return 1; }

	# ---- 备份原始镜像 ----
	BK="$BACKUP/dtbo${SLOT}_$(date '+%Y%m%d-%H%M%S').img"
	cp "$ORIG" "$BK" || { die "备份原始镜像失败，拒绝刷写"; return 1; }
	if [ "$(sha256_of "$BK")" != "$ORIG_SHA" ]; then
		die "备份校验失败，拒绝刷写"
		return 1
	fi
	log "原始镜像已备份: $BK"

	# ---- 刷写 ----
	log "写入分区 $PART ..."
	FLASH_ID=$(gen_token)
	echo "$BK" > "$STATE/pending"
	echo "$CUR_BOOT" > "$STATE/pending_boot"
	echo "$FLASH_ID" > "$STATE/pending_id"
	echo 0 > "$STATE/pending_tries"
	rm -f "$STATE/pending_tries_boot" "$STATE/confirmed"
	sync

	dd if="$WORK/new.img" of="$PART" bs=1048576 conv=fsync 2>"$WORK/dd.err"
	_rc=$?
	sync
	[ "$_rc" -ne 0 ] && log "dd 返回 $_rc：$(cat "$WORK/dd.err" 2>/dev/null | tr '\n' ' ')"

	# ---- 回读校验 ----
	log "回读校验 ..."
	_back=$(read_partition_sha)
	if [ "$_back" != "$NEW_SHA" ]; then
		log "回读校验失败（回读 ${_back:-空} != 写入 $NEW_SHA），立即回滚 ..."
		dd if="$BK" of="$PART" bs=1048576 conv=fsync 2>/dev/null
		sync
		rm -f "$STATE/pending" "$STATE/pending_boot" "$STATE/pending_id" \
		      "$STATE/pending_tries" "$STATE/pending_tries_boot" "$STATE/confirmed"
		die "写入后校验不一致，已回滚原始镜像"
		return 1
	fi
	log "回读校验通过"

	echo "$NEW_SHA" > "$STATE/last_sha"
	echo "$ORIG_SHA" > "$STATE/orig_sha"
	echo "$PART" > "$STATE/part"
	echo "$BK" > "$STATE/backup"
	# 记下这次刷入用的温度档位，用来判断「只改了档位」时要不要重新刷
	echo "$_hi_now" > "$STATE/flash_high"

	# 分区开头 1MB 的哈希：用来事后判断「当前分区还是不是我们刷进去的那份」。
	# 系统 OTA 会把 dtbo 换回原厂，页面上靠它提示需要重新运行一次。
	_head=$(dd if="$WORK/new.img" bs=1048576 count=1 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)
	[ -n "$_head" ] && echo "$_head" > "$STATE/last_head"

	log "刷写成功。重启后生效；下次开机会自动确认启动结果。"
	log "如需回滚: sh $SHOWDIR/restore.sh"
	log "=========== 结束（成功） ==========="
	return 0
}

# ---------------------------------------------------------------------------
# 开发期钩子：模块目录下如果有 override.sh 就加载它，用于在 PC 上测试时
# 替换与设备相关的函数（detect_slot / resolve_partition / pick_workdir 等）。
# 正式安装包里不包含这个文件，所以对设备无影响。
# ---------------------------------------------------------------------------
if [ -f "$MODDIR/override.sh" ]; then
	. "$MODDIR/override.sh"
fi

# 显式返回 0：本文件是被 `.` 加载的，末尾的测试命令若返回非 0，
# 在 `set -e` 的调用方里会让整个脚本意外退出。
return 0 2>/dev/null || true
