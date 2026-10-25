#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 PC 端测试用的夹具（假 dtbo 分区镜像）。

思路:
  1) 用 dtc 把 ref/target.dts 编译成 ref.dtb（= 目标镜像）
  2) 把 ref.dtb 反编译成 dts，再把 patch.list 里列出的每个属性都改成垃圾值，
     编译成 stock.dtb（= 模拟「未改过的原厂 dtbo」）
  3) 补零到 8 MB，得到 part_stock.img（单 DTB 分区）
  4) 把两份 DTB 串接再补零，得到 part_two.img（双 DTB 分区）

用法: python tools/mkfixtures.py <模块目录> <dtc可执行文件>
"""
import os
import re
import struct
import subprocess
import sys

PART_SIZE = 8 * 1024 * 1024


def run(dtc, *args):
    r = subprocess.run([dtc] + list(args), capture_output=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr.decode("utf-8", "replace"))
        raise SystemExit("dtc 失败: %s" % " ".join(args))


def load_rules(path):
    rules = []
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) == 3:
            rules.append(tuple(parts))
    return rules


NODE_OPEN = re.compile(r"^\s*(?:[\w,.\-+@#]+\s*:\s*)*([\w,.\-+@#]+)\s*\{\s*$")
NODE_CLOSE = re.compile(r"^\s*\}\s*;\s*$")
PROP = re.compile(r"^(\s*)([\w,.\-+#@?]+)\s*=")


def corrupt(dts_text, rules):
    """把规则涉及的属性值全换成垃圾，模拟未修改过的原厂 dtbo。"""
    want = {}
    for node, prop, val in rules:
        want.setdefault(node, {})[prop] = val

    out, stack, n = [], [], 0
    for line in dts_text.split("\n"):
        m = NODE_OPEN.match(line)
        if m and "=" not in line and not line.rstrip().endswith(";"):
            stack.append(m.group(1))
            out.append(line)
            continue
        if NODE_CLOSE.match(line):
            if stack:
                stack.pop()
            out.append(line)
            continue
        cur = stack[-1] if stack else None
        pm = PROP.match(line)
        if cur in want and pm and pm.group(2) in want[cur]:
            ref = want[cur][pm.group(2)]
            if ref == "__BOOL__":
                out.append(line)
                continue
            junk = '"ZZZ_STOCK_%d"' % n if ref.startswith('"') else "<0xdeadbeef>"
            out.append("%s%s = %s;" % (pm.group(1), pm.group(2), junk))
            n += 1
            continue
        out.append(line)
    return "\n".join(out), n


def pad(path, data):
    with open(path, "wb") as fh:
        fh.write(data)
        fh.write(b"\0" * (PART_SIZE - len(data)))


# --------------------------------------------------------------- DTBO 表 ---
DTBO_MAGIC = 0xD7B7AB1E
DTBO_PAGE = 2048


def build_dtbo_table(entries, endian="<", page_align=True, page=DTBO_PAGE):
    """按 Android mkdtimg 的格式拼一个 DTBO 表。

    entries: [(dtb_bytes, id, rev), ...]
    endian:      "<" = 官方 mkdtimg 小端；">" = 部分厂商的大端
    page_align:  True = 每个 dtb 按 page 对齐；False = 条目紧挨着排
    """
    header_size = 32
    entry_size = 32
    count = len(entries)
    entries_off = header_size
    cur = entries_off + count * entry_size

    laid = []
    for data, eid, rev in entries:
        if page_align:
            off = (cur + page - 1) // page * page
        else:
            off = cur
        laid.append((off, len(data), eid, rev, data))
        cur = off + len(data)
    total = cur

    out = bytearray()
    out += struct.pack(endian + "8I", DTBO_MAGIC, total, header_size,
                       entry_size, count, entries_off, page, 0)
    for off, size, eid, rev, _ in laid:
        out += struct.pack(endian + "4I4I", size, off, eid, rev, 0, 0, 0, 0)
    for off, size, eid, rev, data in laid:
        out += b"\0" * (off - len(out))
        out += data
    return bytes(out)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    moddir, dtc = sys.argv[1], sys.argv[2]
    out = os.path.join(moddir, "build")
    os.makedirs(out, exist_ok=True)

    target_dts = os.path.join(moddir, "ref", "target.dts")
    ref_dtb = os.path.join(out, "ref.dtb")
    run(dtc, "-@", "-I", "dts", "-O", "dtb", "-o", ref_dtb, target_dts)
    print("ref.dtb      %d 字节" % os.path.getsize(ref_dtb))

    ref_dts = os.path.join(out, "ref.dts")
    run(dtc, "-I", "dtb", "-O", "dts", "-o", ref_dts, ref_dtb)

    text = open(ref_dts, encoding="utf-8").read()
    rules = load_rules(os.path.join(moddir, "ref", "patch.list"))
    stock_text, n = corrupt(text, rules)
    print("已把 %d 个目标属性改成垃圾值" % n)

    stock_dts = os.path.join(out, "stock.dts")
    with open(stock_dts, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(stock_text)
    stock_dtb = os.path.join(out, "stock.dtb")
    run(dtc, "-@", "-I", "dts", "-O", "dtb", "-o", stock_dtb, stock_dts)
    print("stock.dtb    %d 字节" % os.path.getsize(stock_dtb))

    stock = open(stock_dtb, "rb").read()
    ref = open(ref_dtb, "rb").read()

    # 「别的板型」：完全不含充电节点，用来填充 dtbo 表里的其他条目。
    # 真机上 dtbo 分区里的每个条目对应一个板型，它们的原厂取值都不会等于
    # 我们的目标值 —— 所以不能拿 ref.dtb（目标镜像）去填，那会造出一个
    # 「原厂就已经是改好状态」的假分区，测出来的东西没有意义。
    other_dts = os.path.join(out, "other.dts")
    with open(other_dts, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("/dts-v1/;\n\n/ {\n\tmodel = \"other-board\";\n"
                 "\tcompatible = \"qcom,other\";\n\t#address-cells = <2>;\n"
                 "\t#size-cells = <2>;\n\n\tchosen {\n\t\tbootargs = \"\";\n\t};\n};\n")
    other_dtb = os.path.join(out, "other.dtb")
    run(dtc, "-@", "-I", "dts", "-O", "dtb", "-o", other_dtb, other_dts)
    other = open(other_dtb, "rb").read()
    print("other.dtb    %d 字节（不含充电节点）" % len(other))

    part1 = os.path.join(out, "part_stock.img")
    pad(part1, stock)
    print("part_stock.img   %d 字节（裸 DTB 单段）" % os.path.getsize(part1))

    part2 = os.path.join(out, "part_two.img")
    pad(part2, stock + other)
    print("part_two.img     %d 字节（裸 DTB 双段串接）" % os.path.getsize(part2))

    # 真实设备用的格式：DTBO 表，多个 dtb 对应不同板型
    tbl = build_dtbo_table([
        (stock, 0x0000, 0),
        (stock, 0x0001, 0),
        (other, 0x0002, 0),
    ])
    part3 = os.path.join(out, "part_dtbo.img")
    pad(part3, tbl)
    print("part_dtbo.img    %d 字节（DTBO 表，3 个条目，%d 字节表）"
          % (os.path.getsize(part3), len(tbl)))

    part4 = os.path.join(out, "part_dtbo1.img")
    pad(part4, build_dtbo_table([(stock, 0x0000, 0)]))
    print("part_dtbo1.img   %d 字节（DTBO 表，单条目）" % os.path.getsize(part4))

    # 混合：部分条目是「别的板型」，根本不含充电节点
    part5 = os.path.join(out, "part_dtbo_mixed.img")
    pad(part5, build_dtbo_table([
        (other, 0x0000, 0),
        (stock, 0x0001, 0),
        (other, 0x0002, 0),
    ]))
    print("part_dtbo_mixed.img %d 字节（DTBO 表，1/3 含充电节点）"
          % os.path.getsize(part5))

    # 全部条目都不含充电节点：模块应当拒绝
    part6 = os.path.join(out, "part_dtbo_none.img")
    pad(part6, build_dtbo_table([(other, 0x0000, 0), (other, 0x0001, 0)]))
    print("part_dtbo_none.img  %d 字节（DTBO 表，均不含充电节点）"
          % os.path.getsize(part6))

    # 大端 + 条目紧凑排列（实际遇到的 SM8850 机型就是这样）：
    # magic 在文件里是 d7 b7 ab 1e，条目偏移之间没有任何对齐填充。
    part7 = os.path.join(out, "part_dtbo_be.img")
    pad(part7, build_dtbo_table(
        [(other, 0x0000, 0), (stock, 0x0000, 0)],
        endian=">", page_align=False, page=4096))
    print("part_dtbo_be.img    %d 字节（DTBO 表，大端，紧凑排列，2 条目）"
          % os.path.getsize(part7))
    return 0


if __name__ == "__main__":
    sys.exit(main())
