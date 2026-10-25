#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成「厂商 OTA 更新过 dtbo」的测试夹具。

目的: 验证「系统升级换了 dtbo，即使跟充电无关的部分被改过，只要充电节点
还在、属性没变，模块仍然能顺利跑通」。

做法:
  拿 mkfixtures.py 已经产出的 stock.dtb / ref.dtb，用 dtc 反编译成 dts，
  在根节点里塞一个跟充电毫无关系的新节点（模拟 OTA 顺手改了别的东西），
  再编译回去。因为 dtc 重排了所有节点的顺序和偏移，整份 dtb 的字节
  都会变——这正是真实 OTA 之后的样子。

产出的夹具:
  part_dtbo_drift.img          3 条目，全部塞了无关新节点，充电节点原样
  part_dtbo_drift_extra.img    4 条目（厂商加了新板型，也带充电节点）
  part_dtbo_drift_split.img    3 条目，但充电节点被拆散到不同条目里
  part_dtbo_drift_nocharge.img 3 条目，中间那条完全没有充电节点

用法: python tools/mkdrift.py <模块目录> <dtc可执行文件>
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mkfixtures import build_dtbo_table, pad, run  # noqa: E402

# 模块要改写的 8 个节点（ref/expect/ 里的文件名）
CHG_NODES = [
    "mca_buckchg_jeita",
    "mca_buckchg_jeita_gbl_para",
    "mca_buckchg_jeita_second_para",
    "mca_buckchg_jeita_tmp_para",
    "mca_charger_thermal",
    "mca_quick_charge_batt_para_gbl",
    "mca_strategy_buckchg_class",
    "mca_strategy_quick_charge",
]


def to_dts(dtc, dtb_path, dts_path):
    run(dtc, "-I", "dtb", "-O", "dts", "-o", dts_path, dtb_path)
    with open(dts_path, encoding="utf-8") as fh:
        return fh.read()


