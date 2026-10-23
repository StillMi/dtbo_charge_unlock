#!/system/bin/sh
# KernelSU 模块「操作」按钮：重新执行一次刷写流程，并把过程打印出来。
# 也可以手动执行:  su -c "sh /data/adb/modules/dtbo_charge_unlock/action.sh"

MODDIR="${0%/*}"
[ -f "$MODDIR/common.sh" ] || MODDIR=/data/adb/modules/dtbo_charge_unlock

INTERACTIVE=1
export INTERACTIVE
. "$MODDIR/common.sh"

mkdir -p "$LOGDIR" 2>/dev/null
LOGFILE="$LOGDIR/$(date '+%Y%m%d').log"
export LOGFILE

echo "=============================================="
echo " DTBO 有线充电限制解锁"
echo "=============================================="
if [ -f "$STATE/halted" ]; then
	echo "当前状态: 已停用（$STATE/halted）"
	echo "删除该文件后重新执行本脚本即可再次尝试。"
	echo "----------------------------------------------"
fi
echo "当前槽位: $(getprop ro.boot.slot_suffix 2>/dev/null)"
[ -f "$STATE/last_sha" ] && echo "已刷入 sha256: $(cat "$STATE/last_sha")"
[ -f "$STATE/backup" ]   && echo "原始备份    : $(cat "$STATE/backup")"
echo "----------------------------------------------"

run_main
_rc=$?

echo "----------------------------------------------"
echo "退出码: $_rc"
echo "日志: $LOGDIR/"
exit $_rc
