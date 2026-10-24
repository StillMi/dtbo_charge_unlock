#!/bin/sh
# ============================================================================
# 档位测试：安全档(0~48℃) / 极限档(0~56℃) / 默认
#
# 验证三件事：
#   1. 安装时选的档位真的改写进了 config.conf（后续开机会沿用）
#   2. 刷进分区的 dtbo 里 ffc_temp_high 是对应的十六进制值
#   3. JEITA 分段表的高温边界落在对应温度
#
# 用法: sh tools/test_tier.sh <模块目录> <假分区镜像> <dtc> <沙盒根目录>
# ============================================================================

MODDIR="$1"
FAKEPART="$2"
DTC_REAL="$3"
ROOT="$4"

[ -n "$MODDIR" ] && [ -n "$ROOT" ] || {
	echo "用法: sh $0 <模块目录> <假分区镜像> <dtc> <沙盒根目录>"
	exit 2
}

MYDIR=$(dirname "$0")
FAILED=0

mkdir -p "$ROOT" || { echo "无法创建 $ROOT"; exit 1; }

# 把刷好的分区重新拆成 dtb 并反编译，用来直接看里面的真实取值
decompile_partition() {  # decompile_partition <沙盒> <输出目录>
	(
		MODDIR="$1/mod"
		WORK="$2"
		rm -rf "$WORK"
		mkdir -p "$WORK" || exit 1
		. "$MODDIR/common.sh" >/dev/null 2>&1 || exit 1
		DTC="$DTC_REAL"
		# split_dtbs 会拿 PSIZE 校验 total_size，这里必须补上
		PSIZE=$(wc -c < "$1/partition.img" | tr -d ' \t\r\n')
		split_dtbs "$1/partition.img" || exit 1
		_i=0
		while [ "$_i" -lt "$CNT" ]; do
			"$DTC" -I dtb -O dts -o "$WORK/$_i.dts" "$WORK/dtb.$_i" 2>/dev/null || exit 1
			_i=$((_i + 1))
		done
	)
}

check_tier() {  # check_tier <TEST_TIER 值|空> <期望℃> <期望十六进制>
	_tier="$1"
	_want="$2"
	_hex="$3"
	_tag="${_tier:-default}"
	SB="$ROOT/tier_$_tag"

	echo "=== 档位 [$(_tag_name "$_tier")]：期望 0~${_want}℃，ffc_temp_high=<$_hex> ==="

	TEST_TIER="$_tier" sh "$MYDIR/test_install.sh" "$MODDIR" "$FAKEPART" "$DTC_REAL" "$SB" \
		> "$ROOT/tier_$_tag.install.log" 2>&1
	if [ $? -ne 0 ]; then
		echo "  [FAIL] 安装阶段失败，见 $ROOT/tier_$_tag.install.log"
		FAILED=$((FAILED + 1))
		return
	fi

	# 1) config.conf 应该被写成对应值
	_cfg=$(grep '^FFC_TEMP_HIGH=' "$SB/mod/config.conf" 2>/dev/null | cut -d= -f2)
	if [ "$_cfg" = "$_want" ]; then
		echo "  [ OK ] config.conf  FFC_TEMP_HIGH=$_cfg"
	else
		echo "  [FAIL] config.conf  FFC_TEMP_HIGH=$_cfg，期望 $_want"
		FAILED=$((FAILED + 1))
	fi

	# 2) 反编译刷好的分区
	if ! decompile_partition "$SB" "$ROOT/tier_${_tag}_dts" >/dev/null 2>&1; then
		echo "  [FAIL] 无法反编译刷好的分区"
		FAILED=$((FAILED + 1))
		return
	fi

	_hits=0
	_jeita=0
	for _f in "$ROOT"/tier_${_tag}_dts/*.dts; do
		[ -f "$_f" ] || continue
		grep -qF "ffc_temp_high = <$_hex>" "$_f" 2>/dev/null && _hits=$((_hits + 1))
		grep -qF "\"18\", \"$_want\"," "$_f" 2>/dev/null && _jeita=$((_jeita + 1))
	done

	if [ "$_hits" -gt 0 ]; then
		echo "  [ OK ] dtbo 里 ffc_temp_high = <$_hex>（$_hits 个 DTB）"
	else
		echo "  [FAIL] dtbo 里找不到 ffc_temp_high = <$_hex>"
		grep -h 'ffc_temp_high' "$ROOT"/tier_${_tag}_dts/*.dts 2>/dev/null | sed 's/^/        /'
		FAILED=$((FAILED + 1))
	fi

	if [ "$_jeita" -gt 0 ]; then
		echo "  [ OK ] JEITA 分段表高温边界 = ${_want}℃（$_jeita 个 DTB）"
	else
		echo "  [FAIL] JEITA 分段表里没找到 \"18\", \"${_want}\","
		FAILED=$((FAILED + 1))
	fi

	# 3) 另一个档位的值不该同时存在（防止「改了但没生效」）
	if [ "$_want" = "48" ]; then
		grep -qhF 'ffc_temp_high = <0x38>' "$ROOT"/tier_${_tag}_dts/*.dts 2>/dev/null \
			&& { echo "  [FAIL] 仍存在极限档的 0x38"; FAILED=$((FAILED + 1)); }
	fi
	echo ""
}

_tag_name() {
	case "$1" in
		safe) echo "安全档 0~48℃" ;;
		max)  echo "极限档 0~56℃" ;;
		*)    echo "默认（不按键，保持 config.conf）" ;;
	esac
}

check_tier "safe" 48 0x30
check_tier "max"  56 0x38
check_tier ""     56 0x38

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "=== 档位测试全部通过 ==="
	exit 0
fi
echo "=== 档位测试失败：$FAILED 项 ==="
exit 1
