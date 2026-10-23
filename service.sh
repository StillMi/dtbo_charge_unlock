#!/system/bin/sh
# 开机后期确认：如果本轮开机加载的是「上一次刷入的 dtbo」，
# 并且已经走到开机后期（说明没有卡在启动阶段），就记为已确认。
#
# 这个标记只是提前确认；即使本脚本没跑，下次开机也不会误回滚——
# 只有「连续 3 次开机都没走到开机后期」才会回滚。

MODDIR="${0%/*}"
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/dtbo_charge_unlock

STATE="$MODDIR/state"
LOGDIR="$MODDIR/logs"
mkdir -p "$STATE" "$LOGDIR" 2>/dev/null

[ -f "$STATE/pending" ] || exit 0

. "$MODDIR/common.sh" 2>/dev/null

# 刷写发生在本轮开机之后 → 新 dtbo 还没被加载，不能确认
if flashed_this_boot "$STATE/pending"; then
	exit 0
fi

FLASH_ID=$(cat "$STATE/pending_id" 2>/dev/null)
[ -n "$FLASH_ID" ] || exit 0
echo "$FLASH_ID" > "$STATE/confirmed"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 已确认刷入的 dtbo 可以正常开机" \
	>> "$LOGDIR/$(date '+%Y%m%d').log" 2>/dev/null
exit 0
