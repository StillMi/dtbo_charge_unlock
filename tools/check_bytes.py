#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
逐字节核对：FFC_TEMP_HIGH=55 时，模块对「原厂 dtbo 表」处理后的产物
应当与「参考 dtb 重新打成同样结构的 dtbo 表」完全一致。

用法: python tools/check_bytes.py <产物分区镜像> <参考 dtb> <原厂分区镜像>
"""
import struct
import sys

DTBO_MAGIC = 0xD7B7AB1E


def parse(img):
    magic, total, hdrsz, entsz, cnt, eoff, page, ver = struct.unpack("<8I", img[:32])
    if magic != DTBO_MAGIC:
        raise SystemExit("不是 DTBO 表（magic %08x）" % magic)
    ents = []
    for i in range(cnt):
        o = eoff + i * entsz
        size, off, eid, rev = struct.unpack("<4I", img[o:o + 16])
        custom = struct.unpack("<4I", img[o + 16:o + 32])
        ents.append(dict(size=size, off=off, id=eid, rev=rev, custom=custom))
    return dict(total=total, hdrsz=hdrsz, entsz=entsz, cnt=cnt,
                eoff=eoff, page=page, ver=ver, ents=ents)


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 1
    prod_path, ref_path, orig_path = sys.argv[1], sys.argv[2], sys.argv[3]

    prod = open(prod_path, "rb").read()
    ref = open(ref_path, "rb").read()
    orig = open(orig_path, "rb").read()

    pp = parse(prod)
    op = parse(orig)
    print("产物: %d 条目，page=%d，total=%d" % (pp["cnt"], pp["page"], pp["total"]))
    print("原厂: %d 条目，page=%d，total=%d" % (op["cnt"], op["page"], op["total"]))

    ok = True
    if pp["cnt"] != op["cnt"]:
        print("[FAIL] 条目数变了")
        ok = False
    if pp["page"] != op["page"]:
        print("[FAIL] page_size 变了")
        ok = False
    if pp["eoff"] != op["eoff"]:
        print("[FAIL] entries_offset 变了")
        ok = False
    if pp["ver"] != op["ver"]:
        print("[FAIL] version 变了")
        ok = False

    for i, (pe, oe) in enumerate(zip(pp["ents"], op["ents"])):
        if pe["id"] != oe["id"] or pe["rev"] != oe["rev"]:
            print("[FAIL] 条目 %d 的 id/rev 变了" % i)
            ok = False
        if pe["custom"] != oe["custom"]:
            print("[FAIL] 条目 %d 的 custom 变了" % i)
            ok = False
        blob = prod[pe["off"]:pe["off"] + pe["size"]]
        if blob == ref:
            print("  条目 %d: 与参考 dtb 逐字节一致（%d 字节）" % (i, pe["size"]))
        else:
            print("  条目 %d: 与参考 dtb 不同（%d 字节 vs %d 字节）"
                  % (i, pe["size"], len(ref)))
            ok = False

    # 分区尾部必须是全零
    tail = prod[pp["total"]:]
    if tail.strip(b"\0"):
        print("[FAIL] 分区尾部有非零残留（%d 字节）" % len(tail))
        ok = False
    else:
        print("  分区尾部 %d 字节全零" % len(tail))

    print()
    print("=== 逐字节核对通过 ===" if ok else "=== 逐字节核对失败 ===")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
