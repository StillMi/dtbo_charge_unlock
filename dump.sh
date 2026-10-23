#!/system/bin/sh
# 只读工具：把当前槽位的 dtbo 分区导出成镜像，拆出其中的每个 DTB 并反编译成 dts，
# 方便自己查看/比对。**不写任何分区**。
#
# 用法: su -c "sh /data/adb/modules/dtbo_charge_unlock/dump.sh"
# 产物: /sdcard/Download/dtbo_dump/ 下
#   dtbo_a.img          分区原始镜像（16 进制/二进制分析用）
#   dtbo_a.info.txt     镜像格式、字节序、表头、每个条目的位置与大小
#   dtbo_a.0.dtb/.dts   第 0 个 DTB 及其反编译结果
#   dtbo_a.1.dtb/.dts   ...
#   dtbo_a.txt          所有条目里关键充电参数的汇总

MODDIR="${0%/*}"
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/dtbo_charge_unlock

OUT="${1:-/sdcard/Download/dtbo_dump}"
mkdir -p "$OUT" 2>/dev/null || { echo "无法创建 $OUT"; exit 1; }

# ---------------------------------------------------------------- 定位分区 ---
SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null)
case "$SLOT" in
	_a|_b) NAME="dtbo$SLOT" ;;
	*)     NAME="dtbo"; SLOT="" ;;
esac

PART=""
for base in /dev/block/by-name /dev/block/bootdevice/by-name; do
	[ -e "$base/$NAME" ] && { PART="$base/$NAME"; break; }
done
[ -n "$PART" ] || { echo "找不到分区 $NAME"; exit 1; }

REAL=$(readlink -f "$PART" 2>/dev/null)
[ -n "$REAL" ] || REAL="$PART"
DEVNAME=$(basename "$REAL")
PSIZE=$(($(cat "/sys/class/block/$DEVNAME/size" 2>/dev/null) * 512))
[ "$PSIZE" -gt 0 ] 2>/dev/null || { echo "无法获取分区大小"; exit 1; }

echo "槽位     : ${SLOT#_}${SLOT:+（A/B）}"
echo "分区     : $PART -> $REAL"
echo "大小     : $PSIZE 字节"
echo "输出目录 : $OUT"

if [ "$(id -u 2>/dev/null)" != "0" ]; then
	echo "警告: 当前不是 root，读分区可能失败"
fi

# ---------------------------------------------------------------- 导出镜像 ---
IMG="$OUT/dtbo${SLOT}.img"
echo "导出镜像 ..."
dd if="$PART" of="$IMG" bs=4096 2>/dev/null || { echo "读取失败"; exit 1; }
SIZE=$(wc -c < "$IMG" | tr -d ' \t\r\n')
echo "  已写出 $IMG（$SIZE 字节）"

# -------------------------------------------------- 用 common.sh 拆分（只读）---
. "$MODDIR/common.sh"

TMP="${DUMP_WORKDIR:-/dev/dtbo_charge_unlock}"
mkdir -p "$TMP" 2>/dev/null || TMP="${DUMP_WORKDIR:-/data/local/tmp}"
WORK="$TMP/dumpwork"
rm -rf "$WORK" 2>/dev/null
mkdir -p "$WORK" 2>/dev/null || { echo "无法创建临时目录 $WORK"; exit 1; }

cp "$MODDIR/bin/dtc-aarch64" "$WORK/dtc" 2>/dev/null || { echo "复制 dtc 失败"; exit 1; }
chmod 755 "$WORK/dtc" 2>/dev/null
DTC="$WORK/dtc"

echo "识别格式 ..."
if ! split_dtbs "$IMG"; then
	echo "  无法拆分该镜像，前 16 字节: $(hex_head "$IMG" 16)"
	echo "  已导出原始镜像 $IMG，可自行分析"
	rm -rf "$WORK"
	exit 1
fi

INFO="$OUT/dtbo${SLOT}.info.txt"
: > "$INFO"
{
	echo "分区      : $PART -> $REAL"
	echo "分区大小  : $PSIZE 字节"
	echo "镜像格式  : $IMG_FORMAT"
	if [ "$IMG_FORMAT" = "dtbo" ]; then
		echo "字节序    : $DT_ENDIAN（le=官方 mkdtimg，be=部分厂商）"
		echo "表头长度  : $DT_HDRSZ 字节"
		echo "条目长度  : $DT_ENTSZ 字节"
		echo "条目个数  : $DT_CNT"
		echo "条目表偏移: $DT_EOFF"
		echo "页大小    : $DT_PAGE 字节"
		echo "version   : $DT_VER"
		echo "total_size: $DT_TOTAL 字节"
	fi
	echo "DTB 个数  : $CNT"
} >> "$INFO"
echo "  格式: $IMG_FORMAT${DT_ENDIAN:+（$DT_ENDIAN）}，共 $CNT 个 DTB"

# ------------------------------------------------------------ 逐个反编译 ---
SUM="$OUT/dtbo${SLOT}.txt"
: > "$SUM"

echo "反编译 ..."
_i=0
_fail=0
while [ "$_i" -lt "$CNT" ]; do
	cp "$WORK/dtb.$_i" "$OUT/dtbo${SLOT}.$_i.dtb" 2>/dev/null
	_dts="$OUT/dtbo${SLOT}.$_i.dts"
	if "$DTC" -I dtb -O dts -o "$_dts" "$WORK/dtb.$_i" 2>"$WORK/dec.$_i.err"; then
		echo "  DTB #$_i 反编译完成: $(wc -l < "$_dts" | tr -d ' \t\r\n') 行"
		{
			echo "================ DTB #$_i ================"
			echo "大小: $(wc -c < "$WORK/dtb.$_i" | tr -d ' \t\r\n') 字节"
			grep -n 'ffc_temp_high\|ffc_temp_low' "$_dts" 2>/dev/null | head -n 8
			echo "--- mca_charger_thermal ---"
			sed -n '/mca_charger_thermal: mca_charger_thermal {/,/^\t\t};/p' "$_dts" 2>/dev/null \
				| grep -n 'status\|compatible' | head -n 4
			echo "--- mca_buckchg_jeita ---"
			sed -n '/mca_buckchg_jeita: mca_buckchg_jeita {/,/^\t\t};/p' "$_dts" 2>/dev/null \
				| head -n 20
			echo ""
		} >> "$SUM"
	else
		echo "  DTB #$_i 反编译失败:"
		head -n 3 "$WORK/dec.$_i.err" 2>/dev/null | sed 's/^/    /'
		_fail=$((_fail + 1))
		echo "DTB #$_i 反编译失败" >> "$SUM"
	fi
	_i=$((_i + 1))
done

rm -rf "$WORK"
echo ""
echo "产物:"
echo "  $IMG"
echo "  $INFO"
echo "  $SUM"
echo "  $OUT/dtbo${SLOT}.*.dtb / .dts"
[ "$_fail" -eq 0 ] || echo "注意: 有 $_fail 个 DTB 反编译失败"
echo "完成（未修改任何分区）"
