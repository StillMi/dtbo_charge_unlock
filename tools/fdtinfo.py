#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""极简 FDT/DTBO 解析器：用于在 PC 上校验模块产出的 dtb。"""
import struct
import sys

FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


def parse_header(b):
    if len(b) < 40:
        raise ValueError("too small")
    (magic, totalsize, off_struct, off_strings, off_rsvmap,
     version, last_comp, boot_cpuid, size_strings, size_struct) = struct.unpack_from(">10I", b, 0)
    if magic != FDT_MAGIC:
        raise ValueError("bad magic 0x%08x" % magic)
    if totalsize != len(b):
        raise ValueError("totalsize %d != file size %d" % (totalsize, len(b)))
    return dict(totalsize=totalsize, off_struct=off_struct, off_strings=off_strings,
                off_rsvmap=off_rsvmap, version=version, last_comp=last_comp,
                boot_cpuid=boot_cpuid, size_strings=size_strings, size_struct=size_struct)


def walk(b, hdr):
    """返回 [(path, {prop: bytes})]，path 形如 /fragment@40/__overlay__/mca_buckchg_jeita"""
    off, end = hdr["off_struct"], hdr["off_struct"] + hdr["size_struct"]
    stroff = hdr["off_strings"]
    stack = []
    nodes = []
    while off < end:
        tok = struct.unpack_from(">I", b, off)[0]
        off += 4
        if tok == FDT_BEGIN_NODE:
            name_end = b.index(b"\0", off)
            name = b[off:name_end].decode("utf-8", "replace")
            off = (name_end + 4) & ~3
            stack.append(name)
            nodes.append(("/" + "/".join(n for n in stack if n), {}))
        elif tok == FDT_END_NODE:
            if stack:
                stack.pop()
        elif tok == FDT_PROP:
            length, nameoff = struct.unpack_from(">II", b, off)
            off += 8
            val = b[off:off + length]
            off = (off + length + 3) & ~3
            nend = b.index(b"\0", stroff + nameoff)
            pname = b[stroff + nameoff:nend].decode("utf-8", "replace")
            if nodes:
                nodes[-1][1][pname] = val
        elif tok == FDT_NOP:
            pass
        elif tok == FDT_END:
            break
        else:
            raise ValueError("bad token 0x%x at 0x%x" % (tok, off - 4))
    return nodes


def main():
    path = sys.argv[1]
    with open(path, "rb") as fh:
        b = fh.read()
    hdr = parse_header(b)
    print("header:", hdr)
    nodes = walk(b, hdr)
    print("nodes:", len(nodes))
    bad = []
    for p, props in nodes:
        for k, v in props.items():
            if k in ("interrupt-parent", "phandle", "interrupts-extended") and len(v) % 4:
                bad.append((p, k, len(v)))
    for x in bad[:20]:
        print("ODD:", x)
    if len(sys.argv) > 2:
        want = sys.argv[2]
        for p, props in nodes:
            if p.endswith("/" + want) or p == want:
                print("=== ", p)
                for k, v in props.items():
                    if len(v) > 40:
                        print("   %-28s len=%d (long)" % (k, len(v)))
                    else:
                        print("   %-28s %s" % (k, v.hex()))


if __name__ == "__main__":
    main()
