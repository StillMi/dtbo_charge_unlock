#!/bin/sh
# 模拟 KernelSU 安装器，完整跑一遍 customize.sh：
# 验证「安装阶段就完成 提取 → 解包 → 改写 → 打包 → 复核 → 刷入」这条主路径。
#
# 用法: sh tools/test_install.sh <模块目录> <假分区镜像> <dtc> <沙盒目录>

MODDIR="$1"
FAKEPART="$2"
DTC_REAL="$3"
SANDBOX="$4"

rm -rf "$SANDBOX"
mkdir -p "$SANDBOX/mod"

# ---- 模拟安装器解压出来的模块目录 ----
cp "$MODDIR/module.prop" "$MODDIR/common.sh" "$MODDIR/config.conf" "$MODDIR/customize.sh" "$SANDBOX/mod/"
cp "$MODDIR/post-fs-data.sh" "$MODDIR/service.sh" "$MODDIR/action.sh" "$SANDBOX/mod/"
cp "$MODDIR/restore.sh" "$MODDIR/dump.sh" "$MODDIR/uninstall.sh" "$SANDBOX/mod/"
cp -r "$MODDIR/ref" "$SANDBOX/mod/"
cp -r "$MODDIR/bin" "$SANDBOX/mod/"

# 自动化测试里不做音量键询问，否则每次都要干等 10 秒（调用方可以显式覆盖）。
# 想测某个档位就设 TEST_TIER=safe|max，会往 config.conf 里写 FORCE_TIER。
export TIER_PROMPT="${TIER_PROMPT:-0}"
if [ -n "${TEST_TIER:-}" ]; then
	printf 'FORCE_TIER=%s\n' "$TEST_TIER" >> "$SANDBOX/mod/config.conf"
fi

# 用主机 dtc 顶替 aarch64 版本
cp "$DTC_REAL" "$SANDBOX/mod/bin/dtc-aarch64"
chmod 755 "$SANDBOX/mod/bin/dtc-aarch64"

# 测试钩子：替换掉所有依赖设备的函数
cat > "$SANDBOX/mod/override.sh" <<EOF
detect_slot() { SLOT="_a"; SLOTNAME="dtbo_a"; log "[test] 模拟槽位 A"; }
resolve_partition() {
	PART="$SANDBOX/partition.img"
	PSIZE=\$(wc -c < "\$PART" | tr -d ' \t\r\n')
	REAL="\$PART"; DEVNAME="partition.img"
	log "[test] 模拟分区 \$PART (\$PSIZE 字节)"
	return 0
}
log_boot_state() { log "[test] 跳过 bootloader 检查"; return 0; }
pick_workdir() { _d="$SANDBOX/work"; rm -rf "\$_d"; mkdir -p "\$_d" || return 1; echo "\$_d"; }
prepare_dtc() { DTC="$DTC_REAL"; log "[test] 使用主机 dtc"; return 0; }
boot_epoch() { echo 1700000000; }
EOF

cp "$FAKEPART" "$SANDBOX/partition.img"
cp "$FAKEPART" "$SANDBOX/original.img"

# ---- 模拟安装器提供的函数与变量 ----
MODPATH="$SANDBOX/mod"
ARCH="arm64"
API=34
INSTALLER_OUT="$SANDBOX/installer.out"
: > "$INSTALLER_OUT"

ui_print() { echo "$*" >> "$INSTALLER_OUT"; }
abort()   { echo "!! ABORT: $*" >> "$INSTALLER_OUT"; echo "!! ABORT: $*" >&2; exit 1; }
set_perm()           { :; }
set_perm_recursive() { :; }

# ---- 执行 customize.sh ----
echo "=== 运行 customize.sh（模拟安装） ==="
. "$SANDBOX/mod/customize.sh"
RC=$?
echo "customize.sh 退出码: $RC"

echo
echo "=== 安装界面输出 ==="
cat "$INSTALLER_OUT"

echo
echo "=== 结果检查 ==="
FAILED=0

# 1) 分区应该被改过
if cmp -s "$SANDBOX/partition.img" "$SANDBOX/original.img"; then
	echo "[FAIL] 安装后分区未被修改"
	FAILED=1
else
	echo "[ OK ] 安装阶段已写入分区"
fi

# 2) 状态文件应齐全
for f in last_sha last_head flash_high backup part orig_sha pending pending_boot; do
	if [ -f "$SANDBOX/mod/state/$f" ]; then
		echo "[ OK ] state/$f = $(cat "$SANDBOX/mod/state/$f")"
	else
		echo "[FAIL] 缺少 state/$f"
		FAILED=1
	fi
done

# 3) 备份必须是原始镜像
BK=$(cat "$SANDBOX/mod/state/backup" 2>/dev/null)
if [ -n "$BK" ] && cmp -s "$BK" "$SANDBOX/original.img"; then
	echo "[ OK ] 备份内容与原始镜像一致"
else
	echo "[FAIL] 备份内容不一致（$BK）"
	FAILED=1
fi

# 4) 安装日志存在
if ls "$SANDBOX/mod/logs"/install-*.log >/dev/null 2>&1; then
	echo "[ OK ] 安装日志已生成: $(ls "$SANDBOX/mod/logs"/install-*.log | head -n1)"
else
	echo "[FAIL] 没有生成安装日志"
	FAILED=1
fi

echo
if [ "$FAILED" -eq 0 ]; then
	echo "=== 安装阶段测试通过 ==="
	exit 0
fi
echo "=== 安装阶段测试未通过 ==="
exit 1
