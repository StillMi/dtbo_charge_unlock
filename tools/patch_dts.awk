# patch_dts.awk —— 按「节点名 + 属性名」精确改写 dts 中的属性值
#
# 用法: awk -v plist=<patch.list> -f patch_dts.awk <输入.dts> > <输出.dts>
#
# patch.list 每行:  节点名 <TAB> 属性名 <TAB> 值
#   值为 __BOOL__ 表示该属性是布尔属性（不带 "= 值"），保持原样不改写。
#   以 # 开头的行是注释。
#
# 行为:
#   1) 剥离 __symbols__ / __fixups__ / __local_fixups__ 三个节点
#      （重新用 dtc -@ 编译时会自动重新生成，保留原文会重复定义）
#   2) 在指定节点内，把同名属性的值替换成 patch.list 里的值
#   3) 若指定节点内缺少该属性，则在节点末尾补上
#
# 兼容性: 只用 POSIX awk 特性。特别注意不能写 [ \t] —— 在方括号表达式里
#         反斜杠转义不是标准行为（mawk/toybox/busybox 会把它当成字母 t），
#         所以这里统一用 [[:space:]]。

function trim_left(s)  { sub(/^[[:space:]]+/, "", s); return s }
function trim_right(s) { sub(/[[:space:]]+$/, "", s); return s }

# 从 "label: name {" 中取出 name
function node_name(line,   s, p) {
	s = trim_left(line)
	sub(/[[:space:]]*\{[[:space:]]*$/, "", s)
	s = trim_right(s)
	p = index(s, ":")
	if (p > 0) s = substr(s, p + 1)
	return trim_left(s)
}

# 取行首缩进
function indent_of(line,   s) {
	s = line
	sub(/[^[:space:]].*$/, "", s)
	return s
}

# 从 "name = value;" 或 "name;" 中取出 name
function prop_name(line,   s, p) {
	s = trim_left(line)
	p = index(s, "=")
	if (p > 0) s = substr(s, 1, p - 1)
	else sub(/[[:space:]]*;[[:space:]]*$/, "", s)
	return trim_right(s)
}

# 节点收尾时补齐缺失的属性
function emit_missing(node, child_indent,   i, k) {
	for (i = 1; i <= npatch; i++) {
		if (pnode[i] != node) continue
		k = node SUBSEP pprop[i]
		if (k in applied) continue
		if (pval[i] == "__BOOL__") continue
		print child_indent pprop[i] " = " pval[i] ";"
		applied[k] = 1
		added++
	}
}

BEGIN {
	npatch = 0
	depth = 0
	skip = 0
	added = 0
	replaced = 0

	while ((getline ln < plist) > 0) {
		if (ln ~ /^[[:space:]]*#/) continue
		if (ln ~ /^[[:space:]]*$/) continue
		p1 = index(ln, "\t")
		if (p1 == 0) continue
		rest = substr(ln, p1 + 1)
		p2 = index(rest, "\t")
		if (p2 == 0) continue
		nd = substr(ln, 1, p1 - 1)
		pp = substr(rest, 1, p2 - 1)
		vv = substr(rest, p2 + 1)
		sub(/\r$/, "", vv)
		npatch++
		pnode[npatch] = nd
		pprop[npatch] = pp
		pval[npatch]  = vv
		known[nd] = 1
		idx[nd SUBSEP pp] = npatch
	}
	close(plist)
}

{
	line = $0

	# ---- 正在跳过 __symbols__ / __fixups__ / __local_fixups__ ----
	if (skip > 0) {
		t = line; o = gsub(/\{/, "", t)
		t = line; c = gsub(/\}/, "", t)
		skip += o - c
		if (skip < 0) skip = 0
		next
	}

	# ---- 节点打开 ----
	if (line ~ /\{[[:space:]]*$/ && line !~ /=/ && line !~ /;[[:space:]]*$/) {
		nm = node_name(line)
		if (nm == "__symbols__" || nm == "__fixups__" || nm == "__local_fixups__") {
			t = line; o = gsub(/\{/, "", t)
			t = line; c = gsub(/\}/, "", t)
			skip = o - c
			if (skip <= 0) skip = 1
			next
		}
		depth++
		stk[depth] = nm
		stkind[depth] = indent_of(line)
		print line
		next
	}

	# ---- 节点关闭 ----
	if (line ~ /^[[:space:]]*\}[[:space:]]*;[[:space:]]*$/) {
		if (depth > 0) {
			if (stk[depth] in known) emit_missing(stk[depth], stkind[depth] "\t")
			delete stk[depth]
			delete stkind[depth]
			depth--
		}
		print line
		next
	}

	# ---- 属性行 ----
	if (depth > 0 && (stk[depth] in known) && line ~ /^[[:space:]]*[^[:space:]]+[[:space:]]*=/) {
		pn = prop_name(line)
		k = stk[depth] SUBSEP pn
		if (k in idx) {
			i = idx[k]
			if (pval[i] != "__BOOL__") {
				print indent_of(line) pn " = " pval[i] ";"
				applied[k] = 1
				replaced++
				next
			}
			applied[k] = 1
		}
		print line
		next
	}

	print line
}

END {
	if (verbose) {
		printf "# replaced=%d added=%d rules=%d\n", replaced, added, npatch > "/dev/stderr"
	}
}
