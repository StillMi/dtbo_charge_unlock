# refine_patchlist.awk —— 在运行时按配置微调 patch.list 中的 FFC 温度窗口
#
# 用法:
#   awk -v low=0 -v high=56 -f refine_patchlist.awk <ref/patch.list> > <work/patch.list>
#
# 只改写三类东西，其它行原样输出：
#   1) ffc_temp_low  -> <low>
#   2) ffc_temp_high -> <high>
#   3) 名字以 jeita_para / temp_para / batt_para 开头的温度分段表里，
#      把作为「高温边界」出现的那个温度值（默认 55）替换成 high。
#      采用「整段精确匹配」，不会误伤 "65535" / "-65535" 之类的数字。
#
# low / high 传空字符串表示不改写。

BEGIN {
	FS = "\t"
	if (high == "") high = "56"
	if (low == "")  low  = "0"
	old_high = oldhigh
	if (old_high == "") old_high = 55
	lohex = sprintf("0x%02x", low + 0)
	hihex = sprintf("0x%02x", high + 0)
}

{
	if ($0 ~ /^[ \t]*#/ || $0 ~ /^[ \t]*$/) { print; next }

	p1 = index($0, "\t")
	if (p1 == 0) { print; next }
	rest = substr($0, p1 + 1)
	p2 = index(rest, "\t")
	if (p2 == 0) { print; next }
	node = substr($0, 1, p1 - 1)
	prop = substr(rest, 1, p2 - 1)
	val  = substr(rest, p2 + 1)
	sub(/\r$/, "", val)

	if (prop == "ffc_temp_low") {
		printf "%s\t%s\t<0x%02x>\n", node, prop, low + 0
		next
	}
	if (prop == "ffc_temp_high") {
		printf "%s\t%s\t<0x%02x>\n", node, prop, high + 0
		next
	}

	if (prop ~ /^(jeita_para|temp_para|batt_para)/) {
		n = split(val, part, ", ")
		out = ""
		for (i = 1; i <= n; i++) {
			seg = part[i]
			q = seg
			gsub(/"/, "", q)
			if (q + 0 == old_high && q ~ /^[0-9]+$/)
				seg = "\"" high "\""
			if (i == 1) out = seg
			else out = out ", " seg
		}
		printf "%s\t%s\t%s\n", node, prop, out
		next
	}

	print
}
