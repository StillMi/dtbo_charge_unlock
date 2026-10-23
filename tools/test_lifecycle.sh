#!/bin/sh
# 生命周期测试：安装阶段刷写 -> 重启 -> 开机确认 -> 再重启清理状态。
# 这是模块的主路径，验证「装完重启即生效」并且状态机能正确收尾。
#
# 用法: sh tools/test_lifecycle.sh <模块目录> <假分区镜像> <dtc> <沙盒目录>

MODDIR="$1"
FAKEPART="$2"
DTC="$3"
SANDBOX="$4"

# 先跑安装阶段
sh "$MODDIR/tools/test_install.sh" "$MODDIR" "$FAKEPART" "$DTC" "$SANDBOX" >/dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "[FAIL] 安装阶段测试未通过，先看 test_install.sh 的输出"
	exit 1
fi
echo "[ OK ] 安装阶段已完成刷写"

M="$SANDBOX/mod"
P="$M/state/pending"
FAILED=0

[ -f "$P" ] || { echo "[FAIL] 安装后没有 pending 标记"; exit 1; }

# ---------------------------------------------------------------- 第 1 次开机 --
# 安装发生在上一轮开机；把 pending 的 mtime 设成很久以前，模拟「重启之后」
touch -t 202001010000 "$P" 2>/dev/null || touch -d "2020-01-01" "$P" 2>/dev/null

echo
echo "=== 模拟第 1 次开机：post-fs-data.sh ==="
sh "$M/post-fs-data.sh" >"$SANDBOX/boot1-pfd.log" 2>&1
echo "  退出码: $?"
T=$(cat "$M/state/pending_tries" 2>/dev/null)
if [ "$T" = "1" ]; then
	echo "[ OK ] 已跳过刷写并计数 tries=1"
else
	echo "[FAIL] tries=$T，期望 1"
	FAILED=1
fi
if [ -f "$P" ]; then
	echo "[ OK ] pending 仍保留，等待开机后期确认"
else
	echo "[FAIL] pending 被提前清除"
	FAILED=1
fi

echo
echo "=== 模拟第 1 次开机：service.sh（开机后期） ==="
sh "$M/service.sh" >"$SANDBOX/boot1-svc.log" 2>&1
echo "  退出码: $?"
if [ -f "$M/state/confirmed" ]; then
	echo "[ OK ] 已写入 confirmed"
else
	echo "[FAIL] 没有写入 confirmed"
	FAILED=1
fi

# ---------------------------------------------------------------- 第 2 次开机 --
echo
echo "=== 模拟第 2 次开机：post-fs-data.sh ==="
sh "$M/post-fs-data.sh" >"$SANDBOX/boot2-pfd.log" 2>&1
echo "  退出码: $?"
if [ -f "$P" ]; then
	echo "[FAIL] pending 未被清除"
	FAILED=1
else
	echo "[ OK ] pending 已清除，状态机收尾完成"
fi

if grep -q '已确认可正常开机' "$SANDBOX/boot2-pfd.log" 2>/dev/null; then
	echo "[ OK ] 日志记录了确认信息"
else
	echo "[FAIL] 日志里没有确认信息"
	FAILED=1
fi

# ---------------------------------------------------------------- 第 3 次开机 --
echo
echo "=== 模拟第 3 次开机：应识别为已刷过并直接跳过 ==="
sh "$M/post-fs-data.sh" >"$SANDBOX/boot3-pfd.log" 2>&1
if grep -q '已经是本模块刷入的版本' "$SANDBOX/boot3-pfd.log" 2>/dev/null; then
	echo "[ OK ] 正确识别为已刷过"
else
	echo "[FAIL] 没有识别为已刷过"
	cat "$SANDBOX/boot3-pfd.log"
	FAILED=1
fi

echo
if [ "$FAILED" -eq 0 ]; then
	echo "=== 生命周期测试通过 ==="
	exit 0
fi
echo "=== 生命周期测试未通过 ==="
exit 1
