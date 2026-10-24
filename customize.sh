#!/system/bin/sh
# ============================================================================
# 安装脚本：在安装过程中就直接完成「识别槽位 → 提取 dtbo → 解包 → 改写 →
# 打包 → 复核 → 备份 → 刷入 → 回读校验」，装完重启即可生效。
#
# 开机阶段（post-fs-data.sh）只在「检测到 dtbo 被换过」时才重新执行，
# 例如系统 OTA 之后，用来自动重新应用。
# ============================================================================

SKIPUNZIP=0

ui_print "- 设置模块文件权限"
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/bin/dtc-aarch64" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/restore.sh" 0 0 0755
set_perm "$MODPATH/dump.sh" 0 0 0755
set_perm "$MODPATH/monitor.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

mkdir -p "$MODPATH/state" "$MODPATH/backup" "$MODPATH/logs"
set_perm_recursive "$MODPATH/state" 0 0 0755 0644
set_perm_recursive "$MODPATH/backup" 0 0 0755 0644
set_perm_recursive "$MODPATH/logs" 0 0 0755 0644

# ---------------------------------------------------------------------------
# 安装阶段直接执行刷写流程
# ---------------------------------------------------------------------------
MODDIR="$MODPATH"
INSTALL_MODE=1
export INSTALL_MODE
. "$MODPATH/common.sh"

# 安装阶段的日志单独一份，方便事后回看
LOGFILE="$MODPATH/logs/install-$(date '+%Y%m%d-%H%M%S').log"

ui_print ""
ui_print "=============================================="
ui_print " DTBO 有线充电限制解锁 — 安装阶段执行"
ui_print "=============================================="

# ---------------------------------------------------------------------------
# 选档位（音量键）：结果写回 config.conf，之后开机重刷 / OTA 重应用都沿用
# ---------------------------------------------------------------------------
tier_pick

ui_print ""
run_main
RC=$?

ui_print ""
ui_print "----------------------------------------------"

if [ "$RC" -eq 0 ]; then
	if [ -f "$MODPATH/state/last_sha" ]; then
		ui_print "- 刷写成功，重启后生效"
		ui_print "  温度档位: $(tier_desc)"
		ui_print "  已刷入 sha256: $(cat "$MODPATH/state/last_sha")"
		ui_print "  原始镜像备份: $(cat "$MODPATH/state/backup" 2>/dev/null)"
		ui_print "- 刷入后的首次开机会自动确认能否正常启动；"
		ui_print "  若连续 3 次开机都起不来，会自动回滚原始 dtbo 并停用本模块。"
		ui_print "- 提醒: 系统层温控优先级高于 dtbo，"
		ui_print "  需要先在 Scene 里把温控等级改成「丧心病狂」，否则可能看不到提速。"
	else
		ui_print "- 流程完成（未写分区）"
		if [ "$DRY_RUN" = "1" ]; then
			ui_print "  config.conf 里设了 DRY_RUN=1，这是演练模式。"
		fi
	fi
else
	ui_print "- 安装阶段刷写未完成（见上方日志）"
	ui_print "  模块仍会安装，下次开机会自动再试一次。"
	ui_print "  日志: $MODPATH/logs/"
	if [ "$ABORT_ON_INSTALL_FAIL" = "1" ]; then
		abort "- ABORT_ON_INSTALL_FAIL=1，中止安装"
	fi
fi

ui_print "----------------------------------------------"
ui_print "- 当前系统槽位: $(getprop ro.boot.slot_suffix 2>/dev/null)"
ui_print "- 日志目录: $MODPATH/logs/"
ui_print "- 手动重跑: su -c 'sh /data/adb/modules/dtbo_charge_unlock/action.sh'"
ui_print "- 只读导出: su -c 'sh /data/adb/modules/dtbo_charge_unlock/dump.sh'"
ui_print "- 手工回滚: su -c 'sh /data/adb/modules/dtbo_charge_unlock/restore.sh'"
