/* ==========================================================================
   dtbo_charge_unlock · 充电状态 WebUI
   采集是只读的（monitor.sh 只读 /sys /proc 和模块状态文件）。
   唯一的写操作是「运行修改」按钮：二次确认后执行模块自带的 action.sh，
   由它完成「解包 → 改写 → 备份 → 刷入 → 回读校验」，本页面不直接写分区。

   充电日志标签页读的是 chargelog.sh 后台进程记下的文本文件（monitor.sh --logs
   只负责列出来），页面本身不写任何日志。
   ========================================================================== */
(function () {
  'use strict';

  var MODULE_DIR_FALLBACK = '/data/adb/modules/dtbo_charge_unlock';
  var POLL_MS   = 2000;
  var MAX_POINTS = 150;

  /* ------------------------------------------------------------ 小工具 --- */

  function $(id) { return document.getElementById(id); }

  function num(v) {
    if (v === undefined || v === null) return null;
    var s = String(v).trim();
    if (!s) return null;
    var n = Number(s);
    return isFinite(n) ? n : null;
  }

  function fmt(n, d) {
    if (n === null || n === undefined || !isFinite(n)) return '--';
    return n.toFixed(d);
  }

  function pad2(n) { return n < 10 ? '0' + n : '' + n; }

  function clockOf(epochSec) {
    if (!epochSec) return '--';
    var d = new Date(epochSec * 1000);
    return pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds());
  }

  function relTime(epochSec) {
    if (!epochSec) return '--';
    var diff = Math.floor(Date.now() / 1000) - epochSec;
    if (diff < 0) diff = 0;
    if (diff < 60)    return diff + ' 秒前';
    if (diff < 3600)  return Math.floor(diff / 60) + ' 分钟前';
    if (diff < 86400) return Math.floor(diff / 3600) + ' 小时前';
    return Math.floor(diff / 86400) + ' 天前';
  }

  function shortTime(epochSec) {
    if (!epochSec) return '--';
    var d = new Date(epochSec * 1000);
    return (d.getMonth() + 1) + '-' + pad2(d.getDate()) + ' '
         + pad2(d.getHours()) + ':' + pad2(d.getMinutes());
  }

  /* --------------------------------------------------- KernelSU 桥接 --- */

  function hasKsu() {
    return (typeof ksu !== 'undefined') && ksu && (typeof ksu.exec === 'function');
  }

  function moduleDir() {
    try {
      if (hasKsu() && typeof ksu.moduleInfo === 'function') {
        var info = ksu.moduleInfo();
        if (typeof info === 'string') info = JSON.parse(info);
        if (info && info.id) return '/data/adb/modules/' + info.id;
      }
    } catch (e) { /* 接口不存在或返回格式不同，走兜底 */ }
    return MODULE_DIR_FALLBACK;
  }

  var cbSeq = 0;

  /**
   * 包装 KernelSU 的原生 exec。
   * 原生签名: ksu.exec(command, optionsJson, callbackName)
   * 执行结束后由原生侧调用 window[callbackName](errno, stdout, stderr)
   *
   * 采集只要几百毫秒，刷写可能要十几秒，所以超时做成参数。
   */
  function exec(command, timeoutMs) {
    var limit = timeoutMs || 15000;
    return new Promise(function (resolve, reject) {
      if (!hasKsu()) {
        reject(new Error('缺少 KernelSU 接口'));
        return;
      }
      var name = '__ksu_cb_' + Date.now() + '_' + (cbSeq++);
      var settled = false;

      window[name] = function (errno, stdout, stderr) {
        settled = true;
        try { delete window[name]; } catch (e) { window[name] = undefined; }
        resolve({ errno: errno, stdout: stdout || '', stderr: stderr || '' });
      };

      try {
        ksu.exec(command, JSON.stringify({}), name);
      } catch (e) {
        try { delete window[name]; } catch (e2) {}
        reject(e);
        return;
      }

      setTimeout(function () {
        if (settled) return;
        try { delete window[name]; } catch (e) {}
        reject(new Error('执行超时（' + Math.round(limit / 1000) + ' 秒）'));
      }, limit);
    });
  }

  /* ---------------------------------------------------------------- 解析 --- */

  function parseKV(text) {
    var out = {};
    var lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (!line) continue;
      var p = line.indexOf('=');
      if (p < 0) continue;
      out[line.slice(0, p).trim()] = line.slice(p + 1);
    }
    return out;
  }

  /* 电池温度单位不一致：内核 ABI 规定 power_supply 的 temp 是 0.1℃，
     但个别厂商直接写 ℃。取值启发：
       - 负数一律按 0.1℃（手机电池在实际使用中不会到 -6℃ 以下；
         而 -25 当作 -2.5℃ 才符合内核 ABI 的常见实现）
       - 正数 >= 100 按 0.1℃（电池不会到 100℃，所以 352 只能是 35.2℃）
       - 其余正数按 ℃（厂商直写）
     仅影响显示，不参与任何写入。 */
  function tempC(raw) {
    var v = num(raw);
    if (v === null) return null;
    if (v < 0) return v / 10;
    return v >= 100 ? v / 10 : v;
  }

  /* ------------------------------------------------------------ 派生数据 --- */

  var STATUS_MAP = {
    'charging':      { text: '充电中',   cls: 'ok'   },
    'full':          { text: '已充满',   cls: 'ok'   },
    'discharging':   { text: '放电中',   cls: ''     },
    'not charging':  { text: '未充电',   cls: 'warn' },
    'unknown':       { text: '未知',     cls: ''     }
  };

  var SRC_LABEL = { usb: 'USB', ac: '充电器', wireless: '无线', dc: 'DC', pc_port: 'PC' };

  function derive(k) {
    var d = {};

    d.capacity = num(k.capacity);
    d.temp     = tempC(k.temp_raw);

    var vRaw = num(k.voltage_now);
    var iRaw = num(k.current_now);
    var pRaw = num(k.power_now);

    d.voltage = vRaw !== null ? vRaw / 1e6 : null;
    d.current = iRaw !== null ? Math.abs(iRaw) / 1e6 : null;

    if (pRaw !== null && pRaw > 0) {
      d.power = pRaw / 1e6;
    } else if (d.voltage !== null && d.current !== null) {
      d.power = d.voltage * d.current;
    } else {
      d.power = null;
    }

    var st = (k.status || '').trim();
    var stKey = st.toLowerCase();
    d.statusRaw = st;
    d.status = STATUS_MAP[stKey] || { text: st || '—', cls: '' };
    d.charging = /^(charging|full)$/.test(stKey);

    /* 在线的电源 */
    d.sources = [];
    var list = (k['src.list'] || '').trim().split(/\s+/);
    for (var i = 0; i < list.length; i++) {
      var s = list[i];
      if (!s) continue;
      if (num(k['src.' + s + '.online']) === 1) {
        d.sources.push({
          key: s,
          label: SRC_LABEL[s] || s,
          type: (k['src.' + s + '.type'] || '').trim(),
          vnow: num(k['src.' + s + '.vnow']),
          imax: num(k['src.' + s + '.imax'])
        });
      }
    }

    d.health  = (k.health || '').trim();
    d.cycle   = num(k.cycle_count);
    d.counter = num(k.charge_counter);
    d.counterMah = d.counter !== null ? Math.abs(d.counter) / 1000 : null;

    d.lastFlash = num(k.state_last_flash);
    d.part      = (k.state_part || '').trim();
    d.sha       = (k.state_last_sha || '').trim();
    d.backupFile = (k.backup_file || '').trim();
    d.backupSize = num(k.backup_size);
    d.backupTime = num(k.backup_time);
    d.backupCount = num(k.backup_count);
    d.dryRun    = (k.cfg_dry_run || '').trim();

    d.ffcLow  = num(k.cfg_ffc_low);
    d.ffcHigh = num(k.cfg_ffc_high);
    d.tier    = (k.cfg_tier || '').trim();

    /* 分区是否还是我们刷进去的那份。
       cur_head 只在 --full 采集时才算（要读分区头部 1MB），
       轮询时沿用上一次的结果，避免每 2 秒读一次盘。 */
    d.lastHead = (k.state_last_head || '').trim();
    if (k.state_cur_head) curHead = (k.state_cur_head || '').trim();
    d.headMatch = (d.lastHead && curHead) ? (d.lastHead === curHead) : null;

    /* 模块状态：停用 > 待确认 > 需重新应用 > 已应用 > 未刷写 */
    if (k.state_halted === '1') {
      d.mod = { text: '已回滚停用', cls: 'bad', note: '连续开机未确认，已写回备份' };
    } else if (k.state_pending && k.state_pending !== k.state_confirmed) {
      var tries = num(k.state_pending_tries) || 0;
      d.mod = { text: '等待开机确认', cls: 'warn', note: '第 ' + (tries + 1) + ' 次开机' };
    } else if (d.headMatch === false) {
      d.mod = { text: '需重新应用', cls: 'warn', note: 'dtbo 已不是本模块写入的那份（系统更新过？），点「运行修改」重新写入' };
    } else if (d.sha) {
      d.mod = { text: '已应用', cls: 'ok', note: 'dtbo 已改写并确认' };
    } else {
      d.mod = { text: '尚未刷写', cls: '', note: '本次安装未写入 dtbo' };
    }

    return d;
  }

  /* ------------------------------------------------------------ 渲染 --- */

  var last = null;
  /* 当前分区头部哈希，只有 --full 采集会更新 */
  var curHead = '';

  function setText(id, s) {
    var el = $(id);
    if (el) el.textContent = s;
  }

  function banner(html, kind) {
    var b = $('banner');
    if (!html) { b.className = 'banner hidden'; b.innerHTML = ''; return; }
    b.className = 'banner ' + (kind || 'warn');
    b.innerHTML = html;
  }

  function render(k, d) {
    if (k.module_version) setText('modVer', 'v' + k.module_version);

    /* ---- 电量环 ---- */
    var cap = d.capacity;
    var ring = $('ringFg');
    if (cap !== null) {
      setText('capValue', String(Math.round(cap)));
      var frac = Math.max(0, Math.min(100, cap)) / 100;
      ring.style.strokeDashoffset = String(326.73 * (1 - frac));
      ring.style.stroke = cap <= 15 ? '#f85149' : (d.charging ? '#3fb950' : '#58a6ff');
    } else {
      setText('capValue', '--');
      ring.style.strokeDashoffset = '326.73';
    }

    /* ---- 功率 / 状态 ---- */
    setText('powerValue', fmt(d.power, d.power !== null && d.power < 10 ? 2 : 1));

    var chip = $('statusChip');
    var chipText = d.status.text;
    if (d.charging && d.power !== null && d.power > 0.05) {
      chipText += ' · ' + fmt(d.power, 1) + ' W';
    }
    chip.textContent = chipText;
    chip.className = 'chip ' + (d.status.cls || '');

    /* ---- 电源说明 ---- */
    if (d.sources.length) {
      var parts = [];
      for (var i = 0; i < d.sources.length; i++) {
        var s = d.sources[i];
        var t = s.label;
        if (s.type) t += '(' + s.type + ')';
        if (s.vnow !== null && s.vnow > 0) t += ' ' + fmt(s.vnow / 1e6, 2) + 'V';
        if (s.imax !== null && s.imax > 0) t += ' / ' + fmt(Math.abs(s.imax) / 1e6, 2) + 'A 上限';
        parts.push(t);
      }
      setText('sourceNote', parts.join(' + '));
    } else {
      setText('sourceNote', d.charging ? '充电中（未识别到供电来源）' : '未接入电源');
    }

    /* ---- 指标 ---- */
    setText('mCurrent', fmt(d.current, 2));
    setText('mVoltage', fmt(d.voltage, 2));
    setText('mTemp',    fmt(d.temp, 1));
    setText('mHealth',  d.health || '--');
    setText('mCycle',   d.cycle !== null ? String(d.cycle) : '--');
    setText('mCounter', fmt(d.counterMah, 0));

    renderWindow(d);
    renderThermal(k);
    renderModule(d);

    /* ---- 原始数据 ---- */
    var raw = $('rawDump');
    if (raw) {
      var lines = [];
      Object.keys(k).sort().forEach(function (key) {
        lines.push(key + '=' + k[key]);
      });
      raw.textContent = lines.join('\n') || '（无数据）';
    }
  }

  /* ---- 温度窗口条 ---- */
  var TIER_LABEL = { safe: '安全档', max: '极限档', custom: '自定义', ref: '参考表' };

  function renderWindow(d) {
    var low = d.ffcLow, high = d.ffcHigh;
    var range = $('windowRange');
    var marker = $('windowMarker');
    var tier = TIER_LABEL[d.tier] || '';

    if (low === null || high === null || high <= low) {
      range.style.left = '0%';
      range.style.width = '0%';
      marker.style.display = 'none';
      setText('windowHint', '配置里没有设定窗口');
      setText('axisLow', '—');
      setText('axisHigh', '—');
      return;
    }

    marker.style.display = '';

    var domLow  = Math.min(0, low);
    var domHigh = Math.max(60, high);
    var span = domHigh - domLow || 1;

    range.style.left  = ((low - domLow) / span * 100) + '%';
    range.style.width = ((high - low) / span * 100) + '%';

    setText('axisLow',  domLow + '℃');
    setText('axisHigh', domHigh + '℃');
    setText('windowHint',
            (tier ? tier + ' · ' : '') + low + '~' + high + '℃ 全速');

    var t = d.temp;
    if (t === null) {
      marker.style.display = 'none';
      return;
    }
    var pos = Math.max(0, Math.min(100, (t - domLow) / span * 100));
    marker.style.left = 'calc(' + pos + '% - 1.5px)';
    var inside = t >= low && t <= high;
    marker.className = 'window-marker' + (inside ? '' : ' out');
    setText('windowMarkerText', fmt(t, 1) + '℃');
  }

  /* ---- 温度区列表 ---- */
  function renderThermal(k) {
    var ul = $('thermalList');
    var n = num(k['thermal.count']) || 0;
    var items = [];

    for (var i = 0; i < n; i++) {
      var raw = k['thermal.' + i];
      if (!raw) continue;
      var p = raw.indexOf('|');
      if (p < 0) continue;
      var name = raw.slice(0, p);
      var val = num(raw.slice(p + 1));
      if (val === null) continue;
      items.push({ name: name, c: Math.abs(val) >= 1000 ? val / 1000 : val });
    }

    ul.innerHTML = '';
    if (!items.length) {
      var li0 = document.createElement('li');
      li0.innerHTML = '<span class="tn" style="flex:1 1 auto">没有匹配到电池/充电相关的温度区</span>';
      ul.appendChild(li0);
      setText('thermalHint', '—');
      return;
    }

    items.sort(function (a, b) { return b.c - a.c; });
    var maxC = Math.max(60, items[0].c);

    for (var j = 0; j < items.length; j++) {
      var it = items[j];
      var pct = Math.max(2, Math.min(100, (it.c / maxC) * 100));
      var color = it.c >= 55 ? '#f85149' : (it.c >= 45 ? '#d29922' : '#3fb950');

      var li = document.createElement('li');
      var tn = document.createElement('span');
      tn.className = 'tn';
      tn.textContent = it.name;

      var bar = document.createElement('span');
      bar.className = 'tbar';
      var fill = document.createElement('i');
      fill.style.width = pct + '%';
      fill.style.background = color;
      bar.appendChild(fill);

      var tv = document.createElement('span');
      tv.className = 'tv';
      tv.textContent = fmt(it.c, 1) + '℃';

      li.appendChild(tn);
      li.appendChild(bar);
      li.appendChild(tv);
      ul.appendChild(li);
    }
    setText('thermalHint', items.length + ' 个');
  }

  /* ---- 模块状态 ---- */
  function renderModule(d) {
    var chip = $('moduleChip');
    chip.textContent = d.mod.text;
    chip.className = 'chip small ' + (d.mod.cls || '');
    chip.title = d.mod.note || '';

    setText('kLastFlash', d.lastFlash ? (shortTime(d.lastFlash) + '（' + relTime(d.lastFlash) + '）') : '—');
    setText('kPart', d.part || '—');
    setText('kSha', d.sha ? d.sha.slice(0, 16) + '…' : '—');

    if (d.headMatch === true) {
      setText('kApplied', '是（与刷入时一致）');
      $('kApplied').className = 'ok';
    } else if (d.headMatch === false) {
      setText('kApplied', '否（已被覆盖）');
      $('kApplied').className = 'warn';
    } else {
      setText('kApplied', '—');
      $('kApplied').className = '';
    }

    if (d.backupFile) {
      var name = d.backupFile.split('/').pop();
      var size = d.backupSize !== null ? (d.backupSize / 1024 / 1024).toFixed(1) + ' MB' : '';
      var extra = d.backupCount !== null ? '（共 ' + d.backupCount + ' 份）' : '';
      setText('kBackup', name + ' ' + size + extra);
    } else {
      setText('kBackup', '—');
    }

    setText('kDryRun', d.dryRun === '1' ? '开启（不写分区）' : '关闭');
  }

  /* ------------------------------------------------------------ 曲线 --- */

  var series = { power: [], temp: [] };

  function pushSample(d) {
    series.power.push(d.power);
    series.temp.push(d.temp);
    if (series.power.length > MAX_POINTS) series.power.shift();
    if (series.temp.length  > MAX_POINTS) series.temp.shift();

    setText('chartPowerNow', fmt(d.power, 1));
    setText('chartTempNow',  fmt(d.temp, 1));
    setText('chartHint', series.power.length + ' 点 / ' + Math.round(POLL_MS / 1000) + 's');
  }

  function drawSeries(canvas, data, color, fixedMin, total) {
    if (!canvas) return;
    var dpr = window.devicePixelRatio || 1;
    var w = canvas.clientWidth || canvas.parentNode.clientWidth || 300;
    var h = canvas.clientHeight || 72;

    var slots = total || MAX_POINTS;
    if (slots < 2) slots = 2;

    if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
    }

    var ctx = canvas.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);

    var pts = [];
    for (var i = 0; i < data.length; i++) {
      if (data[i] !== null && isFinite(data[i])) pts.push(data[i]);
    }
    if (pts.length < 2) return;

    var lo = Math.min.apply(null, pts);
    var hi = Math.max.apply(null, pts);
    if (fixedMin !== undefined && fixedMin !== null) lo = Math.min(lo, fixedMin);
    if (hi - lo < 0.5) { hi = lo + 0.5; }
    var pad = (hi - lo) * 0.12;
    lo -= pad; hi += pad;
    var span = hi - lo || 1;

    /* 网格 */
    ctx.strokeStyle = 'rgba(255,255,255,.055)';
    ctx.lineWidth = 1;
    for (var g = 1; g <= 2; g++) {
      var y = (h / 3) * g;
      ctx.beginPath();
      ctx.moveTo(0, y + 0.5);
      ctx.lineTo(w, y + 0.5);
      ctx.stroke();
    }

    var stepX = w / (slots - 1);
    var offset = slots - data.length;

    function xAt(idx) { return (offset + idx) * stepX; }
    function yAt(v)   { return h - ((v - lo) / span) * h; }

    /* 折线 */
    ctx.beginPath();
    var started = false;
    for (var k2 = 0; k2 < data.length; k2++) {
      var v2 = data[k2];
      if (v2 === null || !isFinite(v2)) { started = false; continue; }
      var px = xAt(k2), py = yAt(v2);
      if (!started) { ctx.moveTo(px, py); started = true; }
      else { ctx.lineTo(px, py); }
    }
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    ctx.stroke();

    /* 渐变填充 */
    ctx.lineTo(xAt(data.length - 1), h);
    ctx.lineTo(xAt(0), h);
    ctx.closePath();
    var grad = ctx.createLinearGradient(0, 0, 0, h);
    grad.addColorStop(0, color + '33');
    grad.addColorStop(1, color + '00');
    ctx.fillStyle = grad;
    ctx.fill();

    /* 当前点 */
    for (var m = data.length - 1; m >= 0; m--) {
      if (data[m] !== null && isFinite(data[m])) {
        ctx.beginPath();
        ctx.arc(xAt(m), yAt(data[m]), 2.6, 0, Math.PI * 2);
        ctx.fillStyle = color;
        ctx.fill();
        break;
      }
    }
  }

  function redrawCharts() {
    drawSeries($('chartPower'), series.power, '#58a6ff', 0);
    drawSeries($('chartTemp'),  series.temp,  '#3fb950', null);
  }

  /* ------------------------------------------------------------ 充电日志 --- */

  var logList = [];     /* monitor.sh --logs 的结果 */
  var logCur  = null;   /* 当前打开的会话 */
  var tab = 'live';

  function durationText(a, b) {
    if (!a || !b || b < a) return '—';
    var s = b - a;
    if (s < 60) return s + ' 秒';
    if (s < 3600) return Math.floor(s / 60) + ' 分';
    return Math.floor(s / 3600) + ' 时 ' + Math.floor((s % 3600) / 60) + ' 分';
  }

  function switchTab(name) {
    if (name === tab) return;
    tab = name;

    $('viewLive').classList.toggle('hidden', name !== 'live');
    $('viewLogs').classList.toggle('hidden', name !== 'logs');

    var btns = document.querySelectorAll('[data-tab]');
    for (var i = 0; i < btns.length; i++) {
      btns[i].classList.toggle('on', btns[i].getAttribute('data-tab') === name);
    }

    if (name === 'logs') {
      stopTimer();
      loadLogs();
    } else if (autoOn) {
      refresh(true);
      startTimer();
    }
  }

  /* ---- 会话列表 ---- */

  function renderLogState(k) {
    var running = (k.log_running || '').trim() === '1';
    var iv = num(k.log_interval);
    var cur = (k.log_current || '').trim();

    var chip = $('logStateChip');
    chip.textContent = running ? '记录中' : '未记录';
    chip.className = 'chip small ' + (running ? 'ok' : 'warn');

    setText('logInterval', iv !== null ? String(iv) : '30');
    $('logStartBox').classList.toggle('hidden', running);

    if (!running) {
      setText('logHintText', '后台记录进程没有在跑，插拔充电器不会被记下来。');
    } else if (cur) {
      setText('logHintText', '正在记录这次充电（' + cur + '），拔出充电器后结束。');
    } else {
      setText('logHintText', '等待插上充电器…');
    }
  }

  function renderLogList() {
    var ul = $('logList');
    ul.innerHTML = '';

    if (!logList.length) {
      var li0 = document.createElement('li');
      li0.className = 'empty';
      li0.textContent = '还没有记录。插上充电器就会开始记。';
      ul.appendChild(li0);
      return;
    }

    for (var i = 0; i < logList.length; i++) {
      (function (s) {
        var li = document.createElement('li');

        var main = document.createElement('div');
        main.className = 'lt-main';

        var t = document.createElement('div');
        t.className = 'lt-time';
        t.textContent = shortTime(s.start);

        var sub = document.createElement('div');
        sub.className = 'lt-sub';
        var bits = [];
        if (s.cap0 !== null && s.cap1 !== null) {
          bits.push(Math.round(s.cap0) + '% → ' + Math.round(s.cap1) + '%');
        }
        if (s.tmax !== null) bits.push('最高 ' + fmt(s.tmax, 1) + '℃');
        bits.push(s.samples + ' 点');
        sub.textContent = bits.join(' · ');
        if (s.aborted) {
          var b = document.createElement('span');
          b.className = 'bad';
          b.textContent = ' · 未正常结束';
          sub.appendChild(b);
        }

        main.appendChild(t);
        main.appendChild(sub);

        var dur = document.createElement('div');
        dur.className = 'lt-dur';
        dur.textContent = durationText(s.start, s.end);

        li.appendChild(main);
        li.appendChild(dur);
        li.addEventListener('click', function () { openSession(s.name); });
        ul.appendChild(li);
      })(logList[i]);
    }
  }

  function loadLogs() {
    var ul = $('logList');
    if (ul) ul.innerHTML = '<li class="empty">读取中…</li>';
    $('logDetail').classList.add('hidden');
    $('logListCard').classList.remove('hidden');

    return exec('sh ' + moduleDir() + '/monitor.sh --logs', 30000)
      .then(function (res) {
        var k = parseKV(res.stdout || '');
        var n = num(k['log.list_count']) || 0;

        logList = [];
        for (var i = 0; i < n; i++) {
          var nm = k['log.' + i + '.name'];
          if (!nm) continue;
          logList.push({
            name: nm,
            start: num(k['log.' + i + '.start']),
            end: num(k['log.' + i + '.end']),
            aborted: num(k['log.' + i + '.aborted']) === 1,
            samples: num(k['log.' + i + '.samples']) || 0,
            cap0: num(k['log.' + i + '.cap0']),
            cap1: num(k['log.' + i + '.cap1']),
            tmax: tempC(k['log.' + i + '.temp_max'])
          });
        }

        renderLogState(k);
        renderLogList();
      })
      .catch(function (err) {
        ul.innerHTML = '';
        var li = document.createElement('li');
        li.className = 'empty';
        li.textContent = '读取失败：' + (err && err.message ? err.message : err);
        ul.appendChild(li);
      });
  }

  /* ---- 单个会话 ---- */

  function renderSession(s) {
    var pts = s.pts;
    var pw = [], tp = [];
    var pmax = null, tmax = null;
    var c0 = null, c1 = null, cfirst = null, clast = null;

    for (var i = 0; i < pts.length; i++) {
      var p = pts[i];
      pw.push(p.power);
      tp.push(p.temp);
      if (p.power !== null && (pmax === null || p.power > pmax)) pmax = p.power;
      if (p.temp !== null && (tmax === null || p.temp > tmax)) tmax = p.temp;
      if (p.cap !== null) { if (c0 === null) c0 = p.cap; c1 = p.cap; }
      if (p.counter !== null) {
        if (cfirst === null) cfirst = p.counter;
        clast = p.counter;
      }
    }

    var mah = (cfirst !== null && clast !== null && clast >= cfirst)
      ? (clast - cfirst) / 1000 : null;

    var rows = [];
    rows.push(['开始', shortTime(s.start)]);
    rows.push(['结束', s.end ? (clockOf(s.end) + '（' + durationText(s.start, s.end) + '）')
                             : '记录中']);
    if (c0 !== null && c1 !== null) rows.push(['电量', Math.round(c0) + '% → ' + Math.round(c1) + '%']);
    if (mah !== null) rows.push(['充入', fmt(mah, 0) + ' mAh']);
    rows.push(['功率峰值', fmt(pmax, 1) + ' W']);
    rows.push(['温度最高', fmt(tmax, 1) + ' ℃']);
    rows.push(['采样点', pts.length + ' 个']);
    if (s.aborted) rows.push(['状态', '未正常结束（掉电或被系统杀掉）']);

    var stats = $('logStats');
    stats.innerHTML = '';
    for (var r = 0; r < rows.length; r++) {
      var dt = document.createElement('dt');
      dt.textContent = rows[r][0];
      var dd = document.createElement('dd');
      dd.textContent = rows[r][1];
      stats.appendChild(dt);
      stats.appendChild(dd);
    }

    setText('logPowerPeak', fmt(pmax, 1));
    setText('logTempPeak', fmt(tmax, 1));

    drawSeries($('logChartPower'), pw, '#58a6ff', 0, Math.max(pw.length, 2));
    drawSeries($('logChartTemp'),  tp, '#3fb950', null, Math.max(tp.length, 2));
  }

  function openSession(name) {
    $('logListCard').classList.add('hidden');
    $('logDetail').classList.remove('hidden');
    setText('logTitle', String(name).replace(/\.log$/, ''));

    var stats = $('logStats');
    stats.innerHTML = '';
    var dt = document.createElement('dt');
    dt.textContent = '读取中';
    var dd = document.createElement('dd');
    dd.textContent = '…';
    stats.appendChild(dt);
    stats.appendChild(dd);

    return exec('sh ' + moduleDir() + '/monitor.sh --log ' + name, 30000)
      .then(function (res) {
        var k = parseKV(res.stdout || '');
        var n = num(k['session.count']) || 0;
        var pts = [];

        for (var i = 0; i < n; i++) {
          var raw = k['session.s.' + i];
          if (!raw) continue;
          var f = raw.split(',');
          var epoch = num(f[0]);
          if (!epoch) continue;
          var cur = num(f[3]);
          var volt = num(f[4]);
          pts.push({
            t: epoch,
            cap: num(f[1]),
            temp: tempC(f[2]),
            power: (cur !== null && volt !== null)
              ? Math.abs(cur) / 1e6 * (volt / 1e6) : null,
            counter: num(f[5])
          });
        }

        logCur = {
          name: name,
          pts: pts,
          start: num(k['session.start']),
          end: num(k['session.end']),
          aborted: (k['session.aborted'] || '').trim() === '1'
        };
        renderSession(logCur);
      })
      .catch(function (err) {
        stats.innerHTML = '';
        var e1 = document.createElement('dt');
        e1.textContent = '错误';
        var e2 = document.createElement('dd');
        e2.textContent = (err && err.message) ? err.message : String(err);
        stats.appendChild(e1);
        stats.appendChild(e2);
      });
  }

  function backToList() {
    logCur = null;
    $('logDetail').classList.add('hidden');
    $('logListCard').classList.remove('hidden');
    loadLogs();
  }

  function bootLogs() {
    var btns = document.querySelectorAll('[data-tab]');
    for (var i = 0; i < btns.length; i++) {
      btns[i].addEventListener('click', function () {
        switchTab(this.getAttribute('data-tab'));
      });
    }

    $('btnLogBack').addEventListener('click', backToList);

    $('btnLogStart').addEventListener('click', function () {
      var b = $('btnLogStart');
      b.disabled = true;
      b.textContent = '启动中…';
      exec('sh ' + moduleDir() + '/chargelog.sh start', 20000)
        .then(function () {
          return new Promise(function (r) { setTimeout(r, 1200); });
        })
        .then(loadLogs)
        .catch(function (err) {
          setText('logHintText', '启动失败：' + (err && err.message ? err.message : err));
        })
        .then(function () {
          b.disabled = false;
          b.textContent = '启动记录';
        });
    });
  }

  /* ------------------------------------------------------------ 主流程 --- */

  var busy = false;
  var timer = null;
  var autoOn = true;

  function refresh(full) {
    if (busy) return Promise.resolve();
    busy = true;
    $('btnRefresh').classList.add('busy');

    return exec('sh ' + moduleDir() + '/monitor.sh' + (full ? ' --full' : ''))
      .then(function (res) {
        if (res.errno !== 0 && !res.stdout) {
          throw new Error((res.stderr || '').trim() || ('monitor.sh 返回 ' + res.errno));
        }
        var k = parseKV(res.stdout);
        if (!k.time) throw new Error('采集脚本没有输出');

        var d = derive(k);
        last = d;

        if (!k.batt_dir) {
          banner('没有找到电池节点（<code>/sys/class/power_supply/battery</code> 不存在）。'
               + '这台设备可能用了非常规的节点名，页面只能显示模块状态。', 'warn');
        } else {
          banner('');
        }

        render(k, d);
        pushSample(d);
        redrawCharts();
      })
      .catch(function (err) {
        banner('采集失败：' + (err && err.message ? err.message : err), 'err');
      })
      .then(function () {
        busy = false;
        $('btnRefresh').classList.remove('busy');
      });
  }

  function startTimer() {
    stopTimer();
    if (!autoOn) return;
    timer = setInterval(function () { refresh(false); }, POLL_MS);
  }

  function stopTimer() {
    if (timer) { clearInterval(timer); timer = null; }
  }

  /* --------------------------------------------------------- 运行修改 --- */

  var applying = false;

  function applyOut(text) {
    var el = $('applyOut');
    el.classList.remove('hidden');
    el.textContent = text;
  }

  function askConfirm(text) {
    return new Promise(function (resolve) {
      var box = $('confirm');
      $('confirmText').innerHTML = text;
      box.classList.remove('hidden');

      function done(val) {
        box.classList.add('hidden');
        $('confirmYes').removeEventListener('click', yes);
        $('confirmNo').removeEventListener('click', no);
        resolve(val);
      }
      function yes() { done(true); }
      function no() { done(false); }

      $('confirmYes').addEventListener('click', yes);
      $('confirmNo').addEventListener('click', no);
    });
  }

  function doApply() {
    if (applying) return;
    applying = true;

    var btn = $('btnApply');
    btn.disabled = true;
    btn.textContent = '正在执行…';
    stopTimer();
    applyOut('开始执行，刷写期间请不要退出页面…');

    exec('sh ' + moduleDir() + '/action.sh', 240000)
      .then(function (res) {
        var out = (res.stdout || '');
        if (res.stderr) out += (out ? '\n' : '') + res.stderr;
        out += '\n--- 退出码: ' + res.errno + ' ---';
        applyOut(out);
        if (res.errno === 0) {
          banner('已执行完成。新 dtbo <strong>需要重启</strong>后才生效。', 'ok');
        } else {
          banner('执行未成功（退出码 ' + res.errno + '），详见下方输出。分区可能未被修改。', 'err');
        }
      })
      .catch(function (err) {
        applyOut('执行失败：' + (err && err.message ? err.message : err));
        banner('执行失败：' + (err && err.message ? err.message : err), 'err');
      })
      .then(function () {
        applying = false;
        btn.disabled = false;
        btn.textContent = '运行修改';
        return refresh(true);
      })
      .then(function () { if (autoOn) startTimer(); });
  }

  function bootApply() {
    $('btnApply').addEventListener('click', function () {
      var d = last;
      var slot = d && d.part ? d.part : '当前槽位';
      var warn = '';
      if (d && d.headMatch === false) {
        warn = '<br><br><strong>注意：现在分区里的 dtbo 已经不是本模块写入的那份'
             + '（大概被系统更新覆盖了），这次会重新改写。</strong>';
      }
      askConfirm(
        '将会<b>重新解包、改写并刷入</b> <code>' + slot + '</code>。'
        + '<br><br>刷写前会自动备份原始镜像，刷完回读校验，失败会自动写回。'
        + '<br>刷入后需要<b>重启</b>才生效。' + warn
      ).then(function (ok) {
        if (ok) doApply();
      });
    });
  }

  function boot() {
    setText('devModel', '读取中…');
    bootLogs();

    if (!hasKsu()) {
      banner('这个页面需要从 <strong>KernelSU 管理器</strong>里打开才能读取系统数据。'
           + '直接当普通网页打开时，KernelSU 的 <code>ksu</code> 接口不可用。', 'warn');
      setText('devModel', '未在 KernelSU 中打开');
      return;
    }

    /* 设备型号与模块版本 */
    exec('getprop ro.product.model; getprop ro.boot.slot_suffix')
      .then(function (res) {
        var ls = (res.stdout || '').split('\n');
        var model = (ls[0] || '').trim();
        var slot = (ls[1] || '').trim().replace('_', '');
        var txt = model || '未知机型';
        if (slot) txt += ' · 槽位 ' + slot.toUpperCase();
        setText('devModel', txt);
      })
      .catch(function () { setText('devModel', '未知机型'); });

    refresh(true).then(startTimer);

    $('btnRefresh').addEventListener('click', function () { refresh(true); });
    bootApply();

    var toggle = $('autoToggle');
    toggle.addEventListener('change', function () {
      autoOn = toggle.checked;
      if (autoOn) { refresh(false); startTimer(); }
      else { stopTimer(); }
    });

    document.addEventListener('visibilitychange', function () {
      if (document.hidden) { stopTimer(); }
      else if (tab === 'logs') { loadLogs(); }
      else if (autoOn) { refresh(true); startTimer(); }
    });

    window.addEventListener('resize', function () {
      clearTimeout(window.__rz);
      window.__rz = setTimeout(function () {
        if (tab === 'logs') { if (logCur) renderSession(logCur); }
        else redrawCharts();
      }, 150);
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
