#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 WebUI 的离线自测页面。

把 webroot 的 index.html 复制一份，注入一个假的 ksu 桥接，
喂入 monitor.sh 的真实输出（每次调用做小幅扰动，好让曲线有形状）。
仅开发期使用，不进仓库。

用法: python mkwebui_harness.py <模块目录> <输出目录> <monitor输出文件>
"""
import json
import os
import shutil
import sys

STUB = """<script>
(function () {
  var BASE = %s;
  var n = 0;

  function variant(txt, i) {
    var cap  = Math.min(100, 73 + Math.floor(i / 2));
    var temp = 352 + Math.round(Math.sin(i / 2.2) * 14) + i * 3;
    var cur  = 2810000 + Math.round(Math.sin(i / 1.7) * 720000);
    var vol  = 4110000 + i * 7000;
    return txt.replace(/^capacity=.*$/m, 'capacity=' + cap)
              .replace(/^temp_raw=.*$/m, 'temp_raw=' + temp)
              .replace(/^current_now=.*$/m, 'current_now=' + cur)
              .replace(/^voltage_now=.*$/m, 'voltage_now=' + vol);
  }

  window.__errors = [];
  window.onerror = function (m, s, l, c, err) {
    window.__errors.push((err && err.stack ? err.stack : m) + ' @' + l);
    return false;
  };

  window.ksu = {
    exec: function (cmd, opts, cb) {
      var i = n++;
      setTimeout(function () {
        try { window[cb](0, variant(BASE, i), ''); }
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

ERRBOX = """<pre id="__check" style="margin:12px;padding:10px;border-radius:10px;
background:#0d1117;border:1px solid #30363d;color:#7ee787;
font:11px/1.55 monospace;white-space:pre-wrap">check 未运行</pre>
<script>
(function () {
  function painted(c) {
    try {
      var ctx = c.getContext('2d');
      var d = ctx.getImageData(0, 0, c.width, c.height).data;
      var n = 0;
      for (var i = 3; i < d.length; i += 4) { if (d[i] > 0) n++; }
      return n;
    } catch (e) { return -1; }
  }
  function txt(id) {
    var e = document.getElementById(id);
    return e ? (e.textContent || '').trim() : '<缺失#' + id + '>';
  }
  function numish(s) { return /^-?\\d+(\\.\\d+)?$/.test(s); }

  function run() {
    var r = [], errs = window.__errors || [];
    function chk(name, cond, extra) {
      r.push((cond ? 'PASS ' : 'FAIL ') + name + (extra ? ' :: ' + extra : ''));
    }

    chk('js-errors', errs.length === 0, errs.join(' | '));

    var bn = document.getElementById('banner');
    chk('无错误横幅', bn && bn.classList.contains('hidden'),
        bn ? (bn.textContent || bn.className) : '缺失');

    chk('cap-有数值', numish(txt('capValue')), txt('capValue'));
    chk('power-有数值', numish(txt('powerValue')), txt('powerValue'));
    chk('temp-有数值', numish(txt('mTemp')), txt('mTemp'));
    chk('current-有数值', numish(txt('mCurrent')), txt('mCurrent'));
    chk('voltage-有数值', numish(txt('mVoltage')), txt('mVoltage'));
    chk('cycle-有数值', txt('mCycle') !== '--', txt('mCycle'));
    chk('health-已填', txt('mHealth') !== '--', txt('mHealth'));

    var chip = document.getElementById('statusChip');
    chk('状态含功率', /W$/.test(txt('statusChip')), txt('statusChip'));
    chk('状态着色', chip && /\\b(ok|warn|bad)\\b/.test(chip.className), chip && chip.className);
    chk('电源说明', txt('sourceNote').length > 3, txt('sourceNote'));

    var ring = document.getElementById('ringFg');
    var off = ring ? parseFloat(ring.style.strokeDashoffset) : 999;
    chk('电量环已填充', off < 326, 'dashoffset=' + off);

    var wr = document.getElementById('windowRange');
    var wm = document.getElementById('windowMarker');
    chk('温度窗口条有宽度', wr && parseFloat(wr.style.width) > 1, wr && wr.style.width);
    chk('温度标记可见', wm && wm.style.display !== 'none', wm && wm.style.left);
    chk('窗口轴标注', txt('axisLow') !== '—' && txt('axisHigh') !== '—',
        txt('axisLow') + ' ~ ' + txt('axisHigh'));

    var cp = painted(document.getElementById('chartPower'));
    var ct = painted(document.getElementById('chartTemp'));
    chk('功率曲线已绘制', cp > 100, 'pixels=' + cp);
    chk('温度曲线已绘制', ct > 100, 'pixels=' + ct);
    chk('曲线当前值', numish(txt('chartPowerNow')), txt('chartPowerNow'));

    var tl = document.getElementById('thermalList');
    chk('温度区列表非空', tl && tl.children.length > 0,
        tl ? tl.children.length + ' 行' : '无');

    chk('模块状态已填', txt('moduleChip') !== '—', txt('moduleChip'));
    chk('上次刷写已填', txt('kLastFlash') !== '—', txt('kLastFlash'));
    chk('分区已填', txt('kPart') !== '—', txt('kPart'));
    chk('备份已填', txt('kBackup') !== '—', txt('kBackup'));

    chk('原始数据已填', txt('rawDump').indexOf('capacity=') >= 0,
        (txt('rawDump').split('\\n').length) + ' 行');

    var doc = document.documentElement;
    chk('无横向溢出', doc.scrollWidth <= window.innerWidth + 1,
        'scrollWidth=' + doc.scrollWidth + ' innerWidth=' + window.innerWidth);

    var cards = document.querySelectorAll('.card');
    var zero = 0;
    for (var i = 0; i < cards.length; i++) {
      if (cards[i].getBoundingClientRect().height < 12) zero++;
    }
    chk('卡片都有高度', zero === 0, cards.length + ' 张，' + zero + ' 张异常');

    var fail = 0;
    for (var j = 0; j < r.length; j++) { if (r[j].indexOf('FAIL') === 0) fail++; }
    r.push('');
    r.push('总计 ' + r.length + ' 项，失败 ' + fail + ' 项');
    r.push('页面高度 ' + doc.scrollHeight + 'px');

    document.getElementById('__check').textContent = r.join('\\n');
  }

  setTimeout(run, 12000);
})();
</script>
"""


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 1
    moddir, outdir, monfile = sys.argv[1:4]

    src = os.path.join(moddir, "webroot")
    if os.path.isdir(outdir):
        shutil.rmtree(outdir)
    shutil.copytree(src, outdir)

    with open(monfile, encoding="utf-8") as fh:
        base = fh.read()

    index = os.path.join(outdir, "index.html")
    with open(index, encoding="utf-8") as fh:
        html = fh.read()

    html = html.replace('<script src="app.js"></script>',
                        STUB % json.dumps(base) +
                        '<script src="app.js"></script>' + ERRBOX)

    with open(index, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(html)

    print("harness: %s" % index)
    print("  注入 monitor 输出 %d 字节" % len(base))
    return 0


if __name__ == "__main__":
    sys.exit(main())
