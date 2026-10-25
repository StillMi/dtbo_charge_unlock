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
  var LOGS = %s;
  var SESS = %s;
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

  /* 按命令分派：列表 / 单个会话 / 实时采集 */
  function fixture(cmd, i) {
    if (cmd.indexOf('--logs') >= 0) return LOGS;
    if (cmd.indexOf('--log ') >= 0) return SESS;
    return variant(BASE, i);
  }

  window.__errors = [];
  window.__calls = [];
  window.onerror = function (m, s, l, c, err) {
    window.__errors.push((err && err.stack ? err.stack : m) + ' @' + l);
    return false;
  };

  window.ksu = {
    exec: function (cmd, opts, cb) {
      var i = n++;
      window.__calls.push(cmd);
      setTimeout(function () {
        try { window[cb](0, fixture(cmd, i), ''); }
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
    chk('横幅不是错误', !bn || !/\\berr\\b/.test(bn.className),
        bn ? bn.className : '缺失');

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
    chk('分区一致已判定', txt('kApplied') !== '—', txt('kApplied'));
    chk('备份已填', txt('kBackup') !== '—', txt('kBackup'));

    var ab = document.getElementById('btnApply');
    chk('运行修改按钮可见',
        ab && txt('btnApply') === '运行修改'
           && ab.getBoundingClientRect().height > 20,
        ab ? txt('btnApply') + ' h=' + Math.round(ab.getBoundingClientRect().height) : '缺失');
    chk('确认框默认隐藏',
        document.getElementById('confirm').classList.contains('hidden'),
        document.getElementById('confirm').className);

    /* ---- 「运行修改」交互 ---- */
    var ap = window.__apply || {};
    chk('点按钮弹出确认框', ap.opened === true, 'opened=' + ap.opened);
    chk('确认前不调用刷写', ap.calledBefore === false, 'calledBefore=' + ap.calledBefore);
    chk('确认后调用 action.sh', ap.called === true,
        (ap.calls || []).join(' | '));
    chk('执行后回显输出', txt('applyOut').length > 0,
        txt('applyOut').slice(0, 40));
    chk('按钮已恢复', txt('btnApply') === '运行修改', txt('btnApply'));
    chk('确认框已关闭',
        document.getElementById('confirm').classList.contains('hidden'),
        document.getElementById('confirm').className);

    chk('展开后原始数据已填', (window.__raw || {}).opened === true,
        'len=' + ((window.__raw || {}).len));

    /* ---- 充电日志标签页 ---- */
    var L = window.__log || {};
    chk('标签页有两个', L.tabs === 2, 'tabs=' + L.tabs);
    chk('切到充电日志', L.switched === true, 'switched=' + L.switched);
    chk('日志状态已填', /记录中|未记录/.test(L.chip || ''), L.chip);
    chk('日志采样间隔已填', /^\\d+$/.test(L.intv || ''), L.intv);
    chk('记录中不显示启动按钮', L.startHidden === true, 'hidden=' + L.startHidden);
    chk('日志列表有行', (L.rows || 0) >= 2, 'rows=' + L.rows);
    chk('列表显示峰值功率', /峰值 \\d/.test(L.listSub || ''), L.listSub);
    chk('打开会话', L.opened === true && L.title !== '—', L.title);
    chk('会话统计已填', (L.stats || 0) >= 9, 'rows=' + L.stats);
    chk('会话含平均功率', /平均功率/.test(L.statsText || ''), '');
    chk('会话含充电器温度', /充电器/.test(L.statsText || ''), '');
    chk('会话含采样间隔', /秒一点/.test(L.statsText || ''), '');
    chk('功率曲线已绘制', (L.painted || 0) > 100, 'pixels=' + L.painted);
    chk('电压曲线已绘制', (L.paintedV || 0) > 100, 'pixels=' + L.paintedV);
    chk('电流曲线已绘制', (L.paintedC || 0) > 100, 'pixels=' + L.paintedC);
    chk('温度曲线已绘制', (L.paintedT || 0) > 100, 'pixels=' + L.paintedT);
    chk('会话峰值已填', /^\\d/.test(L.peaks || ''), L.peaks);
    chk('返回列表', L.back === true, 'back=' + L.back);

    /* ---- 性能：重复采集不该重建 DOM ---- */
    chk('温度列表不重建节点', L.thermalSame === true, 'same=' + L.thermalSame);
    chk('折叠时不生成原始数据', L.rawKept === true, 'len=' + L.rawLen);

    var doc = document.documentElement;
    chk('无横向溢出', doc.scrollWidth <= window.innerWidth + 1,
        'scrollWidth=' + doc.scrollWidth + ' innerWidth=' + window.innerWidth);

    var cards = document.querySelectorAll('.card');
    var zero = 0, vis = 0;
    for (var i = 0; i < cards.length; i++) {
      if (cards[i].closest('.hidden')) continue;   /* 隐藏标签页里的卡片不算 */
      vis++;
      if (cards[i].getBoundingClientRect().height < 12) zero++;
    }
    chk('卡片都有高度', zero === 0, vis + ' 张可见，' + zero + ' 张异常');

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

# 原始数据折叠时才省性能：展开一次确认它会填，然后再折回去
RAW = """<script>
(function () {
  var R = window.__raw = { opened: false, len: 0, closed: false };
  setTimeout(function () {
    var det = document.getElementById('rawDump').parentNode;
    det.open = true;
    setTimeout(function () {
      var raw = document.getElementById('rawDump');
      R.len = (raw.textContent || '').length;
      R.opened = (raw.textContent || '').indexOf('capacity=') >= 0;
      det.open = false;
      R.closed = true;
    }, 2600);
  }, 3200);
})();
</script>
"""

# 「运行修改」交互：点按钮 → 弹确认框 → 确认后才 exec action.sh
APPLY = """<script>
(function () {
  setTimeout(function () {
    var ab = document.getElementById('btnApply');
    var modal = document.getElementById('confirm');
    var n0 = (window.__calls || []).length;
    var ap = { opened: false, called: false, calledBefore: false, calls: [] };
    window.__apply = ap;

    ab.click();
    ap.opened = !modal.classList.contains('hidden');
    ap.calledBefore = (window.__calls || []).length > n0;

    document.getElementById('confirmYes').click();
    setTimeout(function () {
      ap.calls = (window.__calls || []).slice(n0);
      for (var i = 0; i < ap.calls.length; i++) {
        if (/action\\.sh/.test(ap.calls[i])) ap.called = true;
      }
      window.__applyDone = true;
    }, 1600);
  }, 10200);
})();
</script>
"""

# 充电日志标签页：切过去 → 列表 → 打开一个会话 → 返回列表 → 切回实时
TABS = """<script>
(function () {
  var L = window.__log = { tabs: 0, switched: false, chip: '', rows: 0,
                           opened: false, title: '', stats: 0, painted: 0,
                           paintedV: 0, paintedC: 0, paintedT: 0,
                           peaks: '', back: false, done: false, listSub: '',
                           statsText: '', intv: '', startHidden: false,
                           thermalSame: false, rawKept: false, rawLen: 0 };

  function txt(id) {
    var e = document.getElementById(id);
    return e ? (e.textContent || '').trim() : '';
  }
  function hidden(id) {
    var e = document.getElementById(id);
    return !e || e.className.indexOf('hidden') >= 0;
  }
  function painted(c) {
    if (!c) return -1;
    try {
      var d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
      var n = 0;
      for (var i = 3; i < d.length; i += 4) { if (d[i] > 0) n++; }
      return n;
    } catch (e) { return -1; }
  }

  function step1() {
    var btns = document.querySelectorAll('[data-tab]');
    L.tabs = btns.length;
    var logsBtn = null, liveBtn = null;
    for (var i = 0; i < btns.length; i++) {
      var t = btns[i].getAttribute('data-tab');
      if (t === 'logs') logsBtn = btns[i];
      if (t === 'live') liveBtn = btns[i];
    }
    L.hasLive = !!liveBtn;
    if (!logsBtn) return;
    logsBtn.click();

    setTimeout(function () {
      L.switched = !hidden('viewLogs') && hidden('viewLive');
      L.chip = txt('logStateChip');
      L.intv = txt('logInterval');
      L.startHidden = hidden('logStartBox');
      var ul = document.getElementById('logList');
      L.rows = ul ? ul.children.length : 0;
      L.listSub = (ul && ul.children[0]) ? txt2(ul.children[0]) : '';

      var first = ul && ul.children[0];
      if (!first || first.className === 'empty') return;
      first.click();

      setTimeout(function () {
        L.opened = !hidden('logDetail');
        L.title = txt('logTitle');
        var st = document.getElementById('logStats');
        L.stats = st ? st.children.length : 0;
        L.statsText = st ? (st.textContent || '') : '';
        L.painted  = painted(document.getElementById('logChartPower'));
        L.paintedV = painted(document.getElementById('logChartVolt'));
        L.paintedC = painted(document.getElementById('logChartCur'));
        L.paintedT = painted(document.getElementById('logChartTemp'));
        L.peaks = txt('logPowerPeak') + '/' + txt('logVoltPeak') + '/'
                + txt('logCurPeak') + '/' + txt('logTempPeak');

        document.getElementById('btnLogBack').click();

        setTimeout(function () {
          L.back = hidden('logDetail');
          if (liveBtn) liveBtn.click();
          setTimeout(checkPerf, 300);
        }, 500);
      }, 600);
    }, 700);
  }

  function txt2(el) { return el ? (el.textContent || '').trim() : ''; }

  /* 性能断言：连续两次采集后，温度列表的节点还是同一批（没有重建），
     折叠的原始数据也没被反复重写。 */
  function checkPerf() {
    var ul = document.getElementById('thermalList');
    var raw = document.getElementById('rawDump');
    var before = ul ? ul.children[0] : null;
    L.rawLen = raw ? (raw.textContent || '').length : -1;

    var rawWrites = 0;
    if (window.MutationObserver && raw) {
      var mo = new MutationObserver(function (recs) { rawWrites += recs.length; });
      mo.observe(raw, { childList: true, characterData: true, subtree: true });
      window.__mo = mo;
    }

    /* 采集间隔 2 秒，等 2.6 秒至少跨过一次轮询 */
    setTimeout(function () {
      if (window.__mo) window.__mo.disconnect();
      var after = ul ? ul.children[0] : null;
      L.thermalSame = (before === after) && before !== null;
      L.rawWrites = rawWrites;
      L.rawKept = (rawWrites === 0);
      L.done = true;
    }, 2600);
  }

  setTimeout(step1, 6500);
})();
</script>
"""


def fake_fixtures(now):
    """造两份假数据：monitor.sh --logs 的会话列表、--log 的采样点。"""
    import time as _t

    # (start, end, aborted, samples, cap0, cap1, tmax, pmax_mw, imax_ua, vmax_uv)
    specs = [
        (now - 3 * 86400, now - 3 * 86400 + 3900, 0, 78, 31, 58, 342,
         68400, 3200000, 9240000),
        (now - 2 * 86400, now - 2 * 86400 + 5400, 0, 108, 22, 74, 361,
         71200, 3350000, 9280000),
        (now - 7200,      None,                   0, 24, 55, 64, 348,
         65100, 3100000, 9200000),
    ]

    def name_of(st):
        return _t.strftime("%Y%m%d-%H%M%S", _t.localtime(st)) + ".log"

    rows = ["log_dir=/data/adb/dtbo_charge_unlock/chargelog",
            "log_interval=10",
            "log_count=%d" % len(specs),
            "log_current=" + name_of(specs[2][0]),
            "log_running=1"]
    for i, sp in enumerate(specs):
        st, en, ab, sm, c0, c1, tmax, pmw, imax, vmax = sp
        rows += [
            "log.%d.name=%s" % (i, name_of(st)),
            "log.%d.start=%d" % (i, st),
            "log.%d.end=%s" % (i, "" if en is None else en),
            "log.%d.aborted=%d" % (i, ab),
            "log.%d.samples=%d" % (i, sm),
            "log.%d.cap0=%d" % (i, c0),
            "log.%d.cap1=%d" % (i, c1),
            "log.%d.temp_max=%d" % (i, tmax),
            "log.%d.pmax_mw=%d" % (i, pmw),
            "log.%d.cur_max=%d" % (i, imax),
            "log.%d.volt_max=%d" % (i, vmax),
            "log.%d.cnt0=2600000" % i,
            "log.%d.cnt1=%d" % (i, 2600000 + sm * 20000),
        ]
    rows.append("log.list_count=%d" % len(specs))

    st, en, ab, sm, c0, c1, tmax, pmw, imax, vmax = specs[0]
    pts = 60
    srows = ["session.name=" + name_of(st),
             "session.start=%d" % st,
             "session.end=%d" % en,
             "session.aborted=%d" % ab]
    for i in range(pts):
        frac = i / float(pts - 1)
        cap = int(round(c0 + (c1 - c0) * frac))
        temp = int(round(310 + 40 * frac + 9 * abs((i % 10) - 5)))
        cur = int(round(2400000 + 900000 * (0.5 + 0.5 * ((i * 7) % 13) / 12.0)))
        volt = int(round(4050000 + 120000 * frac))
        cnt = int(round(2600000 + 1500000 * frac))
        pw = int(round(abs(cur) / 1e6 * volt))
        uv = int(round(9000000 + 60000 * frac))
        ui = int(round(3000000 + 100000 * frac))
        chg = int(round(370 + 25 * frac))
        # 11 列 v2 格式
        srows.append("session.s.%d=%d,%d,%d,%d,%d,%d,Charging,%d,%d,%d,%d"
                     % (i, st + i * 10, cap, temp, cur, volt, cnt,
                        pw, uv, ui, chg))
    srows.append("session.count=%d" % pts)

    return "\n".join(rows) + "\n", "\n".join(srows) + "\n"


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

    import time as _t
    logs, sess = fake_fixtures(int(_t.time()))

    index = os.path.join(outdir, "index.html")
    with open(index, encoding="utf-8") as fh:
        html = fh.read()

    html = html.replace('<script src="app.js"></script>',
                        STUB % (json.dumps(base), json.dumps(logs), json.dumps(sess)) +
                        '<script src="app.js"></script>' + ERRBOX + RAW + APPLY + TABS)

    with open(index, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(html)

    print("harness: %s" % index)
    print("  注入 monitor 输出 %d 字节" % len(base))
    print("  注入日志假数据 %d / 会话 %d 字节" % (len(logs), len(sess)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
