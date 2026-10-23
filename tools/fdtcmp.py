#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""比较两个 dtb 的语义内容（忽略 phandle 数值差异，只比较结构与属性值）。"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fdtinfo import parse_header, walk


def load(path):
    with open(path, "rb") as fh:
        b = fh.read()
    return dict(walk(b, parse_header(b)))


def main():
    a = load(sys.argv[1])
    b = load(sys.argv[2])
    ka, kb = set(a), set(b)
    only_a = sorted(ka - kb)
    only_b = sorted(kb - ka)
    print("nodes A=%d B=%d" % (len(ka), len(kb)))
    if only_a:
        print("ONLY IN A (%d):" % len(only_a))
        for p in only_a[:10]:
            print("  ", p)
    if only_b:
        print("ONLY IN B (%d):" % len(only_b))
        for p in only_b[:10]:
            print("  ", p)
    diffs = 0
    for p in sorted(ka & kb):
        pa, pb = a[p], b[p]
        for k in sorted(set(pa) | set(pb)):
            va, vb = pa.get(k), pb.get(k)
            if va != vb:
                diffs += 1
                if diffs <= 15:
                    print("DIFF %s:%s A=%s B=%s" % (p, k,
                          (va[:24].hex() if va is not None else "None"),
                          (vb[:24].hex() if vb is not None else "None")))
    print("property diffs:", diffs)
    return 0 if not only_a and not only_b and diffs == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
