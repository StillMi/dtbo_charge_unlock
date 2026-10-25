#!/bin/sh
# 边界情况测试：
#   1) 没有 pending 时，service.sh 什么也不做
#   2) 残留的旧版本 pending 文件不会让开机脚本动手改分区
#   3) 刷写后「是否生效」的判据（last_head vs 分区头部）能正确区分
#   4) verify_dts 对未改写的 dts 必须报错
#   5) verify_dts 对改写后的 dts 必须通过
#   6) FORCE_SLOT 能强制指定槽位
#   7) 不指定 FORCE_SLOT 时按单分区处理
#
# 用法: sh tools/test_edge.sh <模块目录> <假分区镜像> <dtc> <沙盒目录>

MODDIR="$1"
FAKEPART="$2"
DTC="$3"
SANDBOX="$4"
DTC_REAL="$DTC"

mkdir -p "$SANDBOX"
rm -rf "$SANDBOX/mod"
mkdir -p "$SANDBOX/mod"
cp "$MODDIR/module.prop" "$MODDIR/common.sh" "$MODDIR/config.conf" "$SANDBOX/mod/"
cp "$MODDIR/service.sh" "$SANDBOX/mod/"
cp -r "$MODDIR/ref" "$SANDBOX/mod/"
cp -r "$MODDIR/bin" "$SANDBOX/mod/"
cp "$FAKEPART" "$SANDBOX/partition.img"

MODDIR="$SANDBOX/mod"
. "$MODDIR/common.sh"


# 注意：不覆盖 detect_slot —— 用真实的实现，靠 FORCE_SLOT=a 在主机上指定槽位
FORCE_SLOT=a

resolve_partition() {
	PART="$SANDBOX/partition.img"
	PSIZE=$(wc -c < "$PART" | tr -d ' \t\r\n')
	REAL="$PART"; DEVNAME="partition.img"
	return 0
}
log_boot_state() { return 0; }
pick_workdir() { _d="$SANDBOX/work"; rm -rf "$_d"; mkdir -p "$_d" || return 1; echo "$_d"; }
prepare_dtc() { DTC="$DTC_REAL"; return 0; }

mkdir -p "$MODDIR/state" "$MODDIR/backup" "$MODDIR/logs" "$SANDBOX/work"

FAILED=0
SHA_STOCK=$(sha256sum "$SANDBOX/partition.img" | cut -d' ' -f1)

# ---------------------------------------------------------------- 场景 1 ----
echo "=== 场景 1: 没有任何状态文件时，开机脚本不碰分区 ==="
sh "$MODDIR/service.sh" >"$SANDBOX/svc1.log" 2>&1
_rc=$?
[ "$_rc" = "0" ] && echo "[ OK ] service.sh 退出码 0" || { echo "[FAIL] 退出码 $_rc"; FAILED=1; }
_now=$(sha256sum "$SANDBOX/partition.img" | cut -d' ' -f1)
[ "$_now" = "$SHA_STOCK" ] && echo "[ OK ] 分区未变" || { echo "[FAIL] 分区被改了"; FAILED=1; }
if [ -f "$MODDIR/state/last_sha" ]; then
	echo "[FAIL] 开机脚本不该产生刷写记录"
	FAILED=1
else
	echo "[ OK ] 没有产生刷写记录"
fi

# ---------------------------------------------------------------- 场景 2 ----
echo
echo "=== 场景 2: 旧版本残留的 pending 也不会让开机脚本动手 ==="
cp "$FAKEPART" "$MODDIR/backup/orig.img"
echo "$MODDIR/backup/orig.img" > "$MODDIR/state/pending"
echo "TOKEN-OLD" > "$MODDIR/state/pending_id"
echo 2 > "$MODDIR/state/pending_tries"
sh "$MODDIR/service.sh" >"$SANDBOX/svc2.log" 2>&1
_now=$(sha256sum "$SANDBOX/partition.img" | cut -d' ' -f1)
[ "$_now" = "$SHA_STOCK" ] && echo "[ OK ] 分区仍未变" || { echo "[FAIL] 残留 pending 导致分区被改"; FAILED=1; }
if [ -f "$MODDIR/state/halted" ]; then
	echo "[FAIL] 不该再写 halted（自动回滚已删除）"
	FAILED=1
else
	echo "[ OK ] 没有 halted"
fi
rm -f "$MODDIR/state/pending" "$MODDIR/state/pending_id" \
      "$MODDIR/state/pending_tries"

