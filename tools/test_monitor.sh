#!/system/bin/sh
# ============================================================================
# monitor.sh 自测：造一棵假的 sysfs + 模块目录，检查输出字段。
#
# 用法: sh tools/test_monitor.sh <模块目录> <沙盒目录>
# ============================================================================
set -u

MODDIR_SRC="$1"
SB="$2"

[ -n "$MODDIR_SRC" ] && [ -n "$SB" ] || {
	echo "用法: sh $0 <模块目录> <沙盒目录>"
	exit 2
}

rm -rf "$SB"
mkdir -p "$SB" || exit 1

SYS="$SB/sys"
MOD="$SB/mod"

fail=0
ok()   { echo "  ok   $1"; }
bad()  { echo "  FAIL $1"; fail=$((fail + 1)); }

# 断言输出里有 key=value
expect() {  # expect <输出文件> <键> <期望值>
	_v=$(grep "^$2=" "$1" 2>/dev/null | head -n 1 | cut -d= -f2-)
	if [ "$_v" = "$3" ]; then
		ok "$2 = $3"
	else
		bad "$2 期望 [$3]，实际 [$_v]"
	fi
}

w() {  # w <路径> <内容>
	mkdir -p "${1%/*}" 2>/dev/null
	printf '%s\n' "$2" > "$1"
}

# ------------------------------------------------------------ 假 sysfs ---
PS="$SYS/class/power_supply"
w "$PS/battery/capacity" 73
w "$PS/battery/status" "Charging"
w "$PS/battery/present" 1
w "$PS/battery/health" "Good"
w "$PS/battery/technology" "Li-ion"
w "$PS/battery/temp" 352
w "$PS/battery/current_now" 2800000
w "$PS/battery/voltage_now" 4100000
w "$PS/battery/charge_counter" 3150000
w "$PS/battery/cycle_count" 142
w "$PS/battery/constant_charge_current_max" 6000000
w "$PS/battery/input_current_limit" 3000000

w "$PS/usb/online" 1
w "$PS/usb/type" "USB_PD"
w "$PS/usb/voltage_now" 9000000
w "$PS/usb/current_max" 3000000
w "$PS/usb/voltage_max" 9000000
w "$PS/usb/real_type" "USB_PD"
w "$PS/usb/pd_active" 1

w "$PS/ac/online" 0
w "$PS/wireless/online" 0

w "$SYS/class/thermal/thermal_zone0/type" "battery"
w "$SYS/class/thermal/thermal_zone0/temp" 352
w "$SYS/class/thermal/thermal_zone1/type" "charger_therm0"
w "$SYS/class/thermal/thermal_zone1/temp" 418
w "$SYS/class/thermal/thermal_zone2/type" "cpu-0-0"      # 应被过滤
w "$SYS/class/thermal/thermal_zone2/temp" 999
w "$SYS/class/thermal/thermal_zone3/type" "pm8550_tz"
w "$SYS/class/thermal/thermal_zone3/temp" 38000        # 毫度，异常单位

# ------------------------------------------------------- 假模块目录 ---
mkdir -p "$MOD/state" "$MOD/backup"

cat > "$MOD/module.prop" <<'EOF'
id=dtbo_charge_unlock
name=测试模块
version=v9.9.9
versionCode=99999
author=Tester
EOF

cat > "$MOD/config.conf" <<'EOF'
# 注释
FFC_TEMP_LOW=0
FFC_TEMP_HIGH=56
FFC_REF_HIGH=55
DRY_RUN=0
EOF

printf '%s\n' "abc123def456" > "$MOD/state/last_sha"
printf '%s\n' "000111222333" > "$MOD/state/orig_sha"
printf '%s\n' "/dev/block/sde18" > "$MOD/state/part"
printf '%s\n' "$MOD/backup/dtbo_a_x.img" > "$MOD/state/pending"
printf '%s\n' "tok-99" > "$MOD/state/pending_id"
printf '%s\n' "1" > "$MOD/state/pending_tries"
printf '%s\n' "0" > "$MOD/state/confirmed"
# 注意：state/halted 是「文件存在即停用」，不是看内容，这里先不建

# 两份备份，时间上后一份更新
dd if=/dev/zero of="$MOD/backup/dtbo_a_old.img" bs=1024 count=4 2>/dev/null
sleep 1
dd if=/dev/zero of="$MOD/backup/dtbo_a_new.img" bs=1024 count=8 2>/dev/null
touch -t 202001010000 "$MOD/backup/dtbo_a_old.img"

OUT="$SB/out.txt"
SYSFS_ROOT="$SYS" MODDIR="$MOD" sh "$MODDIR_SRC/monitor.sh" > "$OUT" 2>"$SB/err.txt"
rc=$?

echo "== 基本 =="
[ "$rc" = "0" ] && ok "退出码 0" || bad "退出码 $rc"
[ -s "$OUT" ] && ok "有输出（$(wc -l < "$OUT" | tr -d ' ') 行）" || bad "输出为空"
[ -s "$SB/err.txt" ] && { echo "  stderr:"; sed 's/^/    /' "$SB/err.txt"; }

