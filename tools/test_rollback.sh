#!/bin/sh
# PC 端回滚测试：模拟「刷入的 dtbo 反复开机都没走到开机后期」，
# 验证模块会在第 3 次开机时自动把备份写回分区并停用自己。
#
# 用法: sh tools/test_rollback.sh <模块目录> <假分区镜像> <dtc> <测试沙盒目录>

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
cp "$FAKEPART" "$SANDBOX/original.img"

MODDIR="$SANDBOX/mod"
. "$MODDIR/common.sh"

# 这个测试模拟的是「每次开机」，所以要打开开机阶段的状态机
BOOT_PHASE=1

detect_slot() { SLOT="_a"; SLOTNAME="dtbo_a"; log "[test] 模拟槽位 A"; }
resolve_partition() {
	PART="$SANDBOX/partition.img"
	PSIZE=$(wc -c < "$PART" | tr -d ' \t\r\n')
	REAL="$PART"; DEVNAME="partition.img"
	log "[test] 模拟分区 $PART ($PSIZE 字节)"
	return 0
}
log_boot_state() { return 0; }
pick_workdir() { _d="$SANDBOX/work"; rm -rf "$_d"; mkdir -p "$_d" || return 1; echo "$_d"; }
prepare_dtc() { DTC="$DTC_REAL"; return 0; }

# 主机上没有 /proc/uptime，固定开机时刻让 mtime 比较行为确定
boot_epoch() { echo 1800000000; }

mkdir -p "$MODDIR/state" "$MODDIR/backup" "$MODDIR/logs"

P="$MODDIR/state/pending"

# 构造「上一次开机刷入、尚未确认」的状态：pending 的 mtime 设为很久以前
cp "$SANDBOX/original.img" "$MODDIR/backup/orig.img"
echo "$MODDIR/backup/orig.img" > "$P"
touch -t 202001010000 "$P" 2>/dev/null || touch -d "2020-01-01" "$P" 2>/dev/null
echo "boot-of-last-flash" > "$MODDIR/state/pending_boot"
echo "TOKEN-RB" > "$MODDIR/state/pending_id"
echo 0 > "$MODDIR/state/pending_tries"

# 把分区改成「坏镜像」（全 0），模拟刷坏的 dtbo
dd if=/dev/zero of="$SANDBOX/partition.img" bs=4096 count=2048 2>/dev/null
echo "[test] 分区已被改成坏镜像，大小 $(wc -c < "$SANDBOX/partition.img")"

echo
echo "=== 第 1 次开机（tries 0->1，应只跳过不刷写） ==="
run_main
echo "退出码: $?"
if cmp -s "$SANDBOX/partition.img" "$SANDBOX/original.img"; then
	echo "[test] 意外：第 1 次开机就回滚了"
	exit 1
fi
echo "[test] 第 1 次开机未回滚，符合预期（tries=$(cat "$MODDIR/state/pending_tries")）"

echo
echo "=== 第 2 次开机（tries 1->2，仍只跳过） ==="
run_main
echo "退出码: $?"
if cmp -s "$SANDBOX/partition.img" "$SANDBOX/original.img"; then
	echo "[test] 意外：第 2 次开机就回滚了"
	exit 1
fi
echo "[test] 第 2 次开机未回滚，符合预期（tries=$(cat "$MODDIR/state/pending_tries")）"

echo
echo "=== 第 3 次开机（tries 2->3，应触发回滚） ==="
run_main
echo "退出码: $?"

echo
echo "=== 结果检查 ==="
if cmp -s "$SANDBOX/partition.img" "$SANDBOX/original.img"; then
	echo "[test] 回滚成功：分区内容已恢复为原始镜像"
else
	echo "[test] 回滚失败：分区内容与原始镜像不一致"
	exit 1
fi

if [ -f "$MODDIR/state/halted" ]; then
	echo "[test] 模块已停用（state/halted）: $(cat "$MODDIR/state/halted")"
else
	echo "[test] 未写入 halted 标记"
	exit 1
fi

echo
echo "=== 再次执行（应因 halted 而跳过，不再碰分区） ==="
run_main
echo "退出码: $?"

echo
echo "=== 测试通过 ==="