# ---------------------------------------------------------------- 场景 3 ----
echo
echo "=== 场景 3: 「是否生效」判据（last_head vs 分区头部） ==="
_head=$(dd if="$SANDBOX/partition.img" bs=1048576 count=1 2>/dev/null | sha256sum | cut -d' ' -f1)
echo "$_head" > "$MODDIR/state/last_head"
_cur=$(dd if="$SANDBOX/partition.img" bs=1048576 count=1 2>/dev/null | sha256sum | cut -d' ' -f1)
if [ "$_head" = "$_cur" ]; then
	echo "[ OK ] 一致时判定为「已生效」"
else
	echo "[FAIL] 一致时却判成不一致"
	FAILED=1
fi
# 模拟 OTA：分区头部被换掉
printf 'STOCKXXX' | dd of="$SANDBOX/partition.img" bs=1 seek=0 conv=notrunc 2>/dev/null
_cur2=$(dd if="$SANDBOX/partition.img" bs=1048576 count=1 2>/dev/null | sha256sum | cut -d' ' -f1)
if [ "$_head" != "$_cur2" ]; then
	echo "[ OK ] 被覆盖时判定为「需重新应用」"
else
	echo "[FAIL] 被覆盖了却仍判成一致"
	FAILED=1
fi
rm -f "$MODDIR/state/last_head"

# ---------------------------------------------------------------- 场景 4 ----
echo
echo "=== 场景 4: verify_dts 对未改写的 dts 必须报错 ==="
W2="$SANDBOX/work2"
rm -rf "$W2"; mkdir -p "$W2"
WORK="$W2"
build_runtime_rules >/dev/null 2>&1
# split_dtbs 会用 PSIZE 校验总长度，前面不再经过 run_main，这里要自己补上
PSIZE=$(wc -c < "$FAKEPART" | tr -d ' \t\r\n')
cp "$FAKEPART" "$SANDBOX/partition.img"
split_dtbs "$SANDBOX/partition.img" >/dev/null 2>&1 || { echo "[FAIL] 无法拆出 DTB"; exit 1; }
STOCK=""
_n=0
while [ "$_n" -lt "$CNT" ]; do
	"$DTC" -I dtb -O dts -o "$SANDBOX/stock.dts" "$W2/dtb.$_n" 2>/dev/null || { _n=$((_n + 1)); continue; }
	if grep -q 'mca_buckchg_jeita' "$SANDBOX/stock.dts"; then
		STOCK="$W2/dtb.$_n"
		break
	fi
	_n=$((_n + 1))
done
[ -n "$STOCK" ] || { echo "[FAIL] 分区里找不到含充电节点的 DTB"; exit 1; }
echo "  使用 $STOCK（$(wc -l < "$SANDBOX/stock.dts") 行）"

if verify_dts "$SANDBOX/stock.dts" >/dev/null 2>&1; then
	echo "[FAIL] 未改写的 dts 居然通过了校验"
	FAILED=1
else
	echo "[ OK ] 未改写的 dts 被正确拒绝"
fi

echo
echo "=== 场景 5: verify_dts 对改写后的 dts 必须通过 ==="
sed -f "$W2/patch.sed" "$SANDBOX/stock.dts" > "$SANDBOX/patched.dts"
if verify_dts "$SANDBOX/patched.dts" >/dev/null 2>&1; then
	echo "[ OK ] 改写后的 dts 通过校验"
else
	echo "[FAIL] 改写后的 dts 未通过校验"
	FAILED=1
fi

echo
echo "=== 场景 6: FORCE_SLOT 强制槽位 ==="
FORCE_SLOT=b
detect_slot
if [ "$SLOTNAME" = "dtbo_b" ]; then
	echo "[ OK ] FORCE_SLOT=b 生效（目标 $SLOTNAME）"
else
	echo "[FAIL] FORCE_SLOT=b 未生效（目标 $SLOTNAME）"
	FAILED=1
fi
FORCE_SLOT=

echo
echo "=== 场景 7: 不指定 FORCE_SLOT 时能识别为单分区 ==="
detect_slot
if [ "$SLOTNAME" = "dtbo" ]; then
	echo "[ OK ] 未指定槽位时按单分区处理（$SLOTNAME）"
else
	echo "[FAIL] 期望 dtbo，实际 $SLOTNAME"
	FAILED=1
fi

echo
if [ "$FAILED" -eq 0 ]; then
	echo "=== 全部边界测试通过 ==="
	exit 0
fi
echo "=== 有测试未通过 ==="
exit 1
