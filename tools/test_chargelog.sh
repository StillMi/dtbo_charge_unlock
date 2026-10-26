#!/system/bin/sh
# ============================================================================
# chargelog.sh 自测：造一棵假的 sysfs + 假模块目录，模拟插拔充电器。
#
# 用法: sh tools/test_chargelog.sh <模块目录> <沙盒目录>
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
LOGDIR="$SB/chargelog"

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

w() {  # w <路径> <内容>
	mkdir -p "${1%/*}" 2>/dev/null
	printf '%s\n' "$2" > "$1"
}

# ------------------------------------------------------------ 假 sysfs ---
PS="$SYS/class/power_supply"
w "$PS/battery/capacity" 73
w "$PS/battery/status" "Discharging"
w "$PS/battery/temp" 352
w "$PS/battery/current_now" 2800000
w "$PS/battery/voltage_now" 4100000
w "$PS/battery/charge_counter" 3150000
w "$PS/battery/power_now" 11480000
w "$PS/usb/online" 0
w "$PS/usb/voltage_now" 9000000
w "$PS/usb/current_max" 3000000
w "$PS/ac/online" 0
w "$PS/wireless/online" 0
w "$PS/dc/online" 0

# 一个电池温度区 + 一个充电器温度区（后者进第 11 列）
w "$SYS/class/thermal/thermal_zone0/type" "battery"
w "$SYS/class/thermal/thermal_zone0/temp" 352
w "$SYS/class/thermal/thermal_zone1/type" "charger_therm0"
w "$SYS/class/thermal/thermal_zone1/temp" 418

# ------------------------------------------------------- 假模块目录 ---
mkdir -p "$MOD/state"
cp "$MODDIR_SRC/chargelog.sh" "$MOD/chargelog.sh" || exit 1
cat > "$MOD/module.prop" <<'EOF'
id=dtbo_charge_unlock
name=测试模块
version=v9.9.9
versionCode=99999
author=Tester
EOF

cat > "$MOD/config.conf" <<EOF
CHARGELOG=1
CHARGELOG_INTERVAL=30
CHARGELOG_MAX=40
CHARGELOG_DIR=$LOGDIR
EOF

run() {  # run <参数...>
	SYSFS_ROOT="$SYS" MODDIR="$MOD" sh "$MOD/chargelog.sh" "$@" 2>"$SB/err.txt"
}

samples() {  # samples <文件>
	grep -vc '^#' "$1" 2>/dev/null | tr -d ' \t\r\n'
}

plug()   { w "$PS/usb/online" 1; w "$PS/battery/status" "Charging"; }
unplug() { w "$PS/usb/online" 0; w "$PS/battery/status" "Discharging"; }

