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
  /* 兜底「只拿文件名」那一级的假数据，默认跟 LOGS 一样（正常情况不会走到） */
  var NAMES = LOGS;
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

  /* 按命令分派：列表 / 只要文件名 / 单个会话 / 实时采集 */
  function fixture(cmd, i) {
    if (cmd.indexOf('--names') >= 0) return NAMES;
    if (cmd.indexOf('--logs') >= 0) return LOGS;
    if (cmd.indexOf('--log ') >= 0) return SESS;
    return variant(BASE, i);
  }

  /* 断言「空日志列表不能卡在读取中」时要把 LOGS 换成空的，所以留个口子 */
  window.__setLogs = function (v) { LOGS = v; };
  window.__setNames = function (v) { NAMES = v; };

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

    /* ---- 系统温控卡片（样本里 Scene 是 danger = 丧心病狂）---- */
    chk('温控档位已填', txt('kScene') !== '—', txt('kScene'));
    chk('温控档位认得出丧心病狂', /丧心病狂/.test(txt('kScene')), txt('kScene'));
    chk('温控状态标签', txt('sceneChip') === '已放开', txt('sceneChip'));
    chk('温控引擎已填', txt('kThermalEngine') !== '—', txt('kThermalEngine'));
    chk('温控说明已填', txt('sceneHint').length > 6, txt('sceneHint').slice(0, 30));
    chk('档位正确时顶部不告警',
        document.getElementById('sceneBanner').classList.contains('hidden'),
        document.getElementById('sceneBanner').className);

    /* ---- 恢复原厂卡片 ---- */
    var rb = document.getElementById('btnRestore');
    chk('恢复原厂按钮可见',
        rb && txt('btnRestore') === '恢复原厂 dtbo'
           && rb.getBoundingClientRect().height > 20,
        rb ? txt('btnRestore') + ' h=' + Math.round(rb.getBoundingClientRect().height) : '缺失');
    chk('备份文件名已填', txt('kRestoreFile') !== '—', txt('kRestoreFile'));
    chk('恢复状态标签', txt('restoreChip') === '可恢复', txt('restoreChip'));
    chk('恢复说明提到会改分区', /改分区/.test(txt('restoreHint')),
        txt('restoreHint').slice(0, 40));
    var rs = window.__restore || {};
    chk('点恢复弹出确认框', rs.opened === true, 'opened=' + rs.opened);
    chk('确认前不写分区', rs.calledBefore === false, 'calledBefore=' + rs.calledBefore);
    chk('确认后调用 restore.sh', rs.called === true,
        (rs.calls || []).join(' | '));
    chk('恢复按钮已复位', txt('btnRestore') === '恢复原厂 dtbo', txt('btnRestore'));

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
    chk('日志状态已填', /记录中|未在记录/.test(L.chip || ''), L.chip);
    chk('日志状态说明已填', (L.hint || '').length > 6, L.hint);
    chk('记录中说明含文件名', /正在记录这次充电/.test(L.hint || ''), L.hint);
    chk('日志采样间隔已填', /^\\d+$/.test(L.intv || ''), L.intv);
    chk('记录中不显示启动按钮', L.startHidden === true, 'hidden=' + L.startHidden);
    chk('日志列表有行', (L.rows || 0) >= 2, 'rows=' + L.rows);
    chk('列表显示峰值功率', /峰值 \\d/.test(L.listSub || ''), L.listSub);
    chk('未结束会话显示进行中', /进行中/.test(L.listSub || ''), L.listSub);
    /* 空列表：后台在跑但一次都没记过 —— 不能停在「读取中…」 */
    chk('空列表不卡在读取中',
        L.emptyRows === 1 && /还没有记录/.test(L.emptyText || '')
        && !/读取中/.test(L.emptyText || ''),
        (L.emptyRows + '|' + (L.emptyText || '')).slice(0, 70));
    chk('空列表说明没插充电器', /没插充电器/.test(L.emptyHint || ''), L.emptyHint);
    chk('空列表状态标签', /记录中|未在记录/.test(L.emptyChip || ''), L.emptyChip);
    /* 采集进程卡住：不能继续显示「正在记录」，要说出「卡住了」并给重启入口 */
    chk('卡住时标签是未在记录', (L.stallChip || '') === '未在记录', L.stallChip);
    chk('卡住时说明提到心跳', /卡住|心跳/.test(L.stallHint || ''), L.stallHint);
    chk('卡住时显示启动按钮', L.stallStartHidden === false, 'hidden=' + L.stallStartHidden);
    /* 「有 N 个日志文件，只解析出 M 条」这句话要分清是被中断还是真读不出来 */
    chk('半截输出说成被中断', /中断/.test(L.partText || ''), (L.partText || '').slice(0, 40));
    chk('半截输出不说成没有记录', !/还没有记录/.test(L.partText || ''),
        (L.partText || '').slice(0, 40));
    chk('真读不出说成读不出来',
        /读不出来/.test(L.mismText || '') && /删掉/.test(L.mismText || ''),
        (L.mismText || '').slice(0, 40));
    chk('条数对不上不说成文件坏了',
        !/写坏/.test(L.mismText || ''), (L.mismText || '').slice(0, 40));
    chk('空会话列表说成空文件',
        /空文件/.test(L.zeroText || ''), (L.zeroText || '').slice(0, 40));
    /* 真机上「跑完了、没坏文件、却一条都解析不出来」时要退到只列文件名，
       不能给一个空列表让用户以为日志全丢了 */
    chk('解析不出内容时仍列出文件名', (L.namesRows || 0) >= 2, 'rows=' + L.namesRows);
    chk('只读到文件名时说清楚了',
        /文件名/.test(L.namesHint || ''), (L.namesHint || '').slice(0, 40));
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

  /* 等「恢复原厂」那轮也跑完再出报告；最多再等 20 秒，防止某一轮卡住时
     整个 harness 什么都不输出（宁可报失败也不要没报告） */
  setTimeout(function () {
    var waited = 0;
    var t = setInterval(function () {
      waited += 200;
      if (window.__restoreDone || waited >= 20000) { clearInterval(t); run(); }
    }, 200);
  }, 19000);
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
                           emptyRows: -1, emptyText: '', emptyHint: '',
                           emptyChip: '', hint: '', thermalSame: false,
                           stallHint: '', stallChip: '', stallStartHidden: null,
                           partText: '', mismText: '', zeroText: '',
                           namesRows: -1, namesText: '', namesHint: '',
                           rawKept: false, rawLen: 0 };

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

  var logsBtn = null, liveBtn = null;

  function step1() {
    var btns = document.querySelectorAll('[data-tab]');
    L.tabs = btns.length;
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
      L.hint = txt('logHintText');
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
          /* 性能断言必须紧接在回到实时页之后跑，窗口里不能有别的刷新
             （「运行修改」收尾那次 refresh(true) 会把时间窗污染掉）。 */
          setTimeout(checkPerf, 300);
        }, 500);
      }, 600);
    }, 700);
  }

  function txt2(el) { return el ? (el.textContent || '').trim() : ''; }

  /* 第三轮：日志列表换成空的（后台在跑、没插充电器、一次都没记过），
     看列表会不会卡在「读取中…」。这是用户实际遇到的那个状态。 */
  function phaseEmpty(logsBtn, liveBtn) {
    window.__setLogs('log_dir=/data/adb/dtbo_charge_unlock/chargelog\\n'
      + 'log_interval=10\\nlog_dir_ok=1\\nlog_count=0\\nlog_current=\\n'
      + 'log_running=1\\nlog_beat=4\\nlog_plugged=0\\nlog.list_count=0\\n'
      + 'log_list_done=1\\n');
    if (liveBtn) liveBtn.click();
    setTimeout(function () {
      if (logsBtn) logsBtn.click();
      setTimeout(function () {
        var u2 = document.getElementById('logList');
        L.emptyRows = u2 ? u2.children.length : -1;
        L.emptyText = (u2 && u2.children[0]) ? txt2(u2.children[0]) : '';
        L.emptyHint = txt('logHintText');
        L.emptyChip = txt('logStateChip');
        if (liveBtn) liveBtn.click();
        phaseStalled(logsBtn, liveBtn);
      }, 900);
    }, 400);
  }

  /* 第四轮：采集进程卡住了（.pid 还在、但心跳很久没更新）。
     用户看到的就是「一直卡在记录中不刷新」，页面必须说清楚是卡住，
     而不是继续显示「正在记录」。 */
  function phaseStalled(logsBtn, liveBtn) {
    /* 进程卡住时，之前记好的会话照样读得出来 —— 不能因为进程死了就把
       列表清空，那会让人以为历史也没了。 */
    window.__setLogs('log_dir=/data/adb/dtbo_charge_unlock/chargelog\\n'
      + 'log_interval=10\\nlog_dir_ok=1\\nlog_count=2\\nlog_current=\\n'
      + 'log_running=0\\nlog_beat=600\\nlog_plugged=0\\n'
      + 'log.list_count=2\\nlog_list_done=1\\n'
      + 'log.0.name=20251002-120000.log\\nlog.0.start=1759300000\\n'
      + 'log.0.end=1759303600\\nlog.0.aborted=0\\nlog.0.samples=30\\n'
      + 'log.0.cap0=20\\nlog.0.cap1=70\\nlog.0.temp_max=352\\n'
      + 'log.1.name=20251001-120000.log\\nlog.1.start=1759200000\\n'
      + 'log.1.end=1759203600\\nlog.1.aborted=0\\nlog.1.samples=30\\n'
      + 'log.1.cap0=30\\nlog.1.cap1=80\\nlog.1.temp_max=350\\n');
    setTimeout(function () {
      if (logsBtn) logsBtn.click();
      setTimeout(function () {
        L.stallHint = txt('logHintText');
        L.stallChip = txt('logStateChip');
        L.stallStartHidden = (function () {
          var b = document.getElementById('logStartBox');
          return b ? b.classList.contains('hidden') : null;
        })();
        if (liveBtn) liveBtn.click();
        phasePartial(logsBtn, liveBtn);
      }, 900);
    }, 400);
  }

  /* 第五轮：空文件 / 坏文件的说法。
     用户在真机上看到过「有 6 个日志文件，只解析出 0 条」，必须先弄清楚是哪一种：
       a) 脚本被中断/超时，只吐了半截（没有 log_list_done 哨兵）
       b) 有哨兵，并且点名了读不出来的文件（log_bad）
       c) 有哨兵、没有坏文件，但某个会话一个采样点都没有（0 字节文件）
     三种要给出不同的说法，不能只甩一句数字、更不能一律说「文件写坏了」。 */
  function phasePartial(logsBtn, liveBtn) {
    /* a) 没有哨兵 = 半截 */
    window.__setLogs('log_dir=/data/adb/dtbo_charge_unlock/chargelog\\n'
      + 'log_interval=10\\nlog_dir_ok=1\\nlog_count=6\\nlog_current=\\n'
      + 'log_running=0\\nlog_beat=-1\\nlog_plugged=0\\nlog.list_count=0\\n');
    if (liveBtn) liveBtn.click();
    setTimeout(function () {
      if (logsBtn) logsBtn.click();
      setTimeout(function () {
        var u = document.getElementById('logList');
        L.partText = (u && u.children[0]) ? txt2(u.children[0]) : '';
        if (liveBtn) liveBtn.click();

        /* b) 有哨兵 + 点名了坏文件 = 读不出来 */
        window.__setLogs('log_dir=/data/adb/dtbo_charge_unlock/chargelog\\n'
          + 'log_interval=10\\nlog_dir_ok=1\\nlog_count=6\\nlog_current=\\n'
          + 'log_running=0\\nlog_beat=-1\\nlog_plugged=0\\nlog.list_count=0\\n'
          + 'log_list_done=1\\nlog_bad= 20251001-120000.log 20251002-120000.log\\n');
        setTimeout(function () {
          if (logsBtn) logsBtn.click();
          setTimeout(function () {
            var u2 = document.getElementById('logList');
            L.mismText = (u2 && u2.children[0]) ? txt2(u2.children[0]) : '';
            if (liveBtn) liveBtn.click();

            /* c) 会话在，但一个采样点都没有 = 空文件 */
            window.__setLogs('log_dir=/data/adb/dtbo_charge_unlock/chargelog\\n'
              + 'log_interval=10\\nlog_dir_ok=1\\nlog_count=1\\nlog_current=\\n'
              + 'log_running=0\\nlog_beat=-1\\nlog_plugged=0\\n'
              + 'log.list_count=1\\nlog_list_done=1\\n'
              + 'log.0.name=20251001-120000.log\\nlog.0.start=1759300000\\n'
              + 'log.0.end=0\\nlog.0.aborted=0\\nlog.0.samples=0\\n'
              + 'log.0.cap0=0\\nlog.0.cap1=0\\nlog.0.temp_max=0\\n');
            setTimeout(function () {
              if (logsBtn) logsBtn.click();
              setTimeout(function () {
                var u3 = document.getElementById('logList');
                var li = u3 && u3.children[0];
                L.zeroText = li ? txt2(li) : '';
                if (liveBtn) liveBtn.click();

                /* d) 跑完了、没有坏文件、却一条都解析不出来
                      → 退到「只要文件名」，列表不能是空的 */
                window.__setLogs('log_dir=/data/adb/dtbo_charge_unlock/chargelog\\n'
                  + 'log_interval=10\\nlog_dir_ok=1\\nlog_count=6\\nlog_current=\\n'
                  + 'log_running=0\\nlog_beat=-1\\nlog_plugged=0\\n'
                  + 'log.list_count=0\\nlog_list_done=1\\nlog_scan=6/1/0/0\\n');
                window.__setNames('log_dir=/data/adb/dtbo_charge_unlock/chargelog\\n'
                  + 'log_interval=10\\nlog_dir_ok=1\\nlog_count=6\\nlog_current=\\n'
                  + 'log_running=0\\nlog_beat=-1\\nlog_plugged=0\\n'
                  + 'log.0.name=20251002-120000.log\\nlog.0.samples=0\\n'
                  + 'log.1.name=20251001-120000.log\\nlog.1.samples=0\\n'
                  + 'log.list_count=2\\nlog_list_done=1\\n');
                setTimeout(function () {
                  if (logsBtn) logsBtn.click();
                  setTimeout(function () {
                    var u4 = document.getElementById('logList');
                    L.namesRows = u4 ? u4.children.length : -1;
                    L.namesText = (u4 && u4.children[0]) ? txt2(u4.children[0]) : '';
                    var h4 = document.getElementById('logHintText');
                    L.namesHint = h4 ? txt2(h4) : '';
                    if (liveBtn) liveBtn.click();
                    L.done = true;
                  }, 900);
                }, 400);
              }, 900);
            }, 400);
          }, 900);
        }, 400);
      }, 900);
    }, 400);
  }

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
      phaseEmpty(logsBtn, liveBtn);
    }, 2600);
  }

  setTimeout(step1, 6500);
})();
</script>
"""


# 「恢复原厂」交互：等标签页那轮跑完，再点按钮 → 弹确认框 → 确认后才 exec restore.sh
RESTORE = """<script>
(function () {
  function go() {
    var rb = document.getElementById('btnRestore');
    var modal = document.getElementById('confirm');
    var rs = { opened: false, called: false, calledBefore: false, calls: [] };
    window.__restore = rs;
    if (!rb) { window.__restoreDone = true; return; }

    var n0 = (window.__calls || []).length;
    rb.click();
    rs.opened = !modal.classList.contains('hidden');
    rs.calledBefore = (window.__calls || []).length > n0;

    document.getElementById('confirmYes').click();
    setTimeout(function () {
      rs.calls = (window.__calls || []).slice(n0);
      for (var i = 0; i < rs.calls.length; i++) {
        if (/restore\\.sh/.test(rs.calls[i])) rs.called = true;
      }
      window.__restoreDone = true;
    }, 1600);
  }
  /* 等充电日志那轮（含空列表）和「运行修改」那轮都彻底跑完再动，
     避免两个确认框同时挂着互相踩 */
  var t = setInterval(function () {
    if (window.__log && window.__log.done && window.__applyDone) { clearInterval(t); go(); }
  }, 120);
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
            "log_dir_ok=1",
            "log_count=%d" % len(specs),
            "log_current=" + name_of(specs[2][0]),
            "log_running=1",
            "log_beat=3",
            "log_plugged=1"]
    # monitor.sh --logs 是 ls -1t，最新的排最前，假数据也要照这个顺序
    order = [2, 1, 0]
    for i, idx in enumerate(order):
        st, en, ab, sm, c0, c1, tmax, pmw, imax, vmax = specs[idx]
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
    rows.append("log_list_done=1")

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
                        '<script src="app.js"></script>' + ERRBOX + RAW + APPLY + TABS + RESTORE)

    with open(index, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(html)

    print("harness: %s" % index)
    print("  注入 monitor 输出 %d 字节" % len(base))
    print("  注入日志假数据 %d / 会话 %d 字节" % (len(logs), len(sess)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
