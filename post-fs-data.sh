#!/system/bin/sh
# KernelSU / Magisk 模块：开机早期执行。
#
# 这个脚本**不会刷写 dtbo**。模块只在两种时候改写分区：
#   1) 安装时（customize.sh）
#   2) 用户手动触发：KernelSU 模块页的「操作」按钮，或 WebUI 里的「运行修改」
#
# 开机阶段只做一件只读判断：上一次刷写有没有成功启动过。用来
#   * 已确认启动 → 收掉 pending 标记
#   * 连续 3 次开机都没走到开机后期 → 写回备份并停用（防止变砖循环）
#
# 系统 OTA 之后 dtbo 会回到原厂状态，模块不会自己再改一次，
# 需要用户手动运行一次（见 README）。

MODDIR="${0%/*}"
[ -f "$MODDIR/common.sh" ] || MODDIR=/data/adb/modules/dtbo_charge_unlock

INTERACTIVE=0
. "$MODDIR/common.sh"

# 告诉 common.sh：现在是开机阶段，只做确认/计数/回滚，不刷写
BOOT_PHASE=1

mkdir -p "$LOGDIR" 2>/dev/null
LOGFILE="$LOGDIR/$(date '+%Y%m%d').log"
export LOGFILE

boot_guard
exit 0
