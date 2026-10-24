#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把模块打包成 KernelSU / Magisk 可安装的 zip。

用法: python tools/package.py <模块目录> <输出zip>
"""
import os
import sys
import zipfile

# 打进包里的文件（相对模块根目录）
INCLUDE_FILES = [
    "module.prop",
    "customize.sh",
    "common.sh",
    "post-fs-data.sh",
    "service.sh",
    "action.sh",
    "restore.sh",
    "dump.sh",
    "monitor.sh",
    "chargelog.sh",
    "uninstall.sh",
    "config.conf",
    "README.md",
    "bin/dtc-aarch64",
    "ref/patch.sed",
    "ref/patch.list",
]

INCLUDE_DIRS = [
    "ref/expect",
    "webroot",
]

# 需要可执行权限的文件
EXEC_FILES = {
    "customize.sh", "post-fs-data.sh", "service.sh", "action.sh",
    "restore.sh", "dump.sh", "monitor.sh", "chargelog.sh", "uninstall.sh",
    "bin/dtc-aarch64",
}


def add_file(zf, moddir, rel):
    path = os.path.join(moddir, rel)
    info = zipfile.ZipInfo(rel)
    info.compress_type = zipfile.ZIP_DEFLATED
    if rel in EXEC_FILES:
        info.external_attr = (0o100755 << 16) | 0o20
    else:
        info.external_attr = (0o100644 << 16) | 0o20
    with open(path, "rb") as fh:
        zf.writestr(info, fh.read())
    return os.path.getsize(path)


TEXT_EXTS = (".sh", ".prop", ".conf", ".md", ".txt", ".list", ".sed",
             ".html", ".css", ".js")

# 这些文件会被设备的 sh 直接执行，行尾必须是 LF，否则设备上必然报语法错误。
# 其余文本文件（md/html/css/js）CRLF 只是难看，不至于崩，所以只提示不阻断。
STRICT_EOL_EXTS = (".sh", ".prop", ".conf", ".list", ".sed")


def check_text(rel, data):
    """打包前的硬性检查。

    这三类问题都会让设备上的 sh 直接崩掉，且很难从安装日志看出原因：
      * CRLF 行尾   -> `case x in\\r` 报 syntax error: expecting "in"
      * UTF-8 BOM   -> 第一行 `#!/system/bin/sh` 失效
      * 非法 UTF-8  -> 中文注释变成乱码，可能吞掉换行符
    """
    errs = []
    if data[:3] == b"\xef\xbb\xbf":
        errs.append("有 UTF-8 BOM")
    if b"\r" in data:
        n = data.count(b"\r")
        if rel.endswith(STRICT_EOL_EXTS):
            errs.append("有 %d 处 CR（CRLF 行尾）" % n)
        else:
            print("[提示] %s: 有 %d 处 CR（不影响运行，建议统一成 LF）" % (rel, n))
    if b"\x00" in data:
        errs.append("有 NUL 字节")
    try:
        data.decode("utf-8")
    except UnicodeDecodeError as exc:
        errs.append("不是合法 UTF-8（%s）" % exc)
    return errs


def walk_dir(moddir, rel_dir):
    """递归列出目录下所有文件（相对模块根的路径），按路径排序。"""
    out = []
    full = os.path.join(moddir, rel_dir)
    for root, dirs, files in os.walk(full):
        dirs.sort()
        for name in sorted(files):
            p = os.path.join(root, name)
            out.append(os.path.relpath(p, moddir).replace(os.sep, "/"))
    return out


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    moddir, outzip = sys.argv[1], sys.argv[2]

    # 汇总要打包的文件：显式列表 + 目录递归内容
    entries = list(INCLUDE_FILES)
    for d in INCLUDE_DIRS:
        entries.extend(walk_dir(moddir, d))

    missing = [f for f in entries if not os.path.isfile(os.path.join(moddir, f))]
    if missing:
        print("缺少文件: %s" % ", ".join(missing))
        return 1

    # KernelSU 只认 webroot/index.html 作为入口
    if not os.path.isfile(os.path.join(moddir, "webroot", "index.html")):
        print("缺少 webroot/index.html，KernelSU 无法打开 WebUI")
        return 1

    # ---- 打包前先全部检查一遍，有问题直接失败，不生成 zip ----
    bad = 0
    for rel in entries:
        if not rel.endswith(TEXT_EXTS):
            continue
        with open(os.path.join(moddir, rel), "rb") as fh:
            errs = check_text(rel, fh.read())
        if errs:
            print("[文件有问题] %s: %s" % (rel, "；".join(errs)))
            bad += 1
    if bad:
        print("\n发现 %d 个文件存在编码/行尾问题，已中止打包。" % bad)
        return 1

    os.makedirs(os.path.dirname(outzip) or ".", exist_ok=True)
    total = 0
    count = 0
    with zipfile.ZipFile(outzip, "w", zipfile.ZIP_DEFLATED) as zf:
        for rel in entries:
            total += add_file(zf, moddir, rel)
            count += 1

    print("已生成 %s" % outzip)
    print("  条目 %d 个，原始大小 %.1f KB，压缩后 %.1f KB"
          % (count, total / 1024.0, os.path.getsize(outzip) / 1024.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
