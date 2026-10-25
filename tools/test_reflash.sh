#!/bin/sh
# 模拟「模块升级后 state/ 丢了，但分区里已经是本模块刷入的镜像」。
#
# 这是最容易出事的一个场景：升级模块会把整个模块目录换掉，state/ 和
# backup/ 一起没了。这时用户再点一次「运行修改」，模块必须:
#   1) 认出来分区已经是目标状态，不重复刷写、不报错
#   2) 绝对不能把「已经改过的镜像」当成原厂备份存下来
#      （否则 restore.sh 会把改过的镜像当原厂写回去）
#   3) 把状态补记回去（last_sha / last_head / flash_high），下次能正常跳过
#
# 做法不另造夹具：先用真实流程刷一遍，再把 state/ 和 backup/ 整个删掉，
# 然后第二次运行 —— 这样测的就是设备上真实会发生的路径。
#
# 用法: sh tools/test_reflash.sh <模块目录> <原厂镜像> <dtc> <沙盒目录>

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
rm -rf "$SANDBOX/mod" "$SANDBOX/work"
mkdir -p "$SANDBOX/mod"
cp "$MODDIR/module.prop" "$MODDIR/common.sh" "$MODDIR/config.conf" "$SANDBOX/mod/"
cp -r "$MODDIR/ref" "$SANDBOX/mod/"
cp -r "$MODDIR/bin" "$SANDBOX/mod/"
mkdir -p "$SANDBOX/mod/state" "$SANDBOX/mod/backup" "$SANDBOX/mod/logs"

# 主机没法执行 aarch64 的 dtc，换成主机的
cp "$DTC" "$SANDBOX/mod/bin/dtc-aarch64"
chmod 755 "$SANDBOX/mod/bin/dtc-aarch64"

cp "$FAKEPART" "$SANDBOX/partition.img"
chmod u+w "$SANDBOX/partition.img" 2>/dev/null

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

# ---- 第一步：正常刷一遍（模拟用户之前刷过）----
run_main > "$SANDBOX/run0.log" 2>&1
if [ $? -ne 0 ]; then
	bad "第一次（正常）刷写就失败了"
	tail -n 15 "$SANDBOX/run0.log" | sed 's/^/         /'
	echo "=== $NAME 失败 ==="
	exit 1
fi
ok "第一次正常刷写成功"

FLASHED_SHA=$(sha256sum "$SANDBOX/partition.img" | cut -d' ' -f1)
FLASHED_HEAD=$(dd if="$SANDBOX/partition.img" bs=1048576 count=1 2>/dev/null | sha256sum | cut -d' ' -f1)
_n0=$(ls -1 "$MODDIR/backup"/*.img 2>/dev/null | wc -l | tr -d ' \t\r\n')
echo "  刷完后分区 sha256: $FLASHED_SHA（原厂备份 $_n0 份）"

# ---- 第二步：把 state/ 和 backup/ 整个删掉（模块升级会换掉整个目录）----
rm -rf "$MODDIR/state" "$MODDIR/backup"
mkdir -p "$MODDIR/state" "$MODDIR/backup"
ok "已清空 state/ 与 backup/（模拟模块升级）"

# ---- 第三步：再点一次「运行修改」----
run_main > "$SANDBOX/run1.log" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
	bad "run_main 退出码 $RC（期望 0）"
	tail -n 20 "$SANDBOX/run1.log" | sed 's/^/         /'
	echo "=== $NAME 失败 ==="
	exit 1
fi
ok "run_main 退出码 0"

if grep -q '已经是本模块的目标值' "$SANDBOX/run1.log"; then
	ok "识别出分区已是目标状态"
else
	bad "没识别出「已经是本模块的目标值」"
	tail -n 15 "$SANDBOX/run1.log" | sed 's/^/         /'
fi

if grep -q '已经是本模块刷入的版本，无需重复刷写' "$SANDBOX/run1.log"; then
	bad "误走了「按哈希跳过」分支（state 是空的，不该走这条）"
else
	ok "没有误走「按哈希跳过」分支"
fi

# ---- 分区一个字节都不许动 ----
AFTER_SHA=$(sha256sum "$SANDBOX/partition.img" | cut -d' ' -f1)
need "$AFTER_SHA" "$FLASHED_SHA" "分区内容未被改写"

# ---- 绝不能生成假的原厂备份 ----
if [ -f "$MODDIR/state/backup" ]; then
	bad "生成了 state/backup（会把改过的镜像当成原厂）"
else
	ok "没有生成 state/backup"
fi
_n=$(ls -1 "$MODDIR/backup"/*.img 2>/dev/null | wc -l | tr -d ' \t\r\n')
need "$_n" "0" "backup/ 里没有假的原厂镜像"

# ---- 状态必须补记回去 ----
_got=$(cat "$MODDIR/state/last_sha" 2>/dev/null)
need "$_got" "$FLASHED_SHA" "state/last_sha 已补记"

_got=$(cat "$MODDIR/state/last_head" 2>/dev/null)
need "$_got" "$FLASHED_HEAD" "state/last_head 已补记"

_got=$(cat "$MODDIR/state/flash_high" 2>/dev/null)
need "$_got" "56" "state/flash_high 已补记（默认极限档）"

# ---- 第四次运行必须按哈希跳过 ----
run_main > "$SANDBOX/run2.log" 2>&1
if grep -q '已经是本模块刷入的版本' "$SANDBOX/run2.log"; then
	ok "再运行一次按哈希跳过"
else
	bad "再运行一次没有跳过"
	tail -n 10 "$SANDBOX/run2.log" | sed 's/^/         /'
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
	echo "=== $NAME 通过 ==="
	exit 0
fi
echo "=== $NAME 有 $FAIL 项失败 ==="
exit 1
