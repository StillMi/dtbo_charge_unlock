#!/bin/sh
# 「只在安装时改、之后手动触发」这条约定的回归测试。
#
#   1. 分区是原厂状态、模块没有任何刷写记录时，开机脚本**不许**动手
#   2. 手动运行 action.sh（KernelSU 的「操作」按钮 / WebUI 的「运行修改」）才刷写
#   3. 刷完之后再开机，仍然不许动手
#   4. state/last_head 必须与分区开头的哈希对得上（页面靠它判断「需重新应用」）
#
# 用法: sh tools/test_manual.sh <模块目录> <假分区镜像> <dtc> <沙盒目录>

MODDIR="$1"
FAKEPART="$2"
DTC_REAL="$3"
SANDBOX="$4"

rm -rf "$SANDBOX"
mkdir -p "$SANDBOX/mod" || exit 1

cp "$MODDIR/module.prop" "$MODDIR/common.sh" "$MODDIR/config.conf" "$SANDBOX/mod/"
cp "$MODDIR/post-fs-data.sh" "$MODDIR/service.sh" "$MODDIR/action.sh" "$SANDBOX/mod/"
cp "$MODDIR/restore.sh" "$SANDBOX/mod/"
cp -r "$MODDIR/ref" "$SANDBOX/mod/"
cp -r "$MODDIR/bin" "$SANDBOX/mod/"
cp "$DTC_REAL" "$SANDBOX/mod/bin/dtc-aarch64"
chmod 755 "$SANDBOX/mod/bin/dtc-aarch64"

cat > "$SANDBOX/mod/override.sh" <<EOF
detect_slot() { SLOT="_a"; SLOTNAME="dtbo_a"; log "[test] 模拟槽位 A"; }
resolve_partition() {
	PART="$SANDBOX/partition.img"
	PSIZE=\$(wc -c < "\$PART" | tr -d ' \t\r\n')
	REAL="\$PART"; DEVNAME="partition.img"
	log "[test] 模拟分区 \$PART (\$PSIZE 字节)"
	return 0
}
log_boot_state() { return 0; }
pick_workdir() { _d="$SANDBOX/work"; rm -rf "\$_d"; mkdir -p "\$_d" || return 1; echo "\$_d"; }
prepare_dtc() { DTC="$DTC_REAL"; return 0; }
EOF

cp "$FAKEPART" "$SANDBOX/partition.img"
cp "$FAKEPART" "$SANDBOX/original.img"

M="$SANDBOX/mod"
PART="$SANDBOX/partition.img"
SHA_STOCK=$(sha256sum "$PART" | cut -d' ' -f1)
FAILED=0

ok()  { echo "  [ OK ] $1"; }
bad() { echo "  [FAIL] $1"; FAILED=1; }

echo "=== 1. 原厂分区 + 无历史状态：开机脚本不该动手 ==="
sh "$M/post-fs-data.sh" > "$SANDBOX/pfd1.log" 2>&1
_rc=$?
[ "$_rc" -eq 0 ] && ok "post-fs-data 退出码 0" || bad "post-fs-data 退出码 $_rc"

_now=$(sha256sum "$PART" | cut -d' ' -f1)
[ "$_now" = "$SHA_STOCK" ] && ok "分区未被改动" || bad "分区被开机脚本改掉了"

if [ -f "$M/state/last_sha" ]; then
	bad "开机脚本不应产生刷写记录（state/last_sha 存在）"
else
	ok "没有产生刷写记录"
fi
if [ -f "$M/state/pending" ]; then
	bad "开机脚本不应写入 pending"
else
	ok "没有写入 pending"
fi
if grep -q 'dtbo_charge_unlock 开始' "$SANDBOX/pfd1.log" 2>/dev/null; then
	bad "post-fs-data 竟然执行了刷写流程"
else
	ok "没有执行刷写流程"
fi

echo
echo "=== 2. 手动运行 action.sh：这时候才该刷写 ==="
sh "$M/action.sh" > "$SANDBOX/action.log" 2>&1
_rc=$?
[ "$_rc" -eq 0 ] && ok "action.sh 退出码 0" || { bad "action.sh 退出码 $_rc"; tail -n 15 "$SANDBOX/action.log"; }

_now=$(sha256sum "$PART" | cut -d' ' -f1)
[ "$_now" != "$SHA_STOCK" ] && ok "分区已被改写" || bad "手动运行没有改写分区"

SHA_APPLIED="$_now"

for f in last_sha last_head backup part pending; do
	[ -f "$M/state/$f" ] && ok "state/$f 已生成" || bad "缺少 state/$f"
done

# last_head 必须是分区开头 1MB 的哈希
_head_now=$(dd if="$PART" bs=1048576 count=1 2>/dev/null | sha256sum | cut -d' ' -f1)
_head_st=$(cat "$M/state/last_head" 2>/dev/null)
[ "$_head_now" = "$_head_st" ] && ok "state/last_head 与分区开头一致" \
	|| bad "state/last_head 不符（分区 $_head_now / 记录 ${_head_st:-空}）"

echo
echo "=== 3. 刷完再开机：仍然不许自动改动 ==="
sh "$M/post-fs-data.sh" > "$SANDBOX/pfd2.log" 2>&1
_now=$(sha256sum "$PART" | cut -d' ' -f1)
[ "$_now" = "$SHA_APPLIED" ] && ok "分区未被改动" || bad "分区被开机脚本改了"

if grep -q 'dtbo_charge_unlock 开始' "$SANDBOX/pfd2.log" 2>/dev/null; then
	bad "post-fs-data 又跑了刷写流程"
else
	ok "没有执行刷写流程"
fi

echo
echo "=== 4. 重复手动运行：已刷过就跳过，不再多刷一遍 ==="
sh "$M/action.sh" > "$SANDBOX/action2.log" 2>&1
if grep -q '已经是本模块刷入的版本' "$SANDBOX/action2.log" 2>/dev/null; then
	ok "识别为已刷过并跳过"
else
	bad "没有跳过重复刷写"
	tail -n 12 "$SANDBOX/action2.log"
fi
_now=$(sha256sum "$PART" | cut -d' ' -f1)
[ "$_now" = "$SHA_APPLIED" ] && ok "分区内容不变" || bad "重复运行把分区又改了一次"

echo
if [ "$FAILED" -eq 0 ]; then
	echo "=== 「只手动触发」测试通过 ==="
	exit 0
fi
echo "=== 「只手动触发」测试未通过 ==="
exit 1
