#!/bin/sh
# ============================================================================
# 音量键选档的单元测试（不需要设备，也不需要真按音量键）
#
#   1. key_name_from_event 能从 getevent -l 的输出里认出音量键
#   2. tier_pick 在 音量下 / 音量上 / 无按键 / FORCE_TIER 下的选择是否正确
#   3. 选择结果确实写进了 config.conf（开机重刷、OTA 重应用靠它）
#
# 用法: sh tools/test_key.sh <模块目录> <沙盒目录>
# ============================================================================

SRC="$1"
SB="$2"

[ -n "$SRC" ] && [ -n "$SB" ] || {
	echo "用法: sh $0 <模块目录> <沙盒目录>"
	exit 2
}

# 沙盒路径必须是个目录名，不能是文件。
# （曾经误把 dtc.exe 的路径当沙盒传进来，rm -rf 直接把编译器删了）
case "$SB" in
*.[Ee][Xx][Ee]|*.[Dd][Ll][Ll]|*.[Ii][Mm][Gg]|*.[Dd][Tt][Bb]|*.[Dd][Tt][Ss]|*.[Zz][Ii][Pp])
	echo "沙盒路径不能是文件: $SB" >&2; exit 2 ;;
esac
rm -rf "$SB"
mkdir -p "$SB/mod" || exit 1
cp "$SRC/common.sh" "$SRC/config.conf" "$SRC/module.prop" "$SB/mod/" || exit 1

FAILED=0
ok()  { echo "  [ OK ] $1"; }
bad() { echo "  [FAIL] $1"; FAILED=$((FAILED + 1)); }

# ------------------------------------------------------- 1. 事件行解析 ---
echo "=== 事件行解析 ==="

MODDIR="$SB/mod"
. "$MODDIR/common.sh" >/dev/null 2>&1

chk_event() {  # chk_event <说明> <事件行> <期望>
	_got=$(printf '%s\n' "$2" | key_name_from_event)
	if [ "$_got" = "$3" ]; then
		ok "$1 -> $3"
	else
		bad "$1 期望 [$3]，实际 [$_got]"
	fi
}

chk_event "音量下按下" "/dev/input/event2: EV_KEY       KEY_VOLUMEDOWN       DOWN" volumedown
chk_event "音量上按下" "/dev/input/event2: EV_KEY       KEY_VOLUMEUP         DOWN" volumeup
chk_event "音量下抬起" "/dev/input/event2: EV_KEY       KEY_VOLUMEDOWN       UP"   volumedown
chk_event "无关事件"   "/dev/input/event2: EV_SYN       SYN_REPORT           00000000" none
chk_event "空输入"     "" none

# 多行里挑对的那个（getevent 会先吐 SYN / 触摸等）
_multi=$(printf '%s\n%s\n%s\n' \
	"/dev/input/event2: EV_SYN       SYN_REPORT           00000000" \
	"/dev/input/event2: EV_KEY       KEY_VOLUMEUP         DOWN" \
	"/dev/input/event2: EV_SYN       SYN_REPORT           00000000")
if [ "$(printf '%s\n' "$_multi" | key_name_from_event)" = "volumeup" ]; then
	ok "多行输出里挑中音量键"
else
	bad "多行输出没有挑中音量键"
fi

# ------------------------------------------------------- 2. 档位选择 ---
run_pick() {  # run_pick <说明> <模拟按键> <FORCE_TIER> <TIER_PROMPT> <期望 config 值>
	_desc="$1"
	_key="$2"
	_force="$3"
	_prompt="$4"
	_want="$5"

	cp "$SRC/config.conf" "$SB/mod/config.conf"
	(
		MODDIR="$SB/mod"
		. "$MODDIR/common.sh" >/dev/null 2>&1
		FORCE_TIER="$_force"
		TIER_PROMPT="$_prompt"
		# 替掉真实读键，避免测试卡 10 秒
		read_volume_key() { echo "$_key"; }
		tier_pick
	) 2> "$SB/pick.log"

	_got=$(grep '^FFC_TEMP_HIGH=' "$SB/mod/config.conf" 2>/dev/null | cut -d= -f2)
	if [ "$_got" = "$_want" ]; then
		ok "$_desc：FFC_TEMP_HIGH=$_got"
	else
		bad "$_desc：FFC_TEMP_HIGH=$_got，期望 $_want"
		sed 's/^/        /' "$SB/pick.log"
	fi
}

echo "=== 档位选择 ==="
run_pick "按音量下"   volumedown ""     1 48
run_pick "按音量上"   volumeup   ""     1 56
run_pick "不按键"     none       ""     1 56
run_pick "FORCE_TIER=safe" none   safe   1 48
run_pick "FORCE_TIER=max"  none   max    1 56
run_pick "FORCE_TIER 乱填" none   bogus  1 56
run_pick "TIER_PROMPT=0"   none   ""     0 56

# FORCE_TIER 生效时不该去等按键
echo "=== FORCE_TIER 不等待按键 ==="
cp "$SRC/config.conf" "$SB/mod/config.conf"
(
	MODDIR="$SB/mod"
	. "$MODDIR/common.sh" >/dev/null 2>&1
	FORCE_TIER=safe
	TIER_PROMPT=1
	read_volume_key() { echo "SHOULD_NOT_BE_CALLED"; exit 9; }
	tier_pick
) 2> "$SB/force.log"
if grep -q 'SHOULD_NOT_BE_CALLED' "$SB/force.log" 2>/dev/null; then
	bad "FORCE_TIER=safe 时仍然去读了按键"
else
	ok "FORCE_TIER=safe 时跳过了按键等待"
fi

# ------------------------------------------------------- 3. 描述文案 ---
echo "=== 档位描述 ==="
for pair in "48:安全档 0~48℃ 全速" "56:极限档 0~56℃ 全速" ":参考表原始值（0~55℃ 全速）"; do
	_v="${pair%%:*}"
	_want="${pair#*:}"
	(
		MODDIR="$SB/mod"
		. "$MODDIR/common.sh" >/dev/null 2>&1
		FFC_TEMP_HIGH="$_v"
		tier_desc
	) > "$SB/desc.txt"
	_got=$(cat "$SB/desc.txt")
	if [ "$_got" = "$_want" ]; then
		ok "描述[$_v] -> $_got"
	else
		bad "描述[$_v] 期望 [$_want]，实际 [$_got]"
	fi
done

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "=== 音量键选档测试全部通过 ==="
	exit 0
fi
echo "=== 音量键选档测试失败：$FAILED 项 ==="
exit 1
