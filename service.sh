#!/system/bin/sh
# KernelSU / Magisk 模块：开机后期执行。
#
# 这里只做两件事，都不碰 dtbo 分区：
#   1. 拉起充电日志的后台记录进程
#   2. 记一下本次开机时刻，供页面参考
#
# 没有「开机确认」，也没有「连续几次没起来就自动回滚」。
# 判断模块有没有生效只有一条路：WebUI 里比对当前分区头部哈希与
# state/last_head（monitor.sh --full 输出 state_cur_head）。
# 系统 OTA 之后 dtbo 会回到原厂，模块不会自己再改，需要手动跑一次。

MODDIR="${0%/*}"
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/dtbo_charge_unlock

STATE="$MODDIR/state"
LOGDIR="$MODDIR/logs"
mkdir -p "$STATE" "$LOGDIR" 2>/dev/null

# ---- 充电日志 ----
[ -f "$MODDIR/chargelog.sh" ] && sh "$MODDIR/chargelog.sh" start >/dev/null 2>&1

# ---- 记录本次开机时刻（只用于展示，不参与任何判断） ----
date +%s > "$STATE/boot_time" 2>/dev/null

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 开机后期：充电日志已拉起" \
	>> "$LOGDIR/$(date '+%Y%m%d').log" 2>/dev/null
exit 0
