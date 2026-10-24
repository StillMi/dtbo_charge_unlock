#!/bin/sh
# 生命周期测试：安装阶段刷写 -> 重启 -> 开机确认 -> 再重启清理状态。
# 这是模块的主路径，验证「装完重启即生效」并且状态机能正确收尾。
#
# 同时验证本次改动的核心约定：**开机阶段绝不改写分区**。
# 每次开机后都比对分区镜像的 sha256，必须与安装刷完时完全一致。
#
# 用法: sh tools/test_lifecycle.sh <模块目录> <假分区镜像> <dtc> <沙盒目录>

MODDIR="$1"
FAKEPART="$2"
DTC="$3"
SANDBOX="$4"

# 先跑安装阶段。
# 注意用本脚本自己的目录找 test_install.sh —— 测试脚本属于仓库，
# 不该要求被测模块目录里也带有 tools/（这样也能直接拿打包产物来测）。
MYDIR=$(dirname "$0")
sh "$MYDIR/test_install.sh" "$MODDIR" "$FAKEPART" "$DTC" "$SANDBOX" >/dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "[FAIL] 安装阶段测试未通过，先看 test_install.sh 的输出"
	exit 1
fi
echo "[ OK ] 安装阶段已完成刷写"

M="$SANDBOX/mod"
P="$M/state/pending"
PART="$SANDBOX/partition.img"
FAILED=0

[ -f "$P" ] || { echo "[FAIL] 安装后没有 pending 标记"; exit 1; }

SHA_FLASHED=$(sha256sum "$PART" 2>/dev/null | cut -d' ' -f1)
echo "[ OK ] 刷入后分区 sha256 = $SHA_FLASHED"

# 每次开机后都确认分区没被改动
check_untouched() {
	_now=$(sha256sum "$PART" 2>/dev/null | cut -d' ' -f1)
	if [ "$_now" = "$SHA_FLASHED" ]; then
		echo "[ OK ] $1：分区未被改动"
	else
		echo "[FAIL] $1：分区被改动了（$_now）"
		FAILED=1
	fi
	if grep -q 'dtbo_charge_unlock 开始' "$2" 2>/dev/null; then
		echo "[FAIL] $1：post-fs-data 竟然跑了刷写流程"
		FAILED=1
	fi
}

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
check_untouched "第 1 次开机" "$SANDBOX/boot1-pfd.log"

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
check_untouched "第 2 次开机" "$SANDBOX/boot2-pfd.log"

# ---------------------------------------------------------------- 第 3 次开机 --
echo
echo "=== 模拟第 3 次开机：无事可做，只做只读判断 ==="
sh "$M/post-fs-data.sh" >"$SANDBOX/boot3-pfd.log" 2>&1
if grep -q '状态机\|开始\|回滚' "$SANDBOX/boot3-pfd.log" 2>/dev/null; then
	: # 有内容也只是状态机日志，下面用分区哈希来判断
fi
check_untouched "第 3 次开机" "$SANDBOX/boot3-pfd.log"
if [ -f "$M/state/halted" ]; then
	echo "[FAIL] 第 3 次开机被误判为需要回滚"
	FAILED=1
else
	echo "[ OK ] 没有被误判为需要回滚"
fi

# -------------------------------------------- 第 4 次开机：模拟 OTA 换回原厂 ---
echo
echo "=== 模拟系统 OTA：dtbo 被换回原厂，再开机 ==="
cp "$FAKEPART" "$PART"
SHA_STOCK=$(sha256sum "$PART" 2>/dev/null | cut -d' ' -f1)
sh "$M/post-fs-data.sh" >"$SANDBOX/boot4-pfd.log" 2>&1
_now=$(sha256sum "$PART" 2>/dev/null | cut -d' ' -f1)
if [ "$_now" = "$SHA_STOCK" ]; then
	echo "[ OK ] 开机没有自动重新应用（符合「只手动触发」的约定）"
else
	echo "[FAIL] 开机把 OTA 后的分区又改回去了"
	FAILED=1
fi
if [ -f "$M/state/last_sha" ]; then
	echo "[ OK ] state/last_sha 仍保留，供页面判断「需重新应用」"
else
	echo "[FAIL] last_sha 丢失"
	FAILED=1
fi

echo
if [ "$FAILED" -eq 0 ]; then
	echo "=== 生命周期测试通过 ==="
	exit 0
fi
echo "=== 生命周期测试未通过 ==="
exit 1
