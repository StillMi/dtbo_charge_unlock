#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""独立校验：把 dtbo 镜像按表拆开，检查结构和关键充电参数。"""
import os
import struct
import subprocess
import sys

DTBO_MAGIC = 0xD7B7AB1E


def parse(d):
    for endian, name in (("<", "le"), (">", "be")):
        magic, total, hdrsz, entsz, cnt, eoff, page, ver = struct.unpack(
            endian + "8I", d[:32])
        if magic == DTBO_MAGIC:
            break
    else:
        raise SystemExit("magic 不匹配")
    ents = []
    for i in range(cnt):
        o = eoff + i * entsz
        sz, off, eid, rev = struct.unpack(endian + "4I", d[o:o + 16])
        cust = struct.unpack(endian + "4I", d[o + 16:o + 32])
        ents.append(dict(size=sz, off=off, id=eid, rev=rev, custom=cust))
    return dict(endian=endian, total=total, hdrsz=hdrsz, entsz=entsz,
                cnt=cnt, eoff=eoff, page=page, ver=ver, ents=ents)


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 1
    newimg, origimg, dtc = sys.argv[1], sys.argv[2], sys.argv[3]
    outdir = sys.argv[4] if len(sys.argv) > 4 else "."

    new = open(newimg, "rb").read()
    orig = open(origimg, "rb").read()
    pn = parse(new)
    po = parse(orig)

    ok = True
    print("new : endian=%s total=%d cnt=%d page=%d ver=%d"
          % (pn["endian"], pn["total"], pn["cnt"], pn["page"], pn["ver"]))
    print("orig: endian=%s total=%d cnt=%d page=%d ver=%d"
          % (po["endian"], po["total"], po["cnt"], po["page"], po["ver"]))

    if pn["endian"] != po["endian"]:
        print("[FAIL] 字节序变了"); ok = False
    if pn["cnt"] != po["cnt"]:
        print("[FAIL] 条目数变了"); ok = False
    if pn["page"] != po["page"]:
        print("[FAIL] page_size 变了"); ok = False
    if pn["eoff"] != po["eoff"]:
        print("[FAIL] entries_offset 变了"); ok = False
    if pn["hdrsz"] != po["hdrsz"]:
        print("[FAIL] header_size 变了"); ok = False

    # 尾部必须全零
    tail = new[pn["total"]:]
    if tail.strip(b"\0"):
        print("[FAIL] total_size 之后有非零数据（%d 字节）" % len(tail)); ok = False
    else:
        print("  尾部 %d 字节全零 OK" % len(tail))

    for i, (en, eo) in enumerate(zip(pn["ents"], po["ents"])):
        if en["id"] != eo["id"] or en["rev"] != eo["rev"] or en["custom"] != eo["custom"]:
            print("[FAIL] 条目 %d 的 id/rev/custom 被改了" % i); ok = False
        if en["off"] + en["size"] > pn["total"]:
            print("[FAIL] 条目 %d 越过 total_size" % i); ok = False
        if i + 1 < len(pn["ents"]) and en["off"] + en["size"] > pn["ents"][i + 1]["off"]:
            print("[FAIL] 条目 %d 与下一条目重叠" % i); ok = False
        blob = new[en["off"]:en["off"] + en["size"]]
        if not blob.startswith(b"\xd0\x0d\xfe\xed"):
            print("[FAIL] 条目 %d 不是 FDT" % i); ok = False
        dts = os.path.join(outdir, "new.%d.dts" % i)
        dtb = os.path.join(outdir, "new.%d.dtb" % i)
        open(dtb, "wb").write(blob)
        r = subprocess.run([dtc, "-I", "dtb", "-O", "dts", "-o", dts, dtb],
                           capture_output=True)
        print("  条目 %d: %d 字节（原 %d），dtc 反编译 %s"
              % (i, en["size"], eo["size"], "OK" if r.returncode == 0 else "FAIL"))
        if r.returncode != 0:
            ok = False
            continue

        txt = open(dts, encoding="utf-8", errors="replace").read()
        has_jeita = "mca_buckchg_jeita" in txt
        # mca_charger_thermal 必须 disabled
        for blk in txt.split("mca_charger_thermal {"):
            pass
        idx = txt.find("mca_charger_thermal {")
        stat = "n/a"
        if idx >= 0:
            seg = txt[idx:idx + 1200]
            if 'status = "disabled"' in seg:
                stat = "disabled"
            elif 'status = "ok"' in seg:
                stat = "ok(BAD)"
                ok = False
        print("     含 jeita 节点: %s；mca_charger_thermal: %s" % (has_jeita, stat))

        if has_jeita:
            # 检查 ffc_temp_low/high
            import re
            for prop, want in (("ffc_temp_low", "0x0"), ("ffc_temp_high", "0x38")):
                vals = re.findall(r"%s\s*=\s*<([^>]+)>" % prop, txt)
                good = [v for v in vals if v.strip().lower() == want]
                print("     %-14s 共 %d 处，等于 %s 的 %d 处" % (prop, len(vals), want, len(good)))
                if vals and not good:
                    print("       [WARN] 值不符合预期: %s" % vals[:4])
            # 不应再出现 0x37 的 ffc_temp_high
            bad = re.findall(r"ffc_temp_high\s*=\s*<0x37>", txt)
            if bad:
                print("       [WARN] 仍有 %d 处 ffc_temp_high = 0x37" % len(bad))

    print()
    print("=== 独立校验通过 ===" if ok else "=== 独立校验失败 ===")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
