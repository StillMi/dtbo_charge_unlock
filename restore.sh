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
SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null)
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

if [ "$ASSUME_YES" != "1" ]; then
	printf "确认把备份写回 %s ? [y/N] " "$NAME"
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
	rm -f "$STATE/last_sha" "$STATE/pending" "$STATE/pending_boot" \
	      "$STATE/pending_id" "$STATE/pending_tries" "$STATE/confirmed"
	echo "已停用 $(date '+%Y-%m-%d %H:%M:%S')" > "$STATE/halted"
	echo "提示: 若想再次启用本模块，删除 $STATE/halted 即可。"
else
	die "校验失败（$A != $B），请用 fastboot 手工刷回 $IMG"
fi