echo "== 没插充电器时不该开新会话 =="
rm -rf "$LOGDIR"
run once
_cnt=$(ls -1 "$LOGDIR"/*.log 2>/dev/null | wc -l | tr -d ' \t\r\n')
[ "$_cnt" = "0" ] && ok "没插电不建日志" || bad "没插电却建了 $_cnt 个日志"
[ -f "$LOGDIR/.current" ] && bad "没插电却写了 .current" || ok "没有 .current"

echo "== 插上充电器：开新会话 =="
plug
run once
_cur=$(cat "$LOGDIR/.current" 2>/dev/null)
[ -n "$_cur" ] && ok "写了 .current（$_cur）" || bad "插电后没有 .current"
F="$LOGDIR/$_cur"
[ -f "$F" ] && ok "会话文件存在" || bad "会话文件不存在: $F"

case "$_cur" in
	[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].log)
		ok "文件名是 YYYYmmdd-HHMMSS.log" ;;
	*) bad "文件名不对: $_cur" ;;
esac

[ "$(head -n 1 "$F")" = "#dtbo-chargelog v2" ] \
	&& ok "首行版本标记 v2" || bad "首行不是 v2 版本标记（$(head -n 1 "$F")）"
[ "$(grep -c '^#start=' "$F")" = "1" ] \
	&& ok "有 #start" || bad "缺 #start"
[ "$(samples "$F")" = "1" ] \
	&& ok "第一次采样 1 行" || bad "第一次采样行数不对（$(samples "$F")）"

echo "== 采样行字段（11 列） =="
_line=$(grep -v '^#' "$F" | head -n 1)
_nf=$(printf '%s' "$_line" | awk -F, '{print NF}')
[ "$_nf" = "11" ] && ok "共 11 列" || bad "列数 $_nf（应为 11）"
[ "$(printf '%s' "$_line" | cut -d, -f2)" = "73" ] \
	&& ok "电量 73" || bad "电量字段 [$(printf '%s' "$_line" | cut -d, -f2)]"
[ "$(printf '%s' "$_line" | cut -d, -f3)" = "352" ] \
	&& ok "温度原值 352" || bad "温度字段 [$(printf '%s' "$_line" | cut -d, -f3)]"
[ "$(printf '%s' "$_line" | cut -d, -f4)" = "2800000" ] \
	&& ok "电流原值" || bad "电流字段 [$(printf '%s' "$_line" | cut -d, -f4)]"
[ "$(printf '%s' "$_line" | cut -d, -f5)" = "4100000" ] \
	&& ok "电压原值" || bad "电压字段 [$(printf '%s' "$_line" | cut -d, -f5)]"
[ "$(printf '%s' "$_line" | cut -d, -f6)" = "3150000" ] \
	&& ok "charge_counter" || bad "计数字段 [$(printf '%s' "$_line" | cut -d, -f6)]"
[ "$(printf '%s' "$_line" | cut -d, -f7)" = "Charging" ] \
	&& ok "状态字段" || bad "状态字段 [$(printf '%s' "$_line" | cut -d, -f7)]"
[ "$(printf '%s' "$_line" | cut -d, -f8)" = "11480000" ] \
	&& ok "power_now 记录下来了" || bad "功率字段 [$(printf '%s' "$_line" | cut -d, -f8)]"
[ "$(printf '%s' "$_line" | cut -d, -f9)" = "9000000" ] \
	&& ok "充电器电压" || bad "usb 电压字段 [$(printf '%s' "$_line" | cut -d, -f9)]"
[ "$(printf '%s' "$_line" | cut -d, -f10)" = "3000000" ] \
	&& ok "充电器限流" || bad "usb 限流字段 [$(printf '%s' "$_line" | cut -d, -f10)]"
[ "$(printf '%s' "$_line" | cut -d, -f11)" = "418" ] \
	&& ok "充电器温度（非电池温度区）" || bad "充电器温度字段 [$(printf '%s' "$_line" | cut -d, -f11)]"
_epoch=$(printf '%s' "$_line" | cut -d, -f1)
case "$_epoch" in
	''|*[!0-9]*) bad "时间戳不是纯数字 [$_epoch]" ;;
	*) [ "$_epoch" -gt 1600000000 ] && ok "时间戳是秒级 epoch" || bad "时间戳太小 [$_epoch]" ;;
esac

echo "== 还在充：追加采样，不换文件 =="
w "$PS/battery/capacity" 74
run once
[ "$(cat "$LOGDIR/.current" 2>/dev/null)" = "$_cur" ] \
	&& ok "会话没变" || bad "会话被换掉了"
[ "$(samples "$F")" = "2" ] && ok "追加到同一个文件（2 行）" || bad "采样行数 [$(samples "$F")]"

echo "== 拔出：收尾 =="
unplug
run once
[ -f "$LOGDIR/.current" ] && bad ".current 没清掉" || ok ".current 已清"
[ "$(grep -c '^#end=' "$F")" = "1" ] && ok "写了 #end" || bad "没写 #end"
run once
[ "$(grep -c '^#end=' "$F")" = "1" ] \
	&& ok "再跑一次不会重复写 #end" || bad "#end 重复了"

echo "== 同一秒内先结束再开新会话：不能覆盖上一个文件 =="
# 插拔很快时会连开两个会话，文件名（秒级时间戳）会撞上。
# 早期版本用 > 写入，直接把上一个会话截断了，页面里那次记录就没了。
_prev="$F"
_prev_lines=$(samples "$_prev")
plug
run once
_new1=$(cat "$LOGDIR/.current" 2>/dev/null)
[ "$_new1" != "$_prev" ] && ok "新会话用了不同文件名（$_new1）" \
	|| bad "新会话把上一个文件覆盖了（$_new1）"
[ "$(samples "$_prev")" = "$_prev_lines" ] \
	&& ok "上一个会话内容没被截断" || bad "上一个会话被截断（$(samples "$_prev") 行）"
# 收尾，回到干净状态
unplug
run once
rm -f "$LOGDIR/.current"

echo "== 电池状态兜底（供电源都没 online） =="
w "$PS/usb/online" 0
w "$PS/battery/status" "Charging"
run once
[ -f "$LOGDIR/.current" ] && ok "status=Charging 也能开始记" || bad "兜底没生效"
rm -f "$LOGDIR/.current"

echo "== 异常结束（掉电/被杀）：补 #aborted =="
w "$PS/battery/status" "Discharging"
_sf="$LOGDIR/20200101-000000.log"
{
	printf '#dtbo-chargelog v1\n'
	printf '#start=1577836800\n'
	printf '1577836830,50,330,2000000,4000000,3000000,Charging\n'
} > "$_sf"
printf '%s\n' "20200101-000000.log" > "$LOGDIR/.current"
# 假装后台进程已经在跑（用测试脚本自己的 pid），这样 start 只做补标记不会真起循环
printf '%s\n' "$$" > "$LOGDIR/.pid"
run start
[ "$(grep -c '^#aborted=1' "$_sf")" = "1" ] \
	&& ok "残缺会话被标成 #aborted" || bad "没补 #aborted"
[ -f "$LOGDIR/.current" ] && bad ".current 没清掉" || ok ".current 已清"
[ -f "$_sf" ] && ok "残缺会话没被删掉" || bad "残缺会话被删了"

echo "== 已经在跑就不重复启动 =="
run start
rc=$?
[ "$rc" = "0" ] && ok "重复 start 退出码 0" || bad "重复 start 退出码 $rc"
rm -f "$LOGDIR/.pid"

echo "== CHARGELOG=0 总开关 =="
sed 's/^CHARGELOG=1/CHARGELOG=0/' "$MOD/config.conf" > "$MOD/config.tmp"
mv "$MOD/config.tmp" "$MOD/config.conf"
run start
[ -f "$LOGDIR/.pid" ] && bad "关掉总开关还启动了" || ok "总开关关闭时不启动"
cat > "$MOD/config.conf" <<EOF
CHARGELOG=1
CHARGELOG_INTERVAL=30
CHARGELOG_MAX=40
CHARGELOG_DIR=$LOGDIR
EOF

echo "== monitor.sh --logs =="
unplug
w "$PS/battery/status" "Discharging"
OUT="$SB/logs.txt"
CHARGELOG_DIR="$LOGDIR" MODDIR="$MOD" sh "$MODDIR_SRC/monitor.sh" --logs > "$OUT" 2>&1
_n=$(grep '^log.list_count=' "$OUT" | cut -d= -f2-)
[ -n "$_n" ] && [ "$_n" -ge 2 ] && ok "列出 $_n 个会话" || bad "会话数量不对 [$_n]"
[ "$(grep -c '^log\.0\.name=' "$OUT")" = "1" ] \
	&& ok "有 log.0.name" || bad "缺 log.0.name"
if grep -q "^log\.[0-9]*\.name=$_cur\$" "$OUT"; then
	ok "刚记的那个会话在列表里"
else
	bad "列表里找不到 $_cur"
fi
_nm=$(sed -n "s/^log\.\([0-9]*\)\.name=$_cur\$/\1/p" "$OUT" | head -n 1)
[ -n "$_nm" ] || _nm=0
_v=$(grep "^log\.$_nm\.samples=" "$OUT" | cut -d= -f2-)
[ "$_v" = "$(samples "$F")" ] && ok "samples 统计正确" || bad "samples [$_v] 应为 $(samples "$F")"
_v=$(grep "^log\.$_nm\.aborted=" "$OUT" | cut -d= -f2-)
[ "$_v" = "0" ] && ok "正常会话 aborted=0" || bad "aborted [$_v]"
_v=$(grep "^log\.$_nm\.temp_max=" "$OUT" | cut -d= -f2-)
[ "$_v" = "352" ] && ok "temp_max 352" || bad "temp_max [$_v]"
# power_now 是 11480000 uW = 11480 mW
_v=$(grep "^log\.$_nm\.pmax_mw=" "$OUT" | cut -d= -f2-)
[ "$_v" = "11480" ] && ok "pmax_mw 11480（由 power_now 换算）" || bad "pmax_mw [$_v]"
_v=$(grep "^log\.$_nm\.cur_max=" "$OUT" | cut -d= -f2-)
[ "$_v" = "2800000" ] && ok "cur_max 取到最大值" || bad "cur_max [$_v]"
_v=$(grep "^log\.$_nm\.volt_max=" "$OUT" | cut -d= -f2-)
[ "$_v" = "4100000" ] && ok "volt_max 取到最大值" || bad "volt_max [$_v]"
_v=$(grep "^log\.$_nm\.cnt0=" "$OUT" | cut -d= -f2-)
[ "$_v" = "3150000" ] && ok "cnt0 是首点计数" || bad "cnt0 [$_v]"

echo "== monitor.sh --log <会话> =="
OUT2="$SB/session.txt"
CHARGELOG_DIR="$LOGDIR" MODDIR="$MOD" sh "$MODDIR_SRC/monitor.sh" --log "$_cur" > "$OUT2" 2>&1
[ "$(grep '^session.name=' "$OUT2" | cut -d= -f2-)" = "$_cur" ] \
	&& ok "session.name" || bad "session.name 不对"
[ "$(grep '^session.count=' "$OUT2" | cut -d= -f2-)" = "$(samples "$F")" ] \
	&& ok "session.count 与文件一致" || bad "session.count [$(grep '^session.count=' "$OUT2" | cut -d= -f2-)]"
grep -q '^session\.s\.0=[0-9]*,73,' "$OUT2" \
	&& ok "第一个采样点原样带出" || bad "采样点内容不对"

echo "== --log 名字校验 =="
CHARGELOG_DIR="$LOGDIR" MODDIR="$MOD" sh "$MODDIR_SRC/monitor.sh" --log ../../etc/passwd > "$SB/bad1.txt" 2>&1
[ "$?" = "1" ] && ok "拒绝 .. 穿越" || bad "没拦住 ../ 穿越"
CHARGELOG_DIR="$LOGDIR" MODDIR="$MOD" sh "$MODDIR_SRC/monitor.sh" --log nosuch.log > "$SB/bad2.txt" 2>&1
[ "$?" = "1" ] && ok "不存在的会话返回 1" || bad "不存在的会话没报错"

echo "== 超出 CHARGELOG_MAX 时淘汰最旧的 =="
sed 's/^CHARGELOG_MAX=40/CHARGELOG_MAX=3/' "$MOD/config.conf" > "$MOD/config.tmp"
mv "$MOD/config.tmp" "$MOD/config.conf"
# 前面几个用例留下的会话数量不确定，这里清空目录，只放本用例自己的文件，
# 断言才有确定含义。
rm -rf "$LOGDIR"
mkdir -p "$LOGDIR"
_i=0
while [ "$_i" -lt 5 ]; do
	_f="$LOGDIR/20210101-00000$_i.log"
	{
		printf '#dtbo-chargelog v1\n'
		printf '#start=1609459200\n'
		printf '#end=1609462800\n'
		printf '1609459230,40,300,1000000,4000000,1,Charging\n'
	} > "$_f"
	touch -t "20210101000$_i" "$_f"
	_i=$((_i + 1))
done
plug
run once
_cnt=$(ls -1 "$LOGDIR"/*.log 2>/dev/null | wc -l | tr -d ' \t\r\n')
[ "$_cnt" = "3" ] && ok "只留 3 个（5 个旧的 + 1 个新的 → 3）" \
	|| bad "留下了 $_cnt 个（上限 3）"
_new=$(cat "$LOGDIR/.current" 2>/dev/null)
[ -f "$LOGDIR/$_new" ] && ok "新会话没被自己删掉" || bad "新会话被淘汰了"
# 被淘汰的应该是最旧的几个
if [ -f "$LOGDIR/20210101-000000.log" ]; then
	bad "最旧的会话没被淘汰"
else
	ok "最旧的会话已被淘汰"
fi

echo "== .pid 里的号码被别人复用了：必须重新拉起 =="
# 场景：进程被 SIGKILL 或掉电杀掉时 trap 来不及跑，.pid 留在原地，
# 而那个 PID 可能已经被系统分配给了别的进程 —— kill -0 照样成功。
# 以前 start 会直接 exit 0（永远不再启动），页面就一直显示「记录中」，
# 实际一个采样点都没写。现在要核对 /proc/<pid>/cmdline。
rm -rf "$LOGDIR"
mkdir -p "$LOGDIR" "$SB/proc"
sleep 60 &
_other=$!
mkdir -p "$SB/proc/$_other"
printf 'sleep\00060\000' > "$SB/proc/$_other/cmdline"
printf '%s\n' "$_other" > "$LOGDIR/.pid"
PROC_ROOT="$SB/proc" SYSFS_ROOT="$SYS" MODDIR="$MOD" \
	sh "$MODDIR_SRC/monitor.sh" --logs > "$SB/reuse.txt" 2>&1
_v=$(grep '^log_running=' "$SB/reuse.txt" | cut -d= -f2-)
[ "$_v" = "0" ] && ok "号码被复用时不认成在跑" || bad "log_running [$_v] 应为 0"
PROC_ROOT="$SB/proc" SYSFS_ROOT="$SYS" MODDIR="$MOD" sh "$MOD/chargelog.sh" start >/dev/null 2>&1
sleep 1
_newpid=$(cat "$LOGDIR/.pid" 2>/dev/null)
[ -n "$_newpid" ] && [ "$_newpid" != "$_other" ] \
	&& ok "start 换掉了被复用的号码（$_newpid）" || bad "start 没有重新拉起 [$_newpid]"
kill "$_newpid" 2>/dev/null
kill "$_other" 2>/dev/null

echo "== 心跳过期（进程还活着但卡住）：start 要杀掉重来 =="
rm -rf "$LOGDIR"
mkdir -p "$LOGDIR" "$SB/proc"
sleep 60 &
_stuck=$!
mkdir -p "$SB/proc/$_stuck"
printf 'sh\000/data/adb/modules/dtbo_charge_unlock/chargelog.sh\000loop\000' > "$SB/proc/$_stuck/cmdline"
printf '%s\n' "$_stuck" > "$LOGDIR/.pid"
printf '%s\n' "$(( $(date +%s) - 600 ))" > "$LOGDIR/.beat"
PROC_ROOT="$SB/proc" SYSFS_ROOT="$SYS" MODDIR="$MOD" \
	sh "$MODDIR_SRC/monitor.sh" --logs > "$SB/stuck.txt" 2>&1
_v=$(grep '^log_running=' "$SB/stuck.txt" | cut -d= -f2-)
[ "$_v" = "0" ] && ok "心跳过期时不认成在跑" || bad "log_running [$_v] 应为 0"
_v=$(grep '^log_beat=' "$SB/stuck.txt" | cut -d= -f2-)
[ "$_v" -ge 590 ] 2>/dev/null && ok "log_beat 报出了过期秒数 [$_v]" || bad "log_beat [$_v]"
PROC_ROOT="$SB/proc" SYSFS_ROOT="$SYS" MODDIR="$MOD" sh "$MOD/chargelog.sh" start >/dev/null 2>&1
sleep 1
_newpid=$(cat "$LOGDIR/.pid" 2>/dev/null)
[ -n "$_newpid" ] && [ "$_newpid" != "$_stuck" ] \
	&& ok "卡住的进程被换掉（$_newpid）" || bad "卡住的进程没被换掉 [$_newpid]"
kill "$_newpid" 2>/dev/null
kill "$_stuck" 2>/dev/null

echo "== 心跳新鲜时不要重复启动 =="
rm -rf "$LOGDIR"
mkdir -p "$LOGDIR" "$SB/proc"
sleep 60 &
_live=$!
mkdir -p "$SB/proc/$_live"
printf 'sh\000/data/adb/modules/dtbo_charge_unlock/chargelog.sh\000loop\000' > "$SB/proc/$_live/cmdline"
printf '%s\n' "$_live" > "$LOGDIR/.pid"
printf '%s\n' "$(date +%s)" > "$LOGDIR/.beat"
PROC_ROOT="$SB/proc" SYSFS_ROOT="$SYS" MODDIR="$MOD" \
	sh "$MODDIR_SRC/monitor.sh" --logs > "$SB/live.txt" 2>&1
_v=$(grep '^log_running=' "$SB/live.txt" | cut -d= -f2-)
[ "$_v" = "1" ] && ok "心跳新鲜时算在跑" || bad "log_running [$_v] 应为 1"
PROC_ROOT="$SB/proc" SYSFS_ROOT="$SYS" MODDIR="$MOD" sh "$MOD/chargelog.sh" start >/dev/null 2>&1
_after=$(cat "$LOGDIR/.pid" 2>/dev/null)
[ "$_after" = "$_live" ] && ok "没有重复启动" || bad "重复启动了 [$_after]"
kill "$_live" 2>/dev/null

echo "== 没有 awk 也能列出会话（纯 shell 兜底） =="
rm -rf "$LOGDIR"
mkdir -p "$LOGDIR"
cat > "$LOGDIR/20251001-100000.log" <<'EOF'
#dtbo-chargelog v2
#start=1759284000
1759284010,40,320,2000000,4000000,1000,Charging,8000000,9000000,3000000,330
1759284020,42,322,1900000,4100000,1200,Charging,7790000,9000000,3000000,331
#end=1759284030
EOF
CHARGELOG_DIR="$LOGDIR" MODDIR="$MOD" sh "$MODDIR_SRC/monitor.sh" --logs > "$SB/awk_ok.txt" 2>&1
MONITOR_NO_AWK=1 CHARGELOG_DIR="$LOGDIR" MODDIR="$MOD" \
	sh "$MODDIR_SRC/monitor.sh" --logs > "$SB/awk_no.txt" 2>&1
_n=$(grep '^log.list_count=' "$SB/awk_no.txt" | cut -d= -f2-)
[ "$_n" = "1" ] && ok "兜底也列出 1 个会话" || bad "兜底 list_count [$_n] 应为 1"
_v=$(grep '^log.0.pmax_mw=' "$SB/awk_no.txt" | cut -d= -f2-)
[ "$_v" = "8000" ] && ok "兜底 pmax_mw 8000" || bad "兜底 pmax_mw [$_v]"
_v=$(grep '^log.0.samples=' "$SB/awk_no.txt" | cut -d= -f2-)
[ "$_v" = "2" ] && ok "兜底 samples 2" || bad "兜底 samples [$_v]"
# 两种实现的结果必须一模一样（除 log_err）
grep -v '^log_err=' "$SB/awk_ok.txt" > "$SB/a1.txt"
grep -v '^log_err=' "$SB/awk_no.txt" > "$SB/a2.txt"
if cmp -s "$SB/a1.txt" "$SB/a2.txt"; then
	ok "兜底结果与 awk 逐行一致"
else
	bad "兜底结果与 awk 不一致"
fi

echo ""
if [ "$fail" -eq 0 ]; then
	echo "=== chargelog.sh 自测通过 ==="
	exit 0
fi
echo "=== chargelog.sh 自测失败：$fail 项 ==="
exit 1
