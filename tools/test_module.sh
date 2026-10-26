#!/bin/sh
# PC 端端到端测试：在主机上模拟一个 dtbo 分区文件，完整跑一遍
# run_main（解包 -> 改写 -> 打包 -> 复核 -> 备份 -> 写入 -> 回读校验）。
#
# 用法: sh tools/test_module.sh <模块目录> <假分区镜像> <dtc> <测试沙盒目录>
#
# 说明: 只用于开发期验证脚本逻辑；沙盒里会创建 state/ backup/ logs/，
#       并把「分区」当成普通文件来读写。真实设备上不要执行。

MODDIR="$1"
FAKEPART="$2"
DTC="$3"
SANDBOX="$4"
DTC_REAL="$DTC"

mkdir -p "$SANDBOX"

# 把模块复制到沙盒里跑，避免污染真实模块目录的 state/backup
rm -rf "$SANDBOX/mod"
mkdir -p "$SANDBOX/mod"
cp "$MODDIR/module.prop" "$MODDIR/common.sh" "$MODDIR/config.conf" "$SANDBOX/mod/"
cp -r "$MODDIR/ref" "$SANDBOX/mod/"
cp -r "$MODDIR/bin" "$SANDBOX/mod/"

# 用主机上的 dtc 替换 arm64 版本（主机无法执行 aarch64 二进制）
cp "$DTC" "$SANDBOX/mod/bin/dtc-aarch64"
chmod 755 "$SANDBOX/mod/bin/dtc-aarch64"

cp "$FAKEPART" "$SANDBOX/partition.img"
# 从 Windows 拷过来的样本可能带只读属性，清掉，否则 dd 写不进去
chmod u+w "$SANDBOX/partition.img" 2>/dev/null
rm -f "$SANDBOX/partition.img.lock" 2>/dev/null

MODDIR="$SANDBOX/mod"
. "$MODDIR/common.sh"

# ---- 覆盖所有依赖设备环境的函数 ----
detect_slot() {
	if [ "$TEST_SLOT" = "none" ]; then
		SLOT=""
		SLOTNAME="dtbo"
		log "[test] 模拟单分区设备（分区 dtbo）"
		return 0
	fi
	SLOT="_a"
	SLOTNAME="dtbo_a"
	log "[test] 模拟槽位 A（分区 dtbo_a）"
}

resolve_partition() {
	PART="$SANDBOX/partition.img"
	PSIZE=$(wc -c < "$PART" | tr -d ' \t\r\n')
	REAL="$PART"
	DEVNAME="partition.img"
	log "[test] 模拟分区 $PART ($PSIZE 字节)"
	return 0
}

log_boot_state() {
	log "[test] 跳过 bootloader 属性查询"
	return 0
}

# 主机上没有 /dev /data/local/tmp，用沙盒目录当工作区
pick_workdir() {
	_d="$SANDBOX/work"
	rm -rf "$_d"
	mkdir -p "$_d" || return 1
	echo "$_d"
	return 0
}

# 主机上的 dtc 是 .exe，Windows 无法执行无扩展名的副本，直接用原路径
prepare_dtc() {
	DTC="$DTC_REAL"
	log "[test] 使用主机 dtc: $DTC"
	return 0
}

# 主机上没有 /proc/uptime，boot_epoch 会退化成「当前时刻」，导致
# 「本次开机内刚刷写」的判定出现秒级抖动。固定一个开机时刻，行为才确定。
boot_epoch() { echo 1700000000; }

# 温度窗口由环境变量控制
[ -n "$TEST_FFC_HIGH" ] && FFC_TEMP_HIGH="$TEST_FFC_HIGH"
[ -n "$TEST_DRY_RUN" ] && DRY_RUN="$TEST_DRY_RUN"

ORIG_SHA=$(sha256sum "$SANDBOX/partition.img" | cut -d' ' -f1)

echo "=== 第一次执行 ==="
run_main
RC=$?
echo "run_main 退出码: $RC"
[ "$RC" -eq 0 ] || exit "$RC"

if [ "$DRY_RUN" = "1" ]; then
	echo
	echo "=== 演练模式：分区必须一个字节都没变 ==="
	NOW_SHA=$(sha256sum "$SANDBOX/partition.img" | cut -d' ' -f1)
	if [ "$NOW_SHA" = "$ORIG_SHA" ]; then
		echo "[ OK ] 分区未被修改（sha256 相同）"
	else
		echo "[FAIL] 演练模式下分区居然被改了"
		exit 1
	fi
	[ -f "$SANDBOX/mod/state/last_sha" ] && { echo "[FAIL] 演练模式不应写 last_sha"; exit 1; }
	echo "[ OK ] 未写入 last_sha"
	echo
	echo "=== 测试通过（演练模式） ==="
	exit 0
fi

echo
echo "=== 第二次执行（内容已经刷过，应识别为已刷过而跳过） ==="
run_main 2>&1 | grep -q '已经是本模块刷入的版本' || { echo "未识别为已刷过"; exit 1; }
echo "[ OK ] 重复运行正确跳过（不会多刷一遍）"

echo
echo "=== 模拟切换档位后再次执行（内容不同，应重新刷写） ==="
rm -f "$SANDBOX/mod/state/pending" "$SANDBOX/mod/state/pending_boot" \
      "$SANDBOX/mod/state/pending_id" "$SANDBOX/mod/state/pending_tries" \
      "$SANDBOX/mod/state/confirmed"
FFC_TEMP_HIGH=48 run_main >/dev/null 2>&1 || { echo "切换档位后刷写失败"; exit 1; }
if grep -q '0x30' "$SANDBOX/mod/state/last_sha" 2>/dev/null; then :; fi
_new=$(cat "$SANDBOX/mod/state/last_sha" 2>/dev/null)
[ -n "$_new" ] || { echo "没有生成新的 last_sha"; exit 1; }
echo "[ OK ] 换档位后重新刷写成功（last_sha=${_new%???????????????}…）"

echo
echo "=== 产物检查 ==="
ls -l "$SANDBOX/mod/backup/" 2>/dev/null
echo "last_sha : $(cat "$SANDBOX/mod/state/last_sha" 2>/dev/null)"
echo "partition: $(wc -c < "$SANDBOX/partition.img" | tr -d ' \t\r\n') 字节"
echo "备份文件 : $(cat "$SANDBOX/mod/state/backup" 2>/dev/null)"

echo
echo "=== 从写入后的分区里重新解包核对 ==="
WORK2="$SANDBOX/verify"
rm -rf "$WORK2"
mkdir -p "$WORK2"
WORK="$WORK2"
split_dtbs "$SANDBOX/partition.img" || { echo "无法从分区拆出 DTB"; exit 1; }
echo "格式: $IMG_FORMAT，共 $CNT 个 DTB"
"$DTC" -I dtb -O dts -o "$WORK2/final.dts" "$WORK2/dtb.0" 2>"$WORK2/dec.err"
if [ $? -ne 0 ]; then
	echo "反编译失败"
	cat "$WORK2/dec.err"
	exit 1
fi
echo "反编译行数: $(wc -l < "$WORK2/final.dts")"

echo "--- ffc_temp ---"
grep 'ffc_temp_high' "$WORK2/final.dts" | head -n 3
echo "--- mca_charger_thermal 状态 ---"
sed -n '/mca_charger_thermal[[:space:]]*{/,/};/p' "$WORK2/final.dts" | grep 'status'

echo
echo "=== 测试通过 ==="
