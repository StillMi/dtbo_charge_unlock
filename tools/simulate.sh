#!/bin/sh
# PC 端仿真：只跑「解包 -> 改写 -> 打包 -> 复核」这一段，
# 用真实 dtc + 真实 awk 验证模块内脚本的调用方式是否正确。
# 在设备上不执行；仅用于开发期自测。

set -e

MODDIR="$1"
SRC="$2"          # 输入 dtb（模拟「从 dtbo 分区读出来的镜像」）
DTC="$3"          # dtc 可执行文件
WORK="$4"

BINDIR="$MODDIR/bin"
REF="$MODDIR/ref"

mkdir -p "$WORK"

# 生成运行时 patch.list（等价于 common.sh 里的逻辑）
if [ -n "$FFC_TEMP_HIGH" ]; then
	awk -v low="$FFC_TEMP_LOW" -v high="$FFC_TEMP_HIGH" -v oldhigh="$FFC_REF_HIGH" \
		-f "$BINDIR/refine_patchlist.awk" "$REF/patch.list" > "$WORK/patch.list"
else
	cp "$REF/patch.list" "$WORK/patch.list"
fi
echo "[sim] patch.list 行数: $(wc -l < "$WORK/patch.list")"

# 1) 反编译
"$DTC" -I dtb -O dts -o "$WORK/0.dts" "$SRC" 2>"$WORK/0.dec.err"
echo "[sim] 反编译: $(wc -l < "$WORK/0.dts") 行"

# 2) 改写
awk -v plist="$WORK/patch.list" -f "$BINDIR/patch_dts.awk" "$WORK/0.dts" > "$WORK/0.patched.dts"
echo "[sim] 改写: $(wc -l < "$WORK/0.patched.dts") 行"

# 3) 打包
"$DTC" -@ -I dts -O dtb -o "$WORK/0.new" "$WORK/0.patched.dts" 2>"$WORK/0.comp.err"
echo "[sim] 打包: $(wc -c < "$WORK/0.new") 字节"

# 4) 复核一：能反编译
"$DTC" -I dtb -O dts -o "$WORK/0.check.dts" "$WORK/0.new" 2>"$WORK/0.chk.err"
echo "[sim] 复核反编译 OK: $(wc -l < "$WORK/0.check.dts") 行"

# 5) 复核二：参数一致
awk -v plist="$WORK/patch.list" -f "$BINDIR/check_dts.awk" "$WORK/0.check.dts"
echo "[sim] 复核参数 OK"

# 6) 关键节点确认
echo "[sim] mca_charger_thermal 状态:"
grep -A3 'mca_charger_thermal {' "$WORK/0.check.dts" | head -n 6
echo "[sim] ffc 温度:"
grep -E 'ffc_temp_(low|high)' "$WORK/0.check.dts" | head -n 4
echo "[sim] 完成"
