#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从 ref/patch.list 生成设备端可直接使用的 sed 脚本与校验数据。

产物:
  ref/patch.sed          —— sed -f 执行的替换脚本（含 FFC 温度占位符）
  ref/expect/<node>.txt  —— 每个目标节点应有的属性行，供 check 阶段逐条比对

为什么用 sed 而不是 awk:
  原厂 Android 的 toybox 不提供 awk，Magisk / KernelSU 也不再自带 busybox，
  但 sed / grep / cut / dd / od 一定存在。所以运行时只用这些基础工具。

占位符（运行时由 common.sh 用 sed 替换成实际配置值）:
  @FFC_LOW_HEX@   例如 0x00
  @FFC_HIGH_HEX@  例如 0x38
  @FFC_HIGH@      例如 56   （JEITA / 温度分段表里的高温边界）

用法: python tools/gen_sed.py <patch.list> <输出目录>
"""
import os
import re
import sys

# 生成时认定的「参考高温边界」。patch.list 里作为温度分段边界出现的这个值，
# 会被换成 @FFC_HIGH@ 占位符，运行时再填成实际配置的温度。
REF_HIGH = "55"
REF_HIGH_HEX = "0x37"
REF_LOW_HEX = "0x00"

# 属性名匹配这些前缀的，值里含温度分段表，边界上的 REF_HIGH 要换成占位符
TEMP_TABLE_PROPS = re.compile(r"^(jeita_para|temp_para|batt_para)")


def placeholder_value(prop, value):
    if prop == "ffc_temp_low" and value.strip() == "<%s>" % REF_LOW_HEX:
        return "<@FFC_LOW_HEX@>"
    if prop == "ffc_temp_high" and value.strip() == "<%s>" % REF_HIGH_HEX:
        return "<@FFC_HIGH_HEX@>"
    if TEMP_TABLE_PROPS.match(prop):
        # 只替换「作为独立分段出现」的 "55"，不会误伤 65535 / -65535
        return re.sub(r'"%s"' % re.escape(REF_HIGH), '"@FFC_HIGH@"', value)
    return value


def node_range(node):
    """节点块的 sed 地址范围：从节点定义行到同层收尾的 '};'。"""
    # 兼容 "label: node {" 和 "node {" 两种写法
    start = (r"/^[[:space:]]*\([^[:space:]:]*:[[:space:]]*\)\{0,1\}%s"
             r"[[:space:]]*{/" % node)
    end = r"/^[[:space:]]*};/"
    return "%s,%s" % (start, end)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    plist, outdir = sys.argv[1], sys.argv[2]

    rules = []
    for line in open(plist, "r", encoding="utf-8"):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        rules.append(tuple(parts))

    order, groups = [], {}
    for node, prop, value in rules:
        if node not in groups:
            groups[node] = []
            order.append(node)
        groups[node].append((prop, value))

    os.makedirs(outdir, exist_ok=True)
    expdir = os.path.join(outdir, "expect")
    os.makedirs(expdir, exist_ok=True)
    for fn in os.listdir(expdir):
        if fn.endswith(".txt"):
            os.remove(os.path.join(expdir, fn))

    out = [
        "# 由 tools/gen_sed.py 自动生成，请勿手工修改",
        "# 用法: sed -f patch.sed <输入.dts> > <输出.dts>",
        "# 作用: 在指定节点块内，把有线充电限制相关的属性替换成目标值",
        "# 占位符: @FFC_LOW_HEX@ @FFC_HIGH_HEX@ @FFC_HIGH@",
        "",
    ]

    total = 0
    for node in order:
        rng = node_range(node)
        out.append("# ---- %s ----" % node)
        exp = []
        for prop, value in groups[node]:
            pv = placeholder_value(prop, value)
            if pv == "__BOOL__":
                # 布尔属性：只校验存在，不改写
                exp.append(prop + ";")
                continue
            repl = "%s = %s;" % (prop, pv)
            # s 命令保留原有缩进；范围地址限定在目标节点块内
            out.append(r"%s s/^\([[:space:]]*\)%s[[:space:]]*=.*/\1%s/"
                       % (rng, re.escape(prop), repl))
            exp.append(repl)
            total += 1
        out.append("")
        with open(os.path.join(expdir, node + ".txt"), "w",
                  encoding="utf-8", newline="\n") as fh:
            fh.write("\n".join(exp) + "\n")

    with open(os.path.join(outdir, "patch.sed"), "w",
              encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(out))

    print("patch.sed: %d 个节点, %d 条替换" % (len(order), total))
    print("expect/: %d 个文件" % len(order))
    return 0


if __name__ == "__main__":
    sys.exit(main())