def to_dtb(dtc, text, dts_path, dtb_path):
    with open(dts_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    # 不加 -@: 反编译回来的 dts 已经没有 label 了，保持 phandle 原样最稳
    run(dtc, "-I", "dts", "-O", "dtb", "-o", dtb_path, dts_path)
    with open(dtb_path, "rb") as fh:
        return fh.read()


def inject_node(text, name, marker):
    """在根节点里插一个跟充电无关的新节点。

    注意不能插在 `/ {` 紧后面 —— dtc 要求「属性必须排在子节点前面」，
    插在那里会报 "Properties must precede subnodes"。所以插在根节点
    闭合的 `};` 之前，也就是所有既有子节点的后面。
    """
    lines = text.split("\n")
    for i, line in enumerate(lines):
        if line.strip() == "/ {":
            depth = 0
            for j in range(i, len(lines)):
                depth += lines[j].count("{") - lines[j].count("}")
                if depth == 0:
                    lines[j:j] = [
                        "\t%s {" % name,
                        "\t\tcompatible = \"vendor,%s\";" % marker,
                        "\t\tvendor,rev = <0x2a>;",
                        "\t\tstatus = \"okay\";",
                        "\t};",
                        "",
                    ]
                    return "\n".join(lines)
            break
    raise SystemExit("dts 里找不到根节点 `/ {`")


def node_block_range(lines, name):
    """找出某个节点块的 [开始行, 结束行]（含），找不到返回 None。"""
    import re
    head = re.compile(r"^\s*(?:[\w,.\-+@#]+\s*:\s*)*%s\s*\{\s*$" % re.escape(name))
    for i, line in enumerate(lines):
        if head.match(line):
            depth = 0
            for j in range(i, len(lines)):
                depth += lines[j].count("{") - lines[j].count("}")
                if depth == 0:
                    return i, j
            return None
    return None


def drop_nodes(text, names):
    """删掉指定节点块，剩下的原样保留。"""
    lines = text.split("\n")
    for name in names:
        rng = node_block_range(lines, name)
        if rng is None:
            raise SystemExit("dts 里找不到节点 %s，没法删" % name)
        del lines[rng[0]:rng[1] + 1]
    return "\n".join(lines)


def keep_only(text, names):
    """只保留指定节点，其他充电节点全删。"""
    return drop_nodes(text, [n for n in CHG_NODES if n not in names])


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    moddir, dtc = sys.argv[1], sys.argv[2]
    out = os.path.join(moddir, "build")

    stock_dtb = os.path.join(out, "stock.dtb")
    ref_dtb = os.path.join(out, "ref.dtb")
    for p in (stock_dtb, ref_dtb):
        if not os.path.exists(p):
            raise SystemExit("缺少 %s，先跑 tools/mkfixtures.py" % p)

    stock_dts = to_dts(dtc, stock_dtb, os.path.join(out, "drift_stock.dts"))
    ref_dts = to_dts(dtc, ref_dtb, os.path.join(out, "drift_ref.dts"))

    # 1) 塞无关新节点，充电部分一个字节都不动
    stock_drift = to_dtb(
        dtc, inject_node(stock_dts, "ota_drift_marker", "ota-drift"),
        os.path.join(out, "drift_stock_inj.dts"),
        os.path.join(out, "drift_stock_inj.dtb"))
    ref_drift = to_dtb(
        dtc, inject_node(ref_dts, "ota_drift_marker", "ota-drift"),
        os.path.join(out, "drift_ref_inj.dts"),
        os.path.join(out, "drift_ref_inj.dtb"))
    print("drift_stock_inj.dtb %d 字节（原 %d，塞了无关节点后 dtc 重排了全部字节）"
          % (len(stock_drift), os.path.getsize(stock_dtb)))

    # 2) 新板型：塞了无关节点，充电节点齐全（厂商加了个变种）
    newboard_drift = to_dtb(
        dtc, inject_node(stock_dts, "ota_drift_marker", "ota-new-board"),
        os.path.join(out, "drift_newboard.dts"),
        os.path.join(out, "drift_newboard.dtb"))

    # 3) 只留一个充电节点（模拟厂商把节点拆到别的条目里）
    only_ct = to_dtb(
        dtc, inject_node(keep_only(stock_dts, ["mca_charger_thermal"]),
                         "ota_drift_marker", "ota-split-a"),
        os.path.join(out, "drift_split_a.dts"),
        os.path.join(out, "drift_split_a.dtb"))
    rest = [n for n in CHG_NODES if n != "mca_charger_thermal"]
    rest_ct = to_dtb(
        dtc, inject_node(keep_only(stock_dts, rest),
                         "ota_drift_marker", "ota-split-b"),
        os.path.join(out, "drift_split_b.dts"),
        os.path.join(out, "drift_split_b.dtb"))

    # 4) 完全没有充电节点的条目
    nocharge = to_dtb(
        dtc, inject_node(drop_nodes(stock_dts, CHG_NODES),
                         "ota_drift_marker", "ota-nocharge"),
        os.path.join(out, "drift_nocharge.dts"),
        os.path.join(out, "drift_nocharge.dtb"))

    cases = [
        ("part_dtbo_drift.img",
         [(stock_drift, 0x0000, 0), (stock_drift, 0x0001, 0), (ref_drift, 0x0002, 0)],
         "3 条目，全部塞了无关新节点，充电节点原样"),
        ("part_dtbo_drift_extra.img",
         [(stock_drift, 0x0000, 0), (stock_drift, 0x0001, 0),
          (ref_drift, 0x0002, 0), (newboard_drift, 0x0003, 0)],
         "4 条目，厂商新增了一个也带充电节点的新板型"),
        ("part_dtbo_drift_split.img",
         [(only_ct, 0x0000, 0), (rest_ct, 0x0001, 0), (stock_drift, 0x0002, 0)],
         "3 条目，充电节点被拆散到不同条目里"),
        ("part_dtbo_drift_nocharge.img",
         [(stock_drift, 0x0000, 0), (nocharge, 0x0001, 0), (ref_drift, 0x0002, 0)],
         "3 条目，中间那条完全没有充电节点"),
    ]

    for name, entries, desc in cases:
        path = os.path.join(out, name)
        pad(path, build_dtbo_table(entries))
        print("%-30s %d 字节（%s）" % (name, os.path.getsize(path), desc))

    return 0


if __name__ == "__main__":
    sys.exit(main())
