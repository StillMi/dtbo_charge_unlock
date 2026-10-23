#!/system/bin/sh
# 卸载时不做任何分区写操作：设备当前正在使用已刷入的 dtbo，
# 贸然回滚反而可能出问题。
#
# 但卸载会把整个模块目录删掉，备份也就没了，所以这里先把备份复制到
# /sdcard/Download/dtbo_charge_unlock_backup/ 留存。
# 要恢复原始 dtbo，请在卸载前执行 restore.sh，或卸载后用 fastboot 刷回留存镜像。

MODDIR="${0%/*}"
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/dtbo_charge_unlock

OUT=/sdcard/Download/dtbo_charge_unlock_backup
mkdir -p "$OUT" 2>/dev/null

SAVED=0
for f in "$MODDIR/backup"/*.img; do
	[ -f "$f" ] || continue
	cp "$f" "$OUT/" 2>/dev/null && SAVED=$((SAVED + 1))
done

echo "dtbo_charge_unlock 已卸载。"
echo "当前 dtbo 分区仍保持刷入后的状态。"
if [ "$SAVED" -gt 0 ]; then
	echo "已把 $SAVED 个备份镜像留存到: $OUT"
	echo "如需恢复原始 dtbo，可用 fastboot 刷回其中的镜像，"
	echo "例如: fastboot flash dtbo_a <该目录下对应文件>"
else
	echo "没有找到备份镜像（可能从未成功刷写过）。"
fi
exit 0
