#!/bin/sh
# 模拟「厂商 OTA 更新过 dtbo」：跟充电无关的部分被改过，充电节点原样保留。
#
# 模块必须满足:
#   1) 仍然能顺利跑通（解包 -> 改写 -> 打包 -> 复核 -> 刷写 -> 回读校验）
#   2) 含有充电节点的条目被正确改写
#   3) 不含充电节点的条目一个字节都不动
#   4) 与充电无关的新节点（ota_drift_marker）不能被冲掉
#   5) 条目数量不能变
#   6) 第二次运行要识别成「已经是本模块刷入的版本」并跳过
#
# 用法: sh tools/test_drift.sh <模块目录> <drift 镜像> <dtc> <沙盒目录>

MODDIR="$1"
FAKEPART="$2"
DTC="$3"
SANDBOX="$4"
DTC_REAL="$DTC"
NAME=$(basename "$FAKEPART")

FAIL=0
ok()   { echo "  [ ok ] $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
need() { [ "$1" = "$2" ] && ok "$3" || bad "$3（得到 '$1'，期望 '$2'）"; }

mkdir -p "$SANDBOX"
rm -rf "$SANDBOX/mod" "$SANDBOX/before" "$SANDBOX/after" "$SANDBOX/work"
mkdir -p "$SANDBOX/mod"
cp "$MODDIR/module.prop" "$MODDIR/common.sh" "$MODDIR/config.conf" "$SANDBOX/mod/"
cp -r "$MODDIR/ref" "$SANDBOX/mod/"
cp -r "$MODDIR/bin" "$SANDBOX/mod/"

# 主机没法执行 aarch64 的 dtc，换成主机的
cp "$DTC" "$SANDBOX/mod/bin/dtc-aarch64"
chmod 755 "$SANDBOX/mod/bin/dtc-aarch64"

cp "$FAKEPART" "$SANDBOX/partition.img"
chmod u+w "$SANDBOX/partition.img" 2>/dev/null
rm -f "$SANDBOX/partition.img.lock" 2>/dev/null

MODDIR="$SANDBOX/mod"
. "$MODDIR/common.sh"

# ---- 覆盖依赖设备环境的函数 ----
detect_slot() {
	SLOT="_a"
	SLOTNAME="dtbo_a"
	return 0
}
resolve_partition() {
	PART="$SANDBOX/partition.img"
	PSIZE=$(wc -c < "$PART" | tr -d ' \t\r\n')
	REAL="$PART"
	DEVNAME="partition.img"
	return 0
}
log_boot_state() { return 0; }
pick_workdir() {
	_d="$SANDBOX/work"
	rm -rf "$_d"
	mkdir -p "$_d" || return 1
	echo "$_d"
	return 0
}
prepare_dtc() { DTC="$DTC_REAL"; return 0; }
boot_epoch() { echo 1700000000; }

echo "=== $NAME ==="

# ---- 刷写前：把原镜像拆开留个底 ----
PSIZE=$(wc -c < "$SANDBOX/partition.img" | tr -d ' \t\r\n')
WORK="$SANDBOX/before"
mkdir -p "$WORK"
split_dtbs "$SANDBOX/partition.img" || { bad "拆不开原镜像"; exit 1; }
N_ENTRY=$CNT
echo "  刷写前: $IMG_FORMAT，$N_ENTRY 个 DTB"

_i=0
while [ "$_i" -lt "$N_ENTRY" ]; do
	"$DTC" -I dtb -O dts -o "$WORK/b.$_i.dts" "$WORK/dtb.$_i" 2>/dev/null || {
		bad "反编译 dtb.$_i 失败"; exit 1; }
	# 三种条目分开看：带 jeita 的、只带 charger_thermal 的、一个充电节点都没有的
	# 注意：反编译出来的 dts 有没有 label（`名字: 名字 {`）取决于 dtb 里有没有 __symbols__，
	# 不同版本的 dtc 行为不一样。这里一律按「节点名 + 花括号」认，别依赖冒号。
	if grep -qE '(^|[[:space:]])mca_charger_thermal[[:space:]]*\{' "$WORK/b.$_i.dts"; then
		echo "yes" > "$WORK/th.$_i"
	else
		echo "no" > "$WORK/th.$_i"
	fi
	if grep -qE '(^|[[:space:]])mca_buckchg_jeita[[:space:]]*\{' "$WORK/b.$_i.dts"; then
		echo "jeita" > "$WORK/kind.$_i"
	elif [ "$(cat "$WORK/th.$_i")" = "yes" ]; then
		echo "thermal" > "$WORK/kind.$_i"
	else
		echo "none" > "$WORK/kind.$_i"
	fi
	sha256sum "$WORK/dtb.$_i" | cut -d' ' -f1 > "$WORK/sha.$_i"
	_i=$((_i + 1))
done

# 无关节点必须存在于每个条目里（这是「OTA 改了别的地方」的证据）
_i=0
while [ "$_i" -lt "$N_ENTRY" ]; do
	grep -q 'ota_drift_marker' "$WORK/b.$_i.dts" \
		|| bad "夹具本身有问题: dtb.$_i 里没有 ota_drift_marker"
	_i=$((_i + 1))
done

# ---- 跑一遍 ----
run_main > "$SANDBOX/run1.log" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
	bad "run_main 退出码 $RC（期望 0）"
	tail -n 20 "$SANDBOX/run1.log" | sed 's/^/         /'
	echo "=== $NAME 失败 ==="
	exit 1
fi
ok "run_main 退出码 0"

# ---- 刷写后：重新拆开逐条核对 ----
WORK="$SANDBOX/after"
mkdir -p "$WORK"
PSIZE=$(wc -c < "$SANDBOX/partition.img" | tr -d ' \t\r\n')
split_dtbs "$SANDBOX/partition.img" || { bad "刷写后拆不开"; exit 1; }
need "$CNT" "$N_ENTRY" "条目数量没变"

_i=0
while [ "$_i" -lt "$N_ENTRY" ]; do
	"$DTC" -I dtb -O dts -o "$WORK/a.$_i.dts" "$WORK/dtb.$_i" 2>/dev/null || {
		bad "反编译刷写后的 dtb.$_i 失败"; exit 1; }

	# 无关节点必须还在
	if grep -q 'ota_drift_marker' "$WORK/a.$_i.dts"; then
		ok "条目 $_i: 无关节点 ota_drift_marker 保住了"
	else
		bad "条目 $_i: 无关节点 ota_drift_marker 被冲掉了"
	fi

	_kind=$(cat "$SANDBOX/before/kind.$_i")
	case "$_kind" in
	jeita)
		if grep -q 'ffc_temp_high = <0x38>;' "$WORK/a.$_i.dts"; then
			ok "条目 $_i: ffc_temp_high = <0x38>"
		else
			bad "条目 $_i: ffc_temp_high 没改成 0x38"
		fi
		if grep -q '"18", "56"' "$WORK/a.$_i.dts"; then
			ok "条目 $_i: JEITA 全速段 18~56℃"
		else
			bad "条目 $_i: JEITA 里没有 \"18\", \"56\""
		fi
		;;
	thermal)
		ok "条目 $_i: 只带 mca_charger_thermal（厂商拆分了节点）"
		;;
	esac

	if [ "$(cat "$SANDBOX/before/th.$_i")" = "yes" ]; then
		if sed -n '/mca_charger_thermal[[:space:]]*{/,/};/p' "$WORK/a.$_i.dts" \
			| grep -q 'status = "disabled";'; then
			ok "条目 $_i: mca_charger_thermal = disabled"
		else
			bad "条目 $_i: mca_charger_thermal 没被禁用"
		fi
	elif [ "$_kind" = "none" ]; then
		_new=$(sha256sum "$WORK/dtb.$_i" | cut -d' ' -f1)
		_old=$(cat "$SANDBOX/before/sha.$_i")
		need "$_new" "$_old" "条目 $_i: 不含充电节点，必须原样保留"
	fi
	_i=$((_i + 1))
done

# ---- 第二次运行必须跳过 ----
run_main > "$SANDBOX/run2.log" 2>&1
if grep -q '已经是本模块刷入的版本' "$SANDBOX/run2.log"; then
	ok "第二次运行识别为已刷过并跳过"
else
	bad "第二次运行没有跳过"
	tail -n 10 "$SANDBOX/run2.log" | sed 's/^/         /'
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
	echo "=== $NAME 通过 ==="
	exit 0
fi
echo "=== $NAME 有 $FAIL 项失败 ==="
exit 1
