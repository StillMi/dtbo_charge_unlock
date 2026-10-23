#!/system/bin/sh
# KernelSU / Magisk 模块：开机早期自动执行。
#
# 正常安装时刷写已经在 customize.sh 里完成，这里多数情况下只是走一遍
# 「已刷过 -> 跳过」的快速路径。它存在的意义有两个：
#   1) 处理上一次刷写后的开机确认 / 自动回滚（状态机收尾）；
#   2) 系统 OTA 把 dtbo 换回原厂后，自动重新应用一次。

MODDIR="${0%/*}"
[ -f "$MODDIR/common.sh" ] || MODDIR=/data/adb/modules/dtbo_charge_unlock

INTERACTIVE=0
. "$MODDIR/common.sh"

mkdir -p "$LOGDIR" 2>/dev/null
LOGFILE="$LOGDIR/$(date '+%Y%m%d').log"
export LOGFILE

run_main
exit $?
