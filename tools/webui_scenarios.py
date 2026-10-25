#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""WebUI 状态分支自测。

用不同的 monitor.sh 输出喂给同一个页面，检查状态文案/着色/温度越界等。
仅开发期使用，不进仓库。

用法: python webui_scenarios.py <模块目录> <沙盒目录> <Edge路径> <monitor样本>
"""
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# 场景测试需要「原样返回」，不能像 mkwebui_harness 那样每次扰动数值。
STUB = """<script>
(function () {
  var BASE = %s;
  window.__errors = [];
  window.onerror = function (m, s, l, c, err) {
    window.__errors.push((err && err.stack ? err.stack : m) + ' @' + l);
    return false;
  };
  window.ksu = {
    exec: function (cmd, opts, cb) {
      setTimeout(function () {
        try { window[cb](0, BASE, ''); }
        catch (e) { window.__errors.push('callback: ' + e); }
      }, 25);
    },
    moduleInfo: function () { return JSON.stringify({ id: 'dtbo_charge_unlock' }); },
    toast: function () {},
    fullScreen: function () {},
    enableEdgeToEdge: function () {},
    exit: function () {}
  };
})();
</script>
"""

REPORT = """<pre id="__check" style="margin:12px;padding:10px;border-radius:10px;
background:#0d1117;border:1px solid #30363d;color:#7ee787;
font:11px/1.55 monospace;white-space:pre-wrap">report 未运行</pre>
<script>
(function () {
  function txt(id) {
    var e = document.getElementById(id);
    return e ? (e.textContent || '').trim() : '';
  }
  setTimeout(function () {
    var bn = document.getElementById('banner');
    var mc = document.getElementById('moduleChip');
    var wm = document.getElementById('windowMarker');
    var r = [];
    r.push('errors=' + (window.__errors || []).length);
    r.push('banner=' + (bn && !bn.classList.contains('hidden') ? 'shown' : 'hidden'));
    r.push('bannerText=' + (bn ? (bn.textContent || '').trim() : ''));
    r.push('status=' + txt('statusChip'));
    r.push('statusClass=' + (document.getElementById('statusChip') || {}).className);
    r.push('power=' + txt('powerValue'));
    r.push('current=' + txt('mCurrent'));
    r.push('temp=' + txt('mTemp'));
    r.push('markerClass=' + (wm ? wm.className : ''));
    r.push('markerDisplay=' + (wm ? wm.style.display : ''));
    r.push('windowHint=' + txt('windowHint'));
    r.push('moduleChip=' + txt('moduleChip'));
    r.push('moduleClass=' + (mc ? mc.className : ''));
    r.push('applied=' + txt('kApplied'));
    r.push('applyBtn=' + txt('btnApply'));
    r.push('thermal=' + document.querySelectorAll('#thermalList li').length);
    document.getElementById('__check').textContent = r.join('\\n');
  }, 11000);
})();
</script>
"""


def setkv(text, key, value):
    """把某行的值替换掉；没有该行就追加。"""
    pat = re.compile(r"^%s=.*$" % re.escape(key), re.M)
    line = "%s=%s" % (key, value)
    if pat.search(text):
        return pat.sub(line, text)
    return text.rstrip("\n") + "\n" + line + "\n"


def drop_prefix(text, prefix):
    return "\n".join(l for l in text.split("\n") if not l.startswith(prefix)) + "\n"


def sc_charging(t):
    return t


def sc_discharge(t):
    t = setkv(t, "status", "Discharging")
    t = setkv(t, "current_now", "-1450000")
    t = setkv(t, "src.usb.online", "0")
    t = setkv(t, "src.list", "")
    return t


def sc_full(t):
    t = setkv(t, "status", "Full")
    t = setkv(t, "capacity", "100")
    t = setkv(t, "current_now", "120000")
    return t


def sc_hot(t):
    t = setkv(t, "temp_raw", "612")
    return t


def sc_halted(t):
    # 旧版本会写 state/halted 表示「自动回滚停用」。现在没有这个机制了，
    # 这个场景改成验证「残留的 halted 文件不会再把状态卡成已停用」。
    t = setkv(t, "state_halted", "1")
    return t


def sc_nobatt(t):
    t = setkv(t, "batt_dir", "")
    for k in ("capacity", "status", "temp_raw", "current_now", "voltage_now",
              "health", "cycle_count", "charge_counter", "power_now"):
        t = setkv(t, k, "")
    return t


def sc_cold(t):
    # 低于窗口下限：0℃ 以下，标记应判为越界
    t = setkv(t, "temp_raw", "-25")
    return t


def sc_safe(t):
    # 安全档：窗口收到 0~48℃，此时 50℃ 已经算越界
    t = setkv(t, "cfg_ffc_high", "48")
    t = setkv(t, "cfg_tier", "safe")
    t = setkv(t, "temp_raw", "500")
    return t


def sc_reapply(t):
    # 系统 OTA 之后分区被换回原厂：state_cur_head 与 state_last_head 对不上，
    # 页面应该提示「需重新应用」。
    t = setkv(t, "state_cur_head", "0" * 64)
    return t


SCENARIOS = [
    ("充电中", sc_charging, {
        "errors": "0", "banner": "hidden",
        "status_has": "充电中", "statusClass_has": "ok",
        "markerClass_not_has": "out",
        "moduleChip": "已生效", "moduleClass_has": "ok",
        "applied_has": "是",
    }),
    ("放电中", sc_discharge, {
        "errors": "0", "banner": "hidden",
        "status_has": "放电中",
        "current": "1.45",
        "markerClass_not_has": "out",
        "moduleChip": "已生效",
    }),
    ("已充满", sc_full, {
        "errors": "0", "status_has": "已充满", "statusClass_has": "ok",
        "temp": "35.2",
    }),
    ("极限档过热越界", sc_hot, {
        "errors": "0", "temp": "61.2",
        "markerClass_has": "out",
        "windowHint": "极限档 · 0~56℃ 全速",
    }),
    ("安全档 50℃ 越界", sc_safe, {
        "errors": "0", "temp": "50.0",
        "markerClass_has": "out",
        "windowHint": "安全档 · 0~48℃ 全速",
    }),
    ("OTA 后需重新应用", sc_reapply, {
        "errors": "0",
        "moduleChip": "需重新应用", "moduleClass_has": "warn",
        "applied_has": "否",
        "applyBtn": "运行修改",
    }),
    ("电池低于下限", sc_cold, {
        "errors": "0", "temp": "-2.5",
        "markerClass_has": "out",
    }),
    ("残留 halted 不再影响状态", sc_halted, {
        "errors": "0", "moduleChip": "已生效", "moduleClass_has": "ok",
    }),
    ("无电池节点", sc_nobatt, {
        "errors": "0", "banner": "shown", "status": "—",
        "markerDisplay": "none",
    }),
]


def build_harness(moddir, outdir, base, edge):
    import shutil
    src = os.path.join(moddir, "webroot")
    if os.path.isdir(outdir):
        shutil.rmtree(outdir)
    shutil.copytree(src, outdir)

    index = os.path.abspath(os.path.join(outdir, "index.html"))
    with open(index, encoding="utf-8") as fh:
        html = fh.read()
    html = html.replace('<script src="app.js"></script>',
                        STUB % json.dumps(base) +
                        '<script src="app.js"></script>' + REPORT)
    with open(index, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(html)

    url = "file:///" + index.replace("\\", "/")
    dom = os.path.join(outdir, "dom.html")
    prof = os.path.abspath(os.path.join(outdir, "profile"))
    with open(dom, "wb") as out:
        subprocess.run(
            [edge, "--headless=new", "--disable-gpu", "--no-first-run",
             "--no-default-browser-check", "--user-data-dir=" + prof,
             "--virtual-time-budget=15000", "--dump-dom", url],
            stdout=out, stderr=subprocess.DEVNULL)
    with open(dom, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def main():
    if len(sys.argv) < 5:
        print(__doc__)
        return 1
    moddir, sandbox, edge, sample = sys.argv[1:5]
    with open(sample, encoding="utf-8") as fh:
        base_text = fh.read()

    total_fail = 0
    for idx, (name, fn, exp) in enumerate(SCENARIOS):
        base = fn(base_text)
        # 目录名只用 ASCII：Edge 对非 ASCII 的输出路径会直接不写文件
        outdir = os.path.join(sandbox, "sc_%02d" % idx)
        html = build_harness(moddir, outdir, base, edge)

        m = re.search(r'(?s)<pre id="__check"[^>]*>(.*?)</pre>', html)
        if not m:
            print("[%s] 没有报告块" % name)
            total_fail += 1
            continue
        rep = {}
        for line in m.group(1).strip().split("\n"):
            if "=" in line:
                k, v = line.split("=", 1)
                rep[k.strip()] = v.strip()

        bad = []
        for k, want in exp.items():
            got = rep.get(k, "<缺失>")
            if k.endswith("_not_has"):
                real = rep.get(k[:-8], "")
                if want in real:
                    bad.append("%s 不该含 [%s]，实际 [%s]" % (k[:-8], want, real))
            elif k.endswith("_has"):
                real = rep.get(k[:-4], "")
                if want not in real:
                    bad.append("%s 期望含 [%s]，实际 [%s]" % (k[:-4], want, real))
            else:
                if got != want:
                    bad.append("%s 期望 [%s]，实际 [%s]" % (k, want, got))

        if bad:
            total_fail += len(bad)
            print("[FAIL] %s" % name)
            for b in bad:
                print("        %s" % b)
        else:
            print("[ ok ] %-12s status=%s temp=%s module=%s"
                  % (name, rep.get("status", ""), rep.get("temp", ""),
                     rep.get("moduleChip", "")))

    print()
    if total_fail:
        print("=== 场景自测失败：%d 项 ===" % total_fail)
        return 1
    print("=== 场景自测全部通过（%d 个场景）===" % len(SCENARIOS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
