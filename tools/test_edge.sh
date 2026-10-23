#!/bin/sh
# 边界情况测试：
#   1) confirmed 命中时，下一次开机应清除 pending
#   2) 没有 confirmed、tries 未到 3，应只跳过不回滚
#   3) 本次开机内刚刷写（pending 比开机还新），不应计数也不应回滚
#   4) verify_dts 对未改写的 dts 必须报错
#   5) verify_dts 对改写后的 dts 必须通过
#   6) FORCE_SLOT 能强制指定槽位
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

# 主机上没有 /proc/uptime，boot_epoch 会退化成「当前时刻」，导致 mtime 比较
# 出现一秒级的边界抖动。测试里固定一个开机时刻，行为才是确定的。
boot_epoch() { echo 1800000000; }

mkdir -p "$MODDIR/state" "$MODDIR/backup" "$MODDIR/logs" "$SANDBOX/work"

FAILED=0
P="$MODDIR/state/pending"

# 让 pending 看起来像「上一次开机」写下的：mtime 早于固定的开机时刻
age_pending() {
	touch -t 202001010000 "$P" 2>/dev/null || touch -d "2020-01-01" "$P" 2>/dev/null
}
# 让 pending 看起来像「本次开机内」写下的：mtime 晚于固定的开机时刻
freshen_pending() {
	touch -t 203001010000 "$P" 2>/dev/null || touch -d "2030-01-01" "$P" 2>/dev/null
}

# ---------------------------------------------------------------- 场景 1 ----
echo "=== 场景 1: confirmed 命中后再开机，应清除 pending ==="
cp "$FAKEPART" "$MODDIR/backup/orig.img"
echo "$MODDIR/backup/orig.img" > "$P"
age_pending
echo "boot-of-last-flash" > "$MODDIR/state/pending_boot"
echo "TOKEN-AAA" > "$MODDIR/state/pending_id"
echo 0 > "$MODDIR/state/pending_tries"
echo "TOKEN-AAA" > "$MODDIR/state/confirmed"
sha256sum "$SANDBOX/partition.img" | cut -d' ' -f1 > "$MODDIR/state/last_sha"
run_main >/dev/null 2>&1
if [ -f "$P" ]; then
	echo "[FAIL] pending 未被清除"
	FAILED=1
else
	echo "[ OK ] pending 已清除（confirmed 命中）"
fi
rm -f "$MODDIR/state/confirmed" "$MODDIR/state/last_sha" "$MODDIR/state/halted" \
      "$MODDIR/state/pending_id"

# ---------------------------------------------------------------- 场景 1b ---
echo
echo "=== 场景 1b: confirmed 令牌不匹配，不应算作已确认 ==="
echo "$MODDIR/backup/orig.img" > "$P"
age_pending
echo "TOKEN-BBB" > "$MODDIR/state/pending_id"
echo 0 > "$MODDIR/state/pending_tries"
echo "TOKEN-OLD" > "$MODDIR/state/confirmed"
run_main >/dev/null 2>&1
T=$(cat "$MODDIR/state/pending_tries" 2>/dev/null)
if [ "$T" = "1" ] && [ -f "$P" ]; then
	echo "[ OK ] 令牌不匹配时不确认（tries=1，pending 保留）"
else
	echo "[FAIL] tries=$T，pending 存在=$([ -f "$P" ] && echo yes || echo no)"
	FAILED=1
fi

# ---------------------------------------------------------------- 场景 2 ----
echo
echo "=== 场景 2: 没有 confirmed、tries 未到 3，应只跳过不回滚 ==="
echo 0 > "$MODDIR/state/pending_tries"
rm -f "$MODDIR/state/confirmed"
run_main >/dev/null 2>&1
T=$(cat "$MODDIR/state/pending_tries" 2>/dev/null)
if [ "$T" = "1" ] && [ -f "$P" ]; then
	echo "[ OK ] 已跳过且 tries=1，未回滚"
else
	echo "[FAIL] tries=$T"
	FAILED=1
fi

# ---------------------------------------------------------------- 场景 3 ----
echo
echo "=== 场景 3: 本次开机内刚刷写，不应计数 ==="
freshen_pending
echo 0 > "$MODDIR/state/pending_tries"
run_main >/dev/null 2>&1
T=$(cat "$MODDIR/state/pending_tries" 2>/dev/null)
if [ "$T" = "0" ]; then
	echo "[ OK ] 未计数（tries 仍为 0），符合预期"
else
	echo "[FAIL] tries=$T，不该计数"
	FAILED=1
fi
rm -f "$P" "$MODDIR/state/pending_boot" "$MODDIR/state/pending_id" \
      "$MODDIR/state/pending_tries" "$MODDIR/state/last_sha"

# ---------------------------------------------------------------- 场景 4 ----
echo
echo "=== 场景 4: verify_dts 对未改写的 dts 必须报错 ==="
W2="$SANDBOX/work2"
rm -rf "$W2"; mkdir -p "$W2"
WORK="$W2"
build_runtime_rules >/dev/null 2>&1
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
