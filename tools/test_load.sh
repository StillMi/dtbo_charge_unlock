#!/bin/sh
# 模拟 customize.sh 里 source common.sh 的过程，确认没有解析错误。
# 只做「能不能被 sh 正常加载」的检查，不碰任何分区。
MODDIR="$1"
[ -f "$MODDIR/module.prop" ] || { echo "找不到 module.prop"; exit 1; }

# 提供安装器函数桩，避免 ui_print 未定义
ui_print() { :; }
abort() { echo "abort: $*"; exit 1; }
getprop() { :; }

INSTALL_MODE=1
export INSTALL_MODE

. "$MODDIR/common.sh"
RC=$?
echo "source common.sh 返回: $RC"

# 逐个确认关键函数都定义好了
MISSING=0
for fn in log die sha256_of file_size pick_workdir detect_slot resolve_partition \
          log_boot_state prepare_dtc fdt_head split_dtbs pack_image read_partition_sha \
          build_runtime_rules verify_dts run_main u32_at put_u32 poke_u32 \
          detect_format parse_dtbo_header split_dtbo_table pack_dtbo_table \
          verify_image boot_epoch flashed_this_boot align_up hex_at \
          key_name_from_event read_volume_key set_ffc_high tier_pick tier_desc; do
	if command -v "$fn" >/dev/null 2>&1; then
		:
	else
		echo "  缺少函数: $fn"
		MISSING=$((MISSING + 1))
	fi
done

if [ "$MISSING" -gt 0 ]; then
	echo "有 $MISSING 个函数未定义"
	exit 1
fi
echo "全部函数定义正常"

# 关键变量默认值
echo "FFC_TEMP_HIGH=[$FFC_TEMP_HIGH] FFC_TEMP_LOW=[$FFC_TEMP_LOW]"
echo "FORCE_SLOT=[$FORCE_SLOT] DRY_RUN=[$DRY_RUN]"
echo "SHOWDIR=[$SHOWDIR]"
echo "=== 加载检查通过 ==="
exit 0
