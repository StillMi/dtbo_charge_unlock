#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从一份「已改好目标」的反编译 dts 中提取有线充电限制参数，生成：
  ref/target.dts   —— 去掉 __symbols__ / __fixups__ 后可直接用 dtc 编译的 dts
  ref/patch.list   —— 节点<TAB>属性<TAB>值 形式的替换表（运行时用它改写 dts）

用法:
  python gen_ref.py <参考.dts> <输出目录>
"""
import os
import re
import sys

# 只收录与「有线充电限制」直接相关的节点。
# 无线充电、电池模型、防烧口（connector_antiburn）等节点不在此列。
CHARGE_NODES = [
    "mca_buckchg_jeita",
    "mca_buckchg_jeita_second_para",
    "mca_buckchg_jeita_gbl_para",
    "mca_buckchg_jeita_tmp_para",
    "mca_strategy_buckchg_class",
    "mca_strategy_quick_charge",
    "mca_quick_charge_batt_para_gbl",
    "mca_charger_thermal",
]

NODE_OPEN_LABELED = re.compile(r"^\s*([\w,.\-+@#]+)\s*:\s*([\w,.\-+@#]+)\s*\{\s*$")
NODE_OPEN_PLAIN = re.compile(r"^\s*([\w,.\-+@#]+)\s*\{\s*$")
NODE_CLOSE = re.compile(r"^\s*\}\s*;\s*$")
PROP = re.compile(r"^(\s*)([\w,.\-+#@?]+)\s*=\s*(.+?)\s*;\s*$")
PROP_BOOL = re.compile(r"^(\s*)([\w,.\-+#@?]+)\s*;\s*$")


def parse(text):
    """返回 [(innermost_node_name, prop_name, raw_value)]，保持文件顺序。"""
    out = []
    stack = []
    for line in text.split("\n"):
        m = NODE_OPEN_LABELED.match(line)
        if m:
            stack.append(m.group(2))
            continue
        m = NODE_OPEN_PLAIN.match(line)
        if m and "=" not in line:
            stack.append(m.group(1))
            continue
        if NODE_CLOSE.match(line):
            if stack:
                stack.pop()
            continue
        m = PROP.match(line)
        if m and stack:
            out.append((stack[-1], m.group(2), m.group(3)))
            continue
        m = PROP_BOOL.match(line)
        if m and stack:
            out.append((stack[-1], m.group(2), None))
    return out


def strip_block(text, name):
    """删除顶层 __symbols__ / __fixups__ 节点（含其整个子树）。"""
    lines = text.split("\n")
    out = []
    skipping = False
    depth = 0
    for line in lines:
        if not skipping and re.match(r"^\s*" + re.escape(name) + r"\s*\{\s*$", line):
            skipping = True
            # 从节点自身的 '{' 开始计深度（__local_fixups__ 里还嵌套着子节点，
            # 若从 0 开始计数，第一个子节点收尾时就会误判为整块结束）
            depth = line.count("{") - line.count("}")
            continue
        if skipping:
            depth += line.count("{") - line.count("}")
            if depth <= 0:
                skipping = False
            continue
        out.append(line)
    return "\n".join(out)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    src_path, outdir = sys.argv[1], sys.argv[2]
    with open(src_path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()

    props = parse(text)

    # phandle 由 dtc 在编译时决定，跨 dtbo 复用会打断引用关系，必须排除
    SKIP_PROPS = {"phandle", "linux,phandle"}

    rows = []
    seen = set()
    for node, prop, value in props:
        if node not in CHARGE_NODES:
            continue
        if prop in SKIP_PROPS:
            continue
        if value is None:
            # 布尔属性：值用 "__BOOL__" 表示，运行时只保留不改写
            rows.append((node, prop, "__BOOL__"))
            seen.add((node, prop))
            continue
        rows.append((node, prop, value))
        seen.add((node, prop))

    # 显式保证：mca_charger_thermal 必须是 disabled
    rows = [r for r in rows if not (r[0] == "mca_charger_thermal" and r[1] == "status")]
    rows.append(("mca_charger_thermal", "status", '"disabled"'))

    os.makedirs(outdir, exist_ok=True)

    with open(os.path.join(outdir, "patch.list"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("# 由 tools/gen_ref.py 生成：节点<TAB>属性<TAB>值\n")
        fh.write("# 运行时由 bin/patch_dts.awk 按「节点名 + 属性名」精确替换\n")
        for node, prop, value in rows:
            fh.write("%s\t%s\t%s\n" % (node, prop, value))

    clean = strip_block(text, "__symbols__")
    clean = strip_block(clean, "__fixups__")
    # __local_fixups__ 由 dtc -@ 在编译时自动重新生成；保留原文会与重新生成的内容冲突
    clean = strip_block(clean, "__local_fixups__")
    with open(os.path.join(outdir, "target.dts"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(clean)

    nodes = sorted({r[0] for r in rows})
    print("patch.list: %d 条规则，覆盖节点: %s" % (len(rows), ", ".join(nodes)))
    print("target.dts: %d 行" % clean.count("\n"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
