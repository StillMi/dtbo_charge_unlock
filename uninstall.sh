#!/system/bin/sh
# 卸载时不做任何分区写操作：设备当前正在使用已刷入的 dtbo，
# 贸然回滚反而可能出问题。
#
# 但卸载会把整个模块目录删掉，备份也就没了，所以这里先把备份复制到
# /sdcard/Download/dtbo_charge_unlock_backup/ 留存。
# 要恢复原始 dtbo，请在卸载前执行 restore.sh，或卸载后用 fastboot 刷回留存镜像。

MODDIR="${0%/*}"
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/dtbo_charge_unlock

# 停掉充电日志后台记录，否则卸载后它还在跑、还在写日志
[ -f "$MODDIR/chargelog.sh" ] && sh "$MODDIR/chargelog.sh" stop >/dev/null 2>&1

# 充电日志放在模块目录之外（这样升级模块不会丢历史），卸载时一并清掉
LOGDIR="$(grep '^CHARGELOG_DIR=' "$MODDIR/config.conf" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '\r')"
[ -n "$LOGDIR" ] || LOGDIR=/data/adb/dtbo_charge_unlock/chargelog

OUT=/sdcard/Download/dtbo_charge_unlock_backup
mkdir -p "$OUT" 2>/dev/null

SAVED=0
for f in "$MODDIR/backup"/*.img; do
	[ -f "$f" ] || continue
	cp "$f" "$OUT/" 2>/dev/null && SAVED=$((SAVED + 1))
done

echo "dtbo_charge_unlock 已卸载。"
echo "当前 dtbo 分区仍保持刷入后的状态。"

# 充电日志：先问一句要不要留 —— 卸载脚本无法交互，改成直接留存到 sdcard
if [ -d "$LOGDIR" ] && [ -n "$(ls -1 "$LOGDIR"/*.log 2>/dev/null)" ]; then
	mkdir -p "$OUT/chargelog" 2>/dev/null
	cp "$LOGDIR"/*.log "$OUT/chargelog/" 2>/dev/null
	echo "充电日志已留存到: $OUT/chargelog"
	rm -rf "$LOGDIR" 2>/dev/null
fi
rmdir /data/adb/dtbo_charge_unlock 2>/dev/null

if [ "$SAVED" -gt 0 ]; then
	echo "已把 $SAVED 个备份镜像留存到: $OUT"
	echo "如需恢复原始 dtbo，可用 fastboot 刷回其中的镜像，"
	echo "例如: fastboot flash dtbo_a <该目录下对应文件>"
else
	echo "没有找到备份镜像（可能从未成功刷写过）。"
fi
exit 0
