# check_dts.awk —— 校验一份 dts 是否已经包含 patch.list 要求的全部取值
#
# 用法: awk -v plist=<patch.list> -f check_dts.awk <待校验.dts>
# 退出码: 0 = 全部匹配；1 = 有不匹配 / 缺失
#
# 兼容性: 只用 POSIX awk 特性；方括号表达式内不用 \t（见 patch_dts.awk 的说明）。

function trim_left(s)  { sub(/^[[:space:]]+/, "", s); return s }
function trim_right(s) { sub(/[[:space:]]+$/, "", s); return s }

function node_name(line,   s, p) {
	s = trim_left(line)
	sub(/[[:space:]]*\{[[:space:]]*$/, "", s)
	s = trim_right(s)
	p = index(s, ":")
	if (p > 0) s = substr(s, p + 1)
	return trim_left(s)
}

function prop_name(line,   s, p) {
	s = trim_left(line)
	p = index(s, "=")
	if (p > 0) s = substr(s, 1, p - 1)
	else sub(/[[:space:]]*;[[:space:]]*$/, "", s)
	return trim_right(s)
}

function prop_value(line,   s, p, v) {
	s = trim_left(line)
	p = index(s, "=")
	if (p == 0) return ""
	v = substr(s, p + 1)
	sub(/^[[:space:]]+/, "", v)
	sub(/[[:space:]]*;[[:space:]]*$/, "", v)
	return v
}

# 归一化空白，避免缩进/换行差异造成误判
function norm(s) {
	gsub(/[[:space:]]+/, " ", s)
	sub(/^ /, "", s)
	sub(/ $/, "", s)
	return s
}

BEGIN {
	depth = 0
	fail = 0
	np = 0

	while ((getline ln < plist) > 0) {
		if (ln ~ /^[[:space:]]*#/) continue
		if (ln ~ /^[[:space:]]*$/) continue
		p1 = index(ln, "\t"); if (p1 == 0) continue
		rest = substr(ln, p1 + 1)
		p2 = index(rest, "\t"); if (p2 == 0) continue
		nd = substr(ln, 1, p1 - 1)
		pp = substr(rest, 1, p2 - 1)
		vv = substr(rest, p2 + 1)
		sub(/\r$/, "", vv)
		np++
		pnode[np] = nd
		pprop[np] = pp
		pval[np]  = vv
		known[nd] = 1
		idx[nd SUBSEP pp] = np
	}
	close(plist)
}

{
	line = $0

	if (line ~ /\{[[:space:]]*$/ && line !~ /=/ && line !~ /;[[:space:]]*$/) {
		depth++
		stk[depth] = node_name(line)
		next
	}

	if (line ~ /^[[:space:]]*\}[[:space:]]*;[[:space:]]*$/) {
		if (depth > 0) { delete stk[depth]; depth-- }
		next
	}

	if (depth > 0 && (stk[depth] in known)) {
		# 布尔属性
		if (line ~ /^[[:space:]]*[^[:space:]]+[[:space:]]*;[[:space:]]*$/) {
			pn = prop_name(line)
			k = stk[depth] SUBSEP pn
			if (k in idx) seen[k] = 1
			next
		}
		if (line !~ /=/) next

		pn = prop_name(line)
		k = stk[depth] SUBSEP pn
		if (!(k in idx)) next
		i = idx[k]
		if (pval[i] == "__BOOL__") { seen[k] = 1; next }

		pv = prop_value(line)
		if (norm(pv) == norm(pval[i])) {
			seen[k] = 1
		} else {
			printf "MISMATCH %s:%s\n  expect: %s\n  actual: %s\n", stk[depth], pn, pval[i], pv > "/dev/stderr"
			fail = 1
		}
	}
}

END {
	for (i = 1; i <= np; i++) {
		k = pnode[i] SUBSEP pprop[i]
		if (!(k in seen)) {
			printf "MISSING %s:%s\n", pnode[i], pprop[i] > "/dev/stderr"
			fail = 1
		}
	}
	if (verbose) printf "# checked=%d rules=%d\n", 0, np > "/dev/stderr"
	exit (fail ? 1 : 0)
}
