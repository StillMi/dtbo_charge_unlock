#!/bin/sh
# 生命周期测试：安装阶段刷写 -> 重启 -> 开机 -> OTA 后仍然只有手动才改。
#
# 本次改动的核心约定（用户要求「删掉开机验证，只验证已生效」）：
#   * 开机阶段（service.sh）绝不改写分区
#   * 不再有「等待开机确认 / 连续 3 次没起来就回滚」这套状态机
#   * 判断有没有生效只有一条路：monitor.sh --full 的 state_cur_head
#     与 state/last_head 是否一致
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
PART="$SANDBOX/partition.img"
FAILED=0

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
		echo "[FAIL] $1：开机脚本竟然跑了刷写流程"
		FAILED=1
	fi
}

# 「已生效」的判据：分区头部哈希 == state/last_head
check_applied() {
	_head=$(cat "$M/state/last_head" 2>/dev/null)
	_cur=$(dd if="$PART" bs=1048576 count=1 2>/dev/null | sha256sum | cut -d' ' -f1)
	if [ -n "$_head" ] && [ "$_head" = "$_cur" ]; then
		echo "[ OK ] $1：已生效（分区头部哈希与刷入时一致）"
	else
		echo "[FAIL] $1：未生效（last_head=$_head cur=$_cur）"
		FAILED=1
	fi
}

# ---------------------------------------------------------------- 第 1 次开机 --
echo
echo "=== 模拟第 1 次开机：service.sh（开机后期） ==="
sh "$M/service.sh" >"$SANDBOX/boot1-svc.log" 2>&1
echo "  退出码: $?"
check_untouched "第 1 次开机" "$SANDBOX/boot1-svc.log"
check_applied   "第 1 次开机"

# 不该再产生「等待确认」相关的状态文件
_STRAY=""
for f in pending pending_id pending_tries pending_tries_boot confirmed halted; do
	[ -f "$M/state/$f" ] && _STRAY="$_STRAY $f"
done
if [ -z "$_STRAY" ]; then
	echo "[ OK ] 没有残留 pending / confirmed / halted 状态文件"
else
	echo "[FAIL] 仍有残留状态文件:$_STRAY"
	FAILED=1
fi

# ---------------------------------------------------------------- 第 2 次开机 --
echo
echo "=== 模拟第 2 次开机：反复开机也不该动分区 ==="
sh "$M/service.sh" >"$SANDBOX/boot2-svc.log" 2>&1
sh "$M/service.sh" >"$SANDBOX/boot2b-svc.log" 2>&1
check_untouched "第 2 次开机" "$SANDBOX/boot2-svc.log"
check_applied   "第 2 次开机"
if [ -f "$M/state/halted" ]; then
	echo "[FAIL] 出现了 halted（不应该再有自动回滚）"
	FAILED=1
else
	echo "[ OK ] 没有自动回滚 / 停用"
fi

# -------------------------------------------- 第 3 次开机：模拟 OTA 换回原厂 ---
echo
echo "=== 模拟系统 OTA：dtbo 被换回原厂，再开机 ==="
cp "$FAKEPART" "$PART"
SHA_STOCK=$(sha256sum "$PART" 2>/dev/null | cut -d' ' -f1)
sh "$M/service.sh" >"$SANDBOX/boot3-svc.log" 2>&1
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

# 此时「是否生效」应该变成「否」
_head=$(cat "$M/state/last_head" 2>/dev/null)
_cur=$(dd if="$PART" bs=1048576 count=1 2>/dev/null | sha256sum | cut -d' ' -f1)
if [ -n "$_head" ] && [ "$_head" != "$_cur" ]; then
	echo "[ OK ] OTA 之后页面会显示「需重新应用」"
else
	echo "[FAIL] OTA 之后哈希仍然一致，页面不会提示重新应用"
	FAILED=1
fi

echo
if [ "$FAILED" -eq 0 ]; then
	echo "=== 生命周期测试通过 ==="
	exit 0
fi
echo "=== 生命周期测试未通过 ==="
exit 1
