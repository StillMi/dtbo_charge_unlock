#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""分析真实 dtbo 镜像的结构（两种字节序都试）。"""
import struct
import sys

path = sys.argv[1]
d = open(path, "rb").read()
print("file size: %d" % len(d))
h = d[:32]

for endian, name in ((">", "BIG-ENDIAN"), ("<", "LITTLE-ENDIAN")):
    magic, total, hdrsz, entsz, cnt, eoff, page, ver = struct.unpack(endian + "8I", h)
    print("\n%s:" % name)
    print("  magic      = 0x%08x  %s" % (magic, "OK" if magic == 0xD7B7AB1E else "BAD"))
    print("  total_size = %d" % total)
    print("  header_size= %d" % hdrsz)
    print("  entry_size = %d" % entsz)
    print("  entry_count= %d" % cnt)
    print("  entries_off= %d" % eoff)
    print("  page_size  = %d" % page)
    print("  version    = %d" % ver)
    if magic == 0xD7B7AB1E and 0 < cnt < 64 and entsz >= 32 and eoff + cnt * entsz <= len(d):
        print("  --- entries ---")
        for i in range(cnt):
            o = eoff + i * entsz
            sz, off, eid, rev = struct.unpack(endian + "4I", d[o:o + 16])
            cust = struct.unpack(endian + "4I", d[o + 16:o + 32])
            ok = (off + sz <= min(total, len(d))) and sz > 0
            print("    #%d size=%-8d off=%-8d id=0x%08x rev=0x%08x custom=%s %s"
                  % (i, sz, off, eid, rev, ["0x%x" % c for c in cust],
                     "" if ok else "<-- INVALID"))

print("\n=== scan for FDT magic d00dfeed ===")
pos = []
i = 0
while True:
    i = d.find(b"\xd0\x0d\xfe\xed", i)
    if i < 0:
        break
    pos.append(i)
    i += 1
print("count = %d" % len(pos))
for q in pos[:16]:
    tot = struct.unpack(">I", d[q + 4:q + 8])[0] if q + 8 <= len(d) else 0
    print("  offset %-10d totalsize=%d" % (q, tot))

print("\n=== scan magic patterns ===")
for pat in (b"\xd7\xb7\xab\x1e", b"\x1e\xab\xb7\xd7"):
    ps = []
    i = 0
    while True:
        i = d.find(pat, i)
        if i < 0:
            break
        ps.append(i)
        i += 1
    print("  %s -> %d occurrence(s) %s" % (pat.hex(), len(ps), ps[:8]))
