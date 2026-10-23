#!/bin/sh
# 主机端测试：只测「分区镜像 -> 拆分 -> 反编译 -> 改写 -> 打包 -> 拼装」这一段，
# 用真实的 dtc + awk 跑一遍模块里 common.sh 的 split_dtbs / pack_image。
#
# 用法: sh tools/test_pipeline.sh <模块目录> <假分区镜像> <dtc> <工作目录>
# 假分区镜像应是一个「开头是 DTB、尾部补零」的文件，模拟设备上的 dtbo 分区。

set -e

MODDIR="$1"
IMG="$2"
DTC="$3"
WORK="$4"

PSIZE=$(wc -c < "$IMG" | tr -d ' \t\r\n')
mkdir -p "$WORK"

MODDIR_ABS="$MODDIR"
# 只借用函数定义，不触发任何设备操作
. "$MODDIR/common.sh"

log() { echo "[test] $*" >&2; }
die() { echo "[test][FATAL] $*" >&2; return 1; }

WORK="$WORK"
mkdir -p "$WORK"

echo "[test] 分区镜像 $IMG ($PSIZE 字节)"

CNT=$(split_dtbs "$IMG")
echo "[test] 拆分出 $CNT 个 DTB"

[ "$CNT" -ge 1 ] || { echo "[test] 失败：一个 DTB 都没找到" >&2; exit 1; }

PLIST="$WORK/patch.list"
if [ -n "$FFC_TEMP_HIGH" ]; then
	awk -v low="$FFC_TEMP_LOW" -v high="$FFC_TEMP_HIGH" -v oldhigh="$FFC_REF_HIGH" \
		-f "$MODDIR/bin/refine_patchlist.awk" "$MODDIR/ref/patch.list" > "$PLIST"
else
	cp "$MODDIR/ref/patch.list" "$PLIST"
fi

_i=0
_outs=""
while [ "$_i" -lt "$CNT" ]; do
	"$DTC" -I dtb -O dts -o "$WORK/$_i.dts" "$WORK/dtb.$_i" 2>"$WORK/$_i.dec.err"
	awk -v plist="$PLIST" -f "$MODDIR/bin/patch_dts.awk" "$WORK/$_i.dts" > "$WORK/$_i.patched.dts"
	"$DTC" -@ -I dts -O dtb -o "$WORK/$_i.new" "$WORK/$_i.patched.dts" 2>"$WORK/$_i.comp.err"
	"$DTC" -I dtb -O dts -o "$WORK/$_i.check.dts" "$WORK/$_i.new" 2>"$WORK/$_i.chk.err"
	awk -v plist="$PLIST" -f "$MODDIR/bin/check_dts.awk" "$WORK/$_i.check.dts"
	echo "[test] DTB #$_i: $(wc -c < "$WORK/$_i.new") 字节，复核通过"
	_outs="$_outs $WORK/$_i.new"
	_i=$((_i + 1))
done

pack_image "$WORK/new.img" $_outs
SZ=$(wc -c < "$WORK/new.img" | tr -d ' \t\r\n')
echo "[test] 拼装结果 $SZ 字节（期望 $PSIZE）"
[ "$SZ" = "$PSIZE" ] || { echo "[test] 失败：大小不符" >&2; exit 1; }

# 再拆一次，确认拼出来的镜像仍然可拆可解
CNT2=$(split_dtbs "$WORK/new.img")
echo "[test] 重新拆分出 $CNT2 个 DTB"
[ "$CNT2" = "$CNT" ] || { echo "[test] 失败：重新拆分数量不一致" >&2; exit 1; }

"$DTC" -I dtb -O dts -o "$WORK/recheck.dts" "$WORK/dtb.0" 2>/dev/null
awk -v plist="$PLIST" -f "$MODDIR/bin/check_dts.awk" "$WORK/recheck.dts"
echo "[test] 重新拆出的镜像参数复核通过"

echo "[test] 全部通过"
