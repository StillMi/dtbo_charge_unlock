#!/system/bin/sh
# 手工回滚：把备份的原始 dtbo 写回当前槽位的分区。
#
# 用法:
#   su -c "sh /data/adb/modules/dtbo_charge_unlock/restore.sh"          # 交互确认
#   su -c "sh /data/adb/modules/dtbo_charge_unlock/restore.sh -y"       # 不再询问
#   su -c "sh /data/adb/modules/dtbo_charge_unlock/restore.sh /path/to/backup.img"

MODDIR="${0%/*}"
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/dtbo_charge_unlock
STATE="$MODDIR/state"
BACKUP="$MODDIR/backup"

# WebUI（ksu.exec）起的 shell，PATH 有时只剩一两个目录，dd / sha256sum / ls / sed
# 一个都找不到，脚本会莫名其妙地在第一步就失败。把标准目录补进去（只追加不覆盖）。
for _pd in /system/bin /system/xbin /vendor/bin /odm/bin /sbin /system/sbin; do
	case ":$PATH:" in
		*":$_pd:"*) ;;
		*) PATH="${PATH:+$PATH:}$_pd" ;;
	esac
done
unset _pd

die() { echo "错误: $*"; exit 1; }

ASSUME_YES=0
IMG=""
for a in "$@"; do
	case "$a" in
		-y|--yes) ASSUME_YES=1 ;;
		*)        IMG="$a" ;;
	esac
done

if [ -z "$IMG" ] && [ -f "$STATE/backup" ]; then
	IMG=$(cat "$STATE/backup")
fi
if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
	# 退路：用最近一次备份
	IMG=$(ls -1t "$BACKUP"/*.img 2>/dev/null | head -n1)
fi
[ -n "$IMG" ] && [ -f "$IMG" ] || die "找不到备份镜像（$BACKUP/ 下没有 .img）"

# ---- 槽位与分区 ----
# 和 common.sh 保持一致：config.conf 里设了 FORCE_SLOT 就照它来，
# 否则看当前系统槽位。两边认的槽位不一样就会写错分区。
_FORCE_SLOT=""
if [ -f "$MODDIR/config.conf" ]; then
	_FORCE_SLOT=$(sed -n 's/^[[:space:]]*FORCE_SLOT[[:space:]]*=[[:space:]]*//p' \
		"$MODDIR/config.conf" 2>/dev/null | tail -n1 | tr -d '" \t\r\n')
fi
case "$_FORCE_SLOT" in
	a|b) SLOT="_$_FORCE_SLOT" ;;
	*)
		SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null)
		;;
esac
case "$SLOT" in
	_a|_b) NAME="dtbo$SLOT" ;;
	*)     NAME="dtbo" ;;
esac

PART=""
for base in /dev/block/by-name /dev/block/bootdevice/by-name; do
	[ -e "$base/$NAME" ] && { PART="$base/$NAME"; break; }
done
[ -n "$PART" ] || die "找不到分区 $NAME"

REAL=$(readlink -f "$PART" 2>/dev/null)
[ -n "$REAL" ] || REAL="$PART"
DEVNAME=$(basename "$REAL")
PSIZE=$(($(cat "/sys/class/block/$DEVNAME/size" 2>/dev/null) * 512))
[ "$PSIZE" -gt 0 ] 2>/dev/null || die "无法获取分区大小"

ISZ=$(wc -c < "$IMG" | tr -d ' \t\r\n')
echo "备份镜像 : $IMG ($ISZ 字节)"
echo "目标分区 : $PART -> $REAL ($PSIZE 字节)"
[ "$ISZ" -le "$PSIZE" ] 2>/dev/null || die "备份镜像比分区大，拒绝写入"

# ---- 这份备份还对得上当前系统吗？----
# 备份是「上一次刷写时抓的原厂镜像」。如果这中间系统 OTA 过，分区早就不是
# 本模块刷入的那一份了，把旧备份写回去等于给新系统塞了个旧固件的 dtbo。
STALE=0
if [ -f "$STATE/last_sha" ]; then
	_WANT=$(cat "$STATE/last_sha" 2>/dev/null)
	_CUR=$(dd if="$PART" bs=1048576 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)
	if [ -n "$_WANT" ] && [ -n "$_CUR" ] && [ "$_WANT" != "$_CUR" ]; then
		STALE=1
		echo ""
		echo "警告: 当前 dtbo 分区已经不是本模块刷入的那一份了（系统大概 OTA 过）。"
		echo "      这份备份属于上一个系统版本，写回去可能和当前系统对不上。"
		echo "      更稳的做法是用 fastboot 刷入当前系统版本的官方 dtbo。"
		echo ""
	fi
fi

if [ "$ASSUME_YES" != "1" ]; then
	if [ "$STALE" = "1" ]; then
		printf "备份与当前系统可能不匹配，仍然写回 %s ? [y/N] " "$NAME"
	else
		printf "确认把备份写回 %s ? [y/N] " "$NAME"
	fi
	read -r ans
	case "$ans" in
		y|Y|yes|YES) ;;
		*) echo "已取消"; exit 1 ;;
	esac
fi

TMP=/dev/dtbo_charge_unlock
mkdir -p "$TMP" 2>/dev/null || TMP=/data/local/tmp

echo "写入中 ..."
dd if="$IMG" of="$PART" bs=4096 conv=fsync 2>/dev/null || die "写入失败"
sync

echo "校验中 ..."
CNT=$(( (ISZ + 4095) / 4096 ))
dd if="$PART" of="$TMP/rb.img" bs=4096 count="$CNT" 2>/dev/null
head -c "$ISZ" "$TMP/rb.img" > "$TMP/rb.trim" 2>/dev/null
A=$(sha256sum "$IMG" 2>/dev/null | cut -d' ' -f1)
B=$(sha256sum "$TMP/rb.trim" 2>/dev/null | cut -d' ' -f1)
rm -f "$TMP/rb.img" "$TMP/rb.trim"

if [ -n "$A" ] && [ "$A" = "$B" ]; then
	echo "校验通过，已恢复原始 dtbo。重启后生效。"
	# 恢复后清掉「本模块刷过」的痕迹，页面就会显示「尚未刷写」而不是
	# 「需重新应用」——分区现在确实是原厂的，不需要再跑一次。
	rm -f "$STATE/last_sha" "$STATE/last_head" "$STATE/flash_high" \
	      "$STATE/backup"
	echo "提示: 想再次启用本模块，重新执行 action.sh 或点 WebUI 的「运行修改」即可。"
else
	die "校验失败（$A != $B），请用 fastboot 手工刷回 $IMG"
fi