echo "== 电池 =="
expect "$OUT" capacity 73
expect "$OUT" status "Charging"
expect "$OUT" temp_raw 352
expect "$OUT" current_now 2800000
expect "$OUT" voltage_now 4100000
expect "$OUT" cycle_count 142
expect "$OUT" health "Good"
expect "$OUT" batt_dir "$PS/battery"

echo "== 电源 =="
expect "$OUT" src.usb.online 1
expect "$OUT" src.usb.type "USB_PD"
expect "$OUT" src.ac.online 0
expect "$OUT" src.wireless.online 0

echo "== 温度区 =="
expect "$OUT" thermal.count 3
expect "$OUT" thermal.0 "battery|352"
expect "$OUT" thermal.1 "charger_therm0|418"
expect "$OUT" thermal.2 "pm8550_tz|38000"
# 第一个非电池温度区（充电器/主板），页面用它显示充电器温度
expect "$OUT" chg_temp_raw 418

echo "== 模块状态 =="
expect "$OUT" module_version "v9.9.9"
expect "$OUT" module_author "Tester"
expect "$OUT" state_last_sha "abc123def456"
expect "$OUT" state_boot_time ""
expect "$OUT" backup_file "$MOD/backup/dtbo_a_new.img"
expect "$OUT" backup_size 8192
expect "$OUT" backup_count 2
expect "$OUT" cfg_ffc_low 0
expect "$OUT" cfg_ffc_high 56
expect "$OUT" cfg_dry_run 0
expect "$OUT" cfg_tier max

# 开机确认已删除：不该再输出这些字段
for gone in state_pending state_pending_id state_pending_tries state_confirmed state_halted; do
	if grep -q "^$gone=" "$OUT" 2>/dev/null; then
		bad "不该再输出 $gone（开机确认已删除）"
	else
		ok "不再输出 $gone"
	fi
done

# service.sh 会写 state/boot_time，页面按需读取
printf '%s\n' "1792927782" > "$MOD/state/boot_time"
SYSFS_ROOT="$SYS" MODDIR="$MOD" sh "$MODDIR_SRC/monitor.sh" > "$SB/out_bt.txt" 2>&1
expect "$SB/out_bt.txt" state_boot_time 1792927782

echo "== 充电日志字段 =="
expect "$OUT" log_dir "/data/adb/dtbo_charge_unlock/chargelog"
expect "$OUT" log_interval 10
expect "$OUT" log_count 0
expect "$OUT" log_running 0
expect "$OUT" log_current ""
# 页面靠这一项区分「在等充电器」和「插上了还没采到点」
expect "$OUT" log_plugged 1

# 拔掉所有供电源、电池也不是 Charging/Full 时，必须报 0
w "$PS/usb/online" 0
w "$PS/battery/status" "Discharging"
SYSFS_ROOT="$SYS" MODDIR="$MOD" sh "$MODDIR_SRC/monitor.sh" > "$SB/out_np.txt" 2>&1
expect "$SB/out_np.txt" log_plugged 0

echo "== Scene 温控档位 =="
# 没有 Scene 模块时，档位是空的，但不能报错、也不能瞎猜
expect "$OUT" scene_thermal ""
expect "$OUT" scene_file ""

# 造一个假的 Scene 模块目录：新版用 thermal.current.ini
MR="$SB/modroot"
SC="$MR/modules/scene_test/system/vendor/etc"
mkdir -p "$SC"
printf 'danger\n' > "$SC/thermal.current.ini"
MODULES_ROOT="$MR" SYSFS_ROOT="$SYS" MODDIR="$MOD" sh "$MODDIR_SRC/monitor.sh" > "$SB/out_sc.txt" 2>&1
expect "$SB/out_sc.txt" scene_thermal danger
expect "$SB/out_sc.txt" scene_file "$SC/thermal.current.ini"

# 档位文件里有空白/回车也要清干净
printf '  pro \r\n' > "$SC/thermal.current.ini"
MODULES_ROOT="$MR" SYSFS_ROOT="$SYS" MODDIR="$MOD" sh "$MODDIR_SRC/monitor.sh" > "$SB/out_sc2.txt" 2>&1
expect "$SB/out_sc2.txt" scene_thermal pro

# 旧版 Scene 用的是 thermal-engine.current.ini，也得认
rm -f "$SC/thermal.current.ini"
printf 'extreme\n' > "$SC/thermal-engine.current.ini"
MODULES_ROOT="$MR" SYSFS_ROOT="$SYS" MODDIR="$MOD" sh "$MODDIR_SRC/monitor.sh" > "$SB/out_sc3.txt" 2>&1
expect "$SB/out_sc3.txt" scene_thermal extreme

# 两个文件都在时，新的 thermal.current.ini 优先
printf 'cool\n' > "$SC/thermal.current.ini"
MODULES_ROOT="$MR" SYSFS_ROOT="$SYS" MODDIR="$MOD" sh "$MODDIR_SRC/monitor.sh" > "$SB/out_sc4.txt" 2>&1
expect "$SB/out_sc4.txt" scene_thermal cool

