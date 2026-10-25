#!/system/bin/sh
# ============================================================================
# 安装脚本：在安装过程中就直接完成「识别槽位 → 提取 dtbo → 解包 → 改写 →
# 打包 → 复核 → 备份 → 刷入 → 回读校验」，装完重启即可生效。
#
# 开机阶段（service.sh）**不写任何分区**，只拉起充电日志。
# 系统 OTA 之后需要用户手动触发一次（KernelSU「操作」或 WebUI「运行修改」）。
# ============================================================================

SKIPUNZIP=0

ui_print "- 设置模块文件权限"
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/bin/dtc-aarch64" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/restore.sh" 0 0 0755
set_perm "$MODPATH/dump.sh" 0 0 0755
set_perm "$MODPATH/monitor.sh" 0 0 0755
set_perm "$MODPATH/chargelog.sh" 0 0 0755
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

# 升级安装时，旧版本的充电日志后台进程可能还在跑（它读的脚本文件已被替换），
# 先停掉，安装结束后再按新版本重新拉起。
[ -f "$MODPATH/chargelog.sh" ] && sh "$MODPATH/chargelog.sh" stop >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 清理旧版本残留
# 大多数管理器会先清空模块目录再解压，但这不是所有版本都保证的行为。
# 旧版 post-fs-data.sh 会调用已经删掉的 boot_guard，留下来会让每次开机都报错；
# 旧版的 pending / confirmed / halted 状态文件对新逻辑也没有意义。
# 这里显式删一遍，升级上来才干净。
# ---------------------------------------------------------------------------
_LEGACY=""
for f in post-fs-data.sh state/pending state/pending_boot state/pending_id \
         state/pending_tries state/pending_tries_boot state/confirmed state/halted; do
	[ -e "$MODPATH/$f" ] && { rm -f "$MODPATH/$f" 2>/dev/null && _LEGACY="$_LEGACY $f"; }
done
if [ -n "$_LEGACY" ]; then
	ui_print "- 已清理旧版本残留:$_LEGACY"
fi

# ---------------------------------------------------------------------------
# 选档位（音量键）：结果写回 config.conf，之后手动重刷沿用同一档位
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
		ui_print "- 重启后生效。打开模块的 WebUI，「是否生效」显示「是」就说明成功了。"
		ui_print "- 以后模块不会自动再刷。系统 OTA 之后请手动点一次"
		ui_print "  KernelSU 的「操作」按钮，或打开 WebUI 点「运行修改」。"
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
	ui_print "  模块已安装，但分区没改。可以进 KernelSU 模块页点「操作」，"
	ui_print "  或打开 WebUI 点「运行修改」重试。"
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

# 重新拉起充电日志后台进程（开机时 service.sh 也会拉，这里先让本次安装后就开始记）
[ -f "$MODPATH/chargelog.sh" ] && sh "$MODPATH/chargelog.sh" start >/dev/null 2>&1