# 目录名不含 scene/vtools 的模块不该被误读
mkdir -p "$MR/modules/other_mod/system/vendor/etc"
printf 'danger\n' > "$MR/modules/other_mod/system/vendor/etc/thermal.current.ini"
rm -rf "$MR/modules/scene_test"
MODULES_ROOT="$MR" SYSFS_ROOT="$SYS" MODDIR="$MOD" sh "$MODDIR_SRC/monitor.sh" > "$SB/out_sc5.txt" 2>&1
expect "$SB/out_sc5.txt" scene_thermal ""

# 系统温控引擎：PC 上没有这些可执行文件，应当是 0
expect "$OUT" thermal_engine 0
rm -rf "$MR"
w "$PS/usb/online" 1
w "$PS/battery/status" "Charging"

echo "== --full：分区头部比对（判断是否需重新应用） =="
PRT="$SB/fake_part.img"
dd if=/dev/zero of="$PRT" bs=1024 count=64 2>/dev/null
printf 'DTBOHEAD' | dd of="$PRT" bs=1 seek=0 conv=notrunc 2>/dev/null
printf '%s\n' "$PRT" > "$MOD/state/part"
_head=$(dd if="$PRT" bs=1048576 count=1 2>/dev/null | sha256sum | cut -d' ' -f1)
printf '%s\n' "$_head" > "$MOD/state/last_head"

SYSFS_ROOT="$SYS" MODDIR="$MOD" sh "$MODDIR_SRC/monitor.sh" --full > "$SB/out4.txt" 2>&1
expect "$SB/out4.txt" state_last_head "$_head"
expect "$SB/out4.txt" state_cur_head "$_head"

# 不带 --full 时不该去读分区（轮询每 2 秒一次，不能反复读盘）
SYSFS_ROOT="$SYS" MODDIR="$MOD" sh "$MODDIR_SRC/monitor.sh" > "$SB/out5.txt" 2>&1
if grep -q '^state_cur_head=' "$SB/out5.txt" 2>/dev/null; then
	bad "不带 --full 时也读了分区"
else
	ok "不带 --full 时跳过分区读取"
fi

# 分区被换掉（模拟系统 OTA）→ 哈希不再一致
printf 'STOCK!!!' | dd of="$PRT" bs=1 seek=0 conv=notrunc 2>/dev/null
SYSFS_ROOT="$SYS" MODDIR="$MOD" sh "$MODDIR_SRC/monitor.sh" --full > "$SB/out6.txt" 2>&1
_cur=$(grep '^state_cur_head=' "$SB/out6.txt" 2>/dev/null | cut -d= -f2-)
if [ -n "$_cur" ] && [ "$_cur" != "$_head" ]; then
	ok "分区被覆盖后 state_cur_head 变化"
else
	bad "分区覆盖后哈希没变（$_cur）"
fi

echo "== 没有电池节点时也要能跑 =="
mv "$PS/battery" "$PS/battery.off"
SYSFS_ROOT="$SYS" MODDIR="$MOD" sh "$MODDIR_SRC/monitor.sh" > "$SB/out2.txt" 2>&1
rc2=$?
[ "$rc2" = "0" ] && ok "退出码 0" || bad "退出码 $rc2"
expect "$SB/out2.txt" batt_dir ""
expect "$SB/out2.txt" capacity ""
expect "$SB/out2.txt" module_version "v9.9.9"
mv "$PS/battery.off" "$PS/battery"

echo "== 残留的旧状态文件不影响输出 =="
# 旧版本会写 halted / pending，现在既不该输出也不该影响任何判断
printf '%s\n' "rolled-back 2026-01-01 00:00:00" > "$MOD/state/halted"
printf '%s\n' "/some/backup.img" > "$MOD/state/pending"
SYSFS_ROOT="$SYS" MODDIR="$MOD" sh "$MODDIR_SRC/monitor.sh" --full > "$SB/out3.txt" 2>&1
rc3=$?
[ "$rc3" = "0" ] && ok "有残留文件也能正常跑" || bad "退出码 $rc3"
# 上面最后一个用例把分区改成了原厂内容，这里按当前状态重新算期望值
_cur_now=$(dd if="$PRT" bs=1048576 count=1 2>/dev/null | sha256sum | cut -d' ' -f1)
expect "$SB/out3.txt" state_cur_head "$_cur_now"
if grep -q '^state_halted=' "$SB/out3.txt" 2>/dev/null; then
	bad "不该再输出 state_halted"
else
	ok "残留 halted 不再出现在输出里"
fi
rm -f "$MOD/state/halted" "$MOD/state/pending"

echo ""
if [ "$fail" -eq 0 ]; then
	echo "=== monitor.sh 自测通过 ==="
	exit 0
fi
echo "=== monitor.sh 自测失败：$fail 项 ==="
exit 1
