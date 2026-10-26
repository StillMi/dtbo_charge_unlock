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

  var dirCache = '';

  function moduleDir() {
    if (dirCache) return dirCache;
    try {
      if (hasKsu() && typeof ksu.moduleInfo === 'function') {
        var info = ksu.moduleInfo();
        if (typeof info === 'string') info = JSON.parse(info);
        if (info && info.id) { dirCache = '/data/adb/modules/' + info.id; return dirCache; }
      }
    } catch (e) { /* 接口不存在或返回格式不同，走兜底 */ }
    dirCache = MODULE_DIR_FALLBACK;
    return dirCache;
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
      var tmr = null;

      window[name] = function (errno, stdout, stderr) {
        settled = true;
        if (tmr) { clearTimeout(tmr); tmr = null; }
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

      tmr = setTimeout(function () {
        if (settled) return;
        tmr = null;
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

    /* Scene 温控档位。monitor.sh 只「读一眼」，读到什么就是什么；
       读不到就是空字符串，不猜。 */
    d.scene = (k.scene_thermal || '').trim();
    d.sceneFile = (k.scene_file || '').trim();
    d.thermalEngine = num(k.thermal_engine) === 1;

    d.ffcLow  = num(k.cfg_ffc_low);
    d.ffcHigh = num(k.cfg_ffc_high);
    d.tier    = (k.cfg_tier || '').trim();

    /* 分区是否还是我们刷进去的那份。
       cur_head 只在 --full 采集时才算（要读分区头部 1MB），
       轮询时沿用上一次的结果，避免每 2 秒读一次盘。 */
    d.lastHead = (k.state_last_head || '').trim();
    if (k.state_cur_head) curHead = (k.state_cur_head || '').trim();
    d.headMatch = (d.lastHead && curHead) ? (d.lastHead === curHead) : null;

    /* 模块状态只看一件事：当前分区还是不是本模块写进去的那份。
       没有「等待开机确认」了 —— 模块不做开机确认，刷完重启就生效。 */
    if (d.headMatch === false) {
      d.mod = {
        text: '需重新应用', cls: 'warn',
        note: 'dtbo 已不是本模块写入的那份（系统更新过？），点「运行修改」重新写入'
      };
    } else if (d.headMatch === true) {
      d.mod = { text: '已生效', cls: 'ok', note: '当前 dtbo 就是本模块写入的那份' };
    } else if (d.sha) {
      /* 还没拿到分区哈希（没做过 --full），先按「已刷写」显示 */
      d.mod = { text: '已刷写', cls: 'ok', note: '已写入，正在确认当前分区' };
    } else {
      d.mod = { text: '尚未刷写', cls: '', note: '还没写过 dtbo，点「运行修改」开始' };
    }

    return d;
  }

  /* ------------------------------------------------------------ 渲染 --- */

  var last = null;
  /* 当前分区头部哈希，只有 --full 采集会更新 */
  var curHead = '';

  function setText(id, s) {
    var el = $(id);
    if (!el) return;
    /* 只有真的变了才写 DOM：每 2 秒全量赋值会让页面反复重排，点起来发卡 */
    if (el.textContent !== s) el.textContent = s;
  }

  function banner(html, kind) {
    var b = $('banner');
    if (!html) {
      if (b.className !== 'banner hidden') { b.className = 'banner hidden'; b.innerHTML = ''; }
      return;
    }
    var cls = 'banner ' + (kind || 'warn');
    if (b.className !== cls) b.className = cls;
    if (b.innerHTML !== html) b.innerHTML = html;
  }

  function render(k, d) {
    if (k.module_version) setText('modVer', 'v' + k.module_version);

    /* ---- 电量环 ---- */
    var cap = d.capacity;
    var ring = $('ringFg');
    if (cap !== null) {
      setText('capValue', String(Math.round(cap)));
      var frac = Math.max(0, Math.min(100, cap)) / 100;
      var off = String(326.73 * (1 - frac));
      var col = cap <= 15 ? '#f85149' : (d.charging ? '#3fb950' : '#58a6ff');
      /* 只在变化时写，避免每 2 秒触发一次 SVG 重绘 */
      if (ring.style.strokeDashoffset !== off) ring.style.strokeDashoffset = off;
      if (ring.style.stroke !== col) ring.style.stroke = col;
    } else {
      setText('capValue', '--');
      if (ring.style.strokeDashoffset !== '326.73') ring.style.strokeDashoffset = '326.73';
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
    renderScene(d);
    renderRestore(d);

    /* ---- 原始数据 ---- */
    /* 这段文本很长，每 2 秒重写一次会很卡；折叠状态下干脆不生成。 */
    var raw = $('rawDump');
    var det = raw && raw.parentNode;
    if (raw && det && det.tagName === 'DETAILS' && det.open) {
      var lines = [];
      Object.keys(k).sort().forEach(function (key) {
        lines.push(key + '=' + k[key]);
      });
      var txt = lines.join('\n') || '（无数据）';
      if (raw.textContent !== txt) raw.textContent = txt;
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

    var rl = ((low - domLow) / span * 100) + '%';
    var rw = ((high - low) / span * 100) + '%';
    if (range.style.left !== rl)  range.style.left  = rl;
    if (range.style.width !== rw) range.style.width = rw;

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
    var ml = 'calc(' + pos + '% - 1.5px)';
    if (marker.style.left !== ml) marker.style.left = ml;
    var inside = t >= low && t <= high;
    var mc = 'window-marker' + (inside ? '' : ' out');
    if (marker.className !== mc) marker.className = mc;
    setText('windowMarkerText', fmt(t, 1) + '℃');
  }

  /* ---- 温度区列表 ---- */
  /* 每 2 秒重建一次 <ul> 会不停触发重排（10 个区 = 30 个节点），
     所以按「名字 + 数值」拼一个指纹，指纹没变就一个 DOM 都不碰。 */
  var thermalSig = '';

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

    items.sort(function (a, b) { return b.c - a.c; });

    var sig = '';
    for (var s = 0; s < items.length; s++) sig += items[s].name + '@' + items[s].c + ';';
    if (sig === thermalSig) return;
    thermalSig = sig;

    ul.innerHTML = '';
    if (!items.length) {
      var li0 = document.createElement('li');
      li0.innerHTML = '<span class="tn" style="flex:1 1 auto">没有匹配到电池/充电相关的温度区</span>';
      ul.appendChild(li0);
      setText('thermalHint', '—');
      return;
    }

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
      setText('kApplied', '是（当前分区就是本模块写入的）');
      $('kApplied').className = 'ok';
    } else if (d.headMatch === false) {
      setText('kApplied', '否（已被覆盖，需重新运行）');
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

  /* ---- 系统温控（Scene 档位）----
     模块只改 dtbo 里充电 IC 自己的温控表，系统层的温控（MIUI 的
     thermal-engine / mi_thermald）优先级更高。没把 Scene 的温控改成
     「丧心病狂」的话，很可能刷完一点都提不上去 —— 但这是「可能」，
     不是结论：Scene 的档位只是它自己的设置，用户也可能用别的方式改过。
     所以这里只把读到的原样摆出来，不替用户下判断。 */
  var SCENE_LABEL = {
    'default': '系统默认',
    'cool': '清爽酷凉',
    'pro': '深度定制',
    'performance': '提高阈值',
    'extreme': '极致性能',
    'danger': '丧心病狂'
  };

  function renderScene(d) {
    var chip = $('sceneChip');
    var top = $('sceneBanner');
    if (!chip) return;

    var key = (d.scene || '').toLowerCase();
    var label = SCENE_LABEL[key] || '';
    var txt = key ? (label ? label + '（' + key + '）' : key) : '—';

    if (!key) {
      chip.textContent = '未检测到';
      chip.className = 'chip small warn';
      setText('kScene', '—');
      $('kScene').className = '';
      setText('sceneHint',
        '没找到 Scene 的温控档位文件。要是确实装了 Scene 并选了「丧心病狂」，'
        + '那可能是版本不同、文件在别处，或者温控是用别的方式改的 —— '
        + '直接看充电功率有没有上去更靠谱。');
      setText('kThermalEngine', d.thermalEngine ? '在运行' : '未找到');
      $('kThermalEngine').className = d.thermalEngine ? 'warn' : '';
      if (top) top.className = 'banner hidden';
      return;
    }

    setText('kScene', txt);
    $('kScene').className = (key === 'danger') ? 'ok' : 'warn';
    setText('kThermalEngine', d.thermalEngine ? '在运行' : '未找到');
    $('kThermalEngine').className = '';

    if (key === 'danger') {
      chip.textContent = '已放开';
      chip.className = 'chip small ok';
      setText('sceneHint',
        'Scene 的温控档位是「丧心病狂」，系统层温控已经放开，'
        + '模块改的充电温控表能真正起作用。');
      if (top) top.className = 'banner hidden';
    } else {
      chip.textContent = '可能还在限流';
      chip.className = 'chip small warn';
      setText('sceneHint',
        'Scene 现在的温控档位是「' + (label || key) + '」，不是「丧心病狂」。'
        + '系统层温控优先级比 dtbo 高，这种情况下刷了模块也可能完全看不到提速。'
        + '建议先去 Scene 把温控改成「丧心病狂」，再回来确认。');
      if (top) {
        top.className = 'banner warn';
        top.innerHTML = '系统温控没有放开（Scene 当前档位：<strong>'
          + (label || key) + '</strong>）。模块只改充电 IC 自己的温控表，'
          + '系统层的限流优先级更高 —— <strong>不把 Scene 温控改成「丧心病狂」，'
          + '很可能一点都提不上去</strong>。';
      }
    }
  }

  /* ---- 恢复原厂 ---- */
  function renderRestore(d) {
    var chip = $('restoreChip');
    if (!chip) return;

    var btn = $('btnRestore');
    var has = !!d.backupFile;

    if (has) {
      setText('kRestoreFile', d.backupFile.split('/').pop()
        + (d.backupSize !== null ? ' ' + (d.backupSize / 1024 / 1024).toFixed(1) + ' MB' : ''));
      chip.textContent = '可恢复';
      chip.className = 'chip small ok';
      if (btn) btn.disabled = false;
    } else {
      setText('kRestoreFile', '—');
      chip.textContent = '没有备份';
      chip.className = 'chip small warn';
      if (btn) btn.disabled = true;
    }

    var stale = (d.headMatch === false);
    var hint = $('restoreHint');
    if (!hint) return;
    var base = '把刷入前备份的原厂 <code>dtbo</code> 写回当前槽位，之后充电就回到官方限制。';
    if (!has) {
      hint.innerHTML = base
        + '<br><strong>现在没有可用的原厂备份</strong>，没法用这个按钮回滚。'
        + '要真正回到原厂，请用 fastboot 刷入当前系统版本的官方 <code>dtbo</code>。';
    } else if (stale) {
      hint.innerHTML = base
        + '<br><strong>注意：当前分区已经不是本模块写入的那份了</strong>'
        + '（系统大概更新过），这份备份可能和当前系统对不上。'
        + '更稳的做法是用 fastboot 刷入当前系统版本的官方 <code>dtbo</code>。';
    } else {
      hint.innerHTML = base + '<strong>这一步会真的改分区。</strong>';
    }
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
      /* 日志页不做 2 秒的 sysfs 轮询，但必须换成一个慢速刷新：
         之前是完全停掉，结果插拔充电器后「记录中 / 等待插上」一直不动，
         看起来像没写日志。日志只是一次 ls + 一次文件扫描，5 秒一次不费电。 */
      stopTimer();
      loadLogs();
      if (autoOn) startLogTimer();
    } else {
      stopLogTimer();
      /* 切回来只做一次轻量采集，不要每次都读 1MB 分区 */
      if (autoOn) { refresh(false); startTimer(); }
    }
  }

  /* ---- 会话列表 ---- */

  function renderLogState(k) {
    var running = (k.log_running || '').trim() === '1';
    var plugged = (k.log_plugged || '').trim() === '1';
    var iv = num(k.log_interval);
    var cur = (k.log_current || '').trim();
    var cnt = num(k.log_count) || 0;

    var chip = $('logStateChip');
    chip.textContent = running ? '记录中' : '未在记录';
    chip.className = 'chip small ' + (running ? 'ok' : 'warn');

    setText('logInterval', iv !== null ? String(iv) : '10');
    $('logStartBox').classList.toggle('hidden', running);

    /* 四句话覆盖全部状态，让用户不用猜：
         进程没跑 / 在跑且在记 / 在跑且插着电但还没采到点 / 在跑但没插电 */
    if (!running) {
      setText('logHintText', '后台记录进程没有在跑，插拔充电器不会被记下来。点下面的按钮启动。');
    } else if (cur) {
      setText('logHintText', '正在记录这次充电（' + cur + '），拔出充电器后结束。');
    } else if (plugged) {
      setText('logHintText', '充电器已插上，正在等第一个采样点（最多 ' + (iv !== null ? iv : 10) + ' 秒）。');
    } else {
      setText('logHintText', '后台在跑，现在没插充电器 —— 插上就会自动开始记。已有 ' + cnt + ' 次记录。');
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
        if (s.pmax !== null) bits.push('峰值 ' + fmt(s.pmax, 1) + 'W');
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
        /* 还没 #end 的就是正在记的那一次，别显示成「—」 */
        dur.textContent = s.end ? durationText(s.start, s.end) : '进行中';

        li.appendChild(main);
        li.appendChild(dur);
        li.addEventListener('click', function () { openSession(s.name); });
        ul.appendChild(li);
      })(logList[i]);
    }
  }

  function loadLogs(silent) {
    var ul = $('logList');
    if (!silent) {
      if (ul) ul.innerHTML = '<li class="empty">读取中…</li>';
      $('logDetail').classList.add('hidden');
      $('logListCard').classList.remove('hidden');
    }

    /* 刷新时不要把列表清空重画：对比一下指纹，没变就一个节点都不动，
       变了再整块重画（列表最多 40 行，重建代价可以接受，但没必要每 5 秒来一次）。 */
    return exec('sh ' + moduleDir() + '/monitor.sh --logs', 30000)
      .then(function (res) {
        /* 采集脚本本身失败时必须说出来。以前不看 errno，stdout 空着就当成
           「0 个会话」，页面于是永远停在「读取中…」，谁也看不出是坏了。 */
        if (res.errno !== 0 && !res.stdout) {
          throw new Error((res.stderr || '').trim() || ('monitor.sh 返回 ' + res.errno));
        }
        var k = parseKV(res.stdout || '');
        var n = num(k['log.list_count']) || 0;

        var next = [];
        for (var i = 0; i < n; i++) {
          var nm = k['log.' + i + '.name'];
          if (!nm) continue;
          var pmw = num(k['log.' + i + '.pmax_mw']);
          next.push({
            name: nm,
            start: num(k['log.' + i + '.start']),
            end: num(k['log.' + i + '.end']),
            aborted: num(k['log.' + i + '.aborted']) === 1,
            samples: num(k['log.' + i + '.samples']) || 0,
            cap0: num(k['log.' + i + '.cap0']),
            cap1: num(k['log.' + i + '.cap1']),
            pmax: pmw !== null ? pmw / 1000 : null,
            tmax: tempC(k['log.' + i + '.temp_max'])
          });
        }

        renderLogState(k);

        /* 指纹比对：静默刷新时没变就一个节点都不动。但非静默（刚把列表清成
           「读取中…」）必须重画，否则会把自己刚写的占位留在屏幕上；
           「从来没画过」也不能算没变 —— 空列表的指纹也是空串。 */
        var sig = listSig(next);
        if (silent && logsDrawn && sig === logSig) return;
        logSig = sig;
        logsDrawn = true;
        logList = next;
        renderLogList();
      })
      .catch(function (err) {
        /* 静默刷新失败也不要把界面留在「读取中…」：只有真的已经画好过一次
           列表，才允许安静地失败（下一轮自己会恢复）。 */
        if (silent && logsDrawn) return;
        if (!ul) return;
        ul.innerHTML = '';
        var li = document.createElement('li');
        li.className = 'empty';
        li.textContent = '读取失败：' + (err && err.message ? err.message : err);
        ul.appendChild(li);
        logsDrawn = true;
      });
  }

  var logSig = '';
  var logsDrawn = false;

  function listSig(list) {
    var a = [];
    for (var i = 0; i < list.length; i++) {
      var s = list[i];
      a.push(s.name + ':' + s.end + ':' + s.samples + ':' + s.cap1 + ':' + s.pmax);
    }
    return a.join('|');
  }

  /* ---- 单个会话 ---- */

  function renderSession(s) {
    var pts = s.pts;
    var pw = [], tp = [], vt = [], cu = [], ct = [];
    var pmax = null, tmax = null, vmax = null, cmax = null, chmax = null;
    var c0 = null, c1 = null, cfirst = null, clast = null;
    var iSum = 0, iN = 0;

    for (var i = 0; i < pts.length; i++) {
      var p = pts[i];
      pw.push(p.power);
      tp.push(p.temp);
      vt.push(p.volt);
      cu.push(p.cur);
      ct.push(p.chgTemp);

      if (p.power !== null) {
        if (pmax === null || p.power > pmax) pmax = p.power;
        if (p.power > 0) { iSum += p.power; iN++; }
      }
      if (p.temp !== null && (tmax === null || p.temp > tmax)) tmax = p.temp;
      if (p.volt !== null && (vmax === null || p.volt > vmax)) vmax = p.volt;
      if (p.cur !== null && (cmax === null || p.cur > cmax)) cmax = p.cur;
      if (p.chgTemp !== null && (chmax === null || p.chgTemp > chmax)) chmax = p.chgTemp;
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
    if (iN > 0) rows.push(['平均功率', fmt(iSum / iN, 1) + ' W']);
    rows.push(['电压最高', fmt(vmax, 2) + ' V']);
    rows.push(['电流最大', fmt(cmax, 2) + ' A']);
    rows.push(['电池温度', (tmax !== null ? fmt(tmax, 1) + ' ℃' : '—')
      + (chmax !== null ? '（充电器 ' + fmt(chmax, 1) + ' ℃）' : '')]);
    rows.push(['采样点', pts.length + ' 个 · 约 ' + Math.round(s.interval || 0) + ' 秒一点']);
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
    setText('logVoltPeak',  fmt(vmax, 2));
    setText('logCurPeak',   fmt(cmax, 2));
    setText('logTempPeak',  fmt(tmax, 1));

    var slots = Math.max(pw.length, 2);
    drawSeries($('logChartPower'), pw, '#58a6ff', 0,    slots);
    drawSeries($('logChartVolt'),  vt, '#d29922', null, slots);
    drawSeries($('logChartCur'),   cu, '#a371f7', 0,    slots);
    drawSeries($('logChartTemp'),  tp, '#3fb950', null, slots);
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
          var pow = num(f[7]);
          var curA = (cur !== null) ? Math.abs(cur) / 1e6 : null;
          var voltV = (volt !== null) ? volt / 1e6 : null;
          var pw = (pow !== null && pow > 0) ? pow / 1e6
                 : ((curA !== null && voltV !== null) ? curA * voltV : null);
          pts.push({
            t: epoch,
            cap: num(f[1]),
            temp: tempC(f[2]),
            cur: curA,
            volt: voltV,
            power: pw,
            counter: num(f[5]),
            chgTemp: tempC(f[10])
          });
        }

        var st = num(k['session.start']);
        var en = num(k['session.end']);
        var iv = 0;
        if (pts.length > 1 && pts[0].t && pts[pts.length - 1].t) {
          iv = (pts[pts.length - 1].t - pts[0].t) / (pts.length - 1);
        } else if (st && en && pts.length > 1) {
          iv = (en - st) / (pts.length - 1);
        }

        logCur = {
          name: name,
          pts: pts,
          start: st,
          end: en,
          interval: iv,
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
  var logTimer = null;
  var autoOn = true;

  function refresh(full) {
    if (busy) return Promise.resolve();
    busy = true;
    var btn = $('btnRefresh');
    if (full && btn) btn.classList.add('busy');

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
        if (tab === 'live') redrawCharts();
      })
      .catch(function (err) {
        banner('采集失败：' + (err && err.message ? err.message : err), 'err');
      })
      .then(function () {
        busy = false;
        if (btn) btn.classList.remove('busy');
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

  /* 日志页的慢速刷新：只读日志目录，不碰 sysfs 也不读分区。
     打开会话详情时暂停列表刷新，免得把用户正在看的图刷没。 */
  var LOG_POLL_MS = 5000;

  function startLogTimer() {
    stopLogTimer();
    if (!autoOn) return;
    logTimer = setInterval(function () {
      if (document.hidden) return;
      if (tab !== 'logs') return;
      if (!$('logDetail').classList.contains('hidden')) return;
      loadLogs(true);
    }, LOG_POLL_MS);
  }

  function stopLogTimer() {
    if (logTimer) { clearInterval(logTimer); logTimer = null; }
  }

  /* --------------------------------------------------------- 运行修改 --- */

  var applying = false;
  var restoring = false;

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
    if (applying || restoring) return;
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

  /* --------------------------------------------------------- 恢复原厂 --- */

  function restoreOut(text) {
    var el = $('restoreOut');
    if (!el) return;
    el.classList.remove('hidden');
    el.textContent = text;
  }

  function doRestore() {
    if (restoring || applying) return;
    restoring = true;

    var btn = $('btnRestore');
    btn.disabled = true;
    btn.textContent = '正在写回…';
    stopTimer();
    restoreOut('开始写回原厂镜像，期间请不要退出页面…');

    exec('sh ' + moduleDir() + '/restore.sh -y', 240000)
      .then(function (res) {
        var out = (res.stdout || '');
        if (res.stderr) out += (out ? '\n' : '') + res.stderr;
        out += '\n--- 退出码: ' + res.errno + ' ---';
        restoreOut(out);
        if (res.errno === 0) {
          banner('已写回原厂 dtbo。<strong>重启后</strong>充电就回到官方限制了。', 'ok');
        } else {
          banner('写回未成功（退出码 ' + res.errno + '），详见下方输出。分区可能未被修改。', 'err');
        }
      })
      .catch(function (err) {
        var msg = err && err.message ? err.message : err;
        restoreOut('执行失败：' + msg);
        banner('写回失败：' + msg, 'err');
      })
      .then(function () {
        restoring = false;
        btn.disabled = false;
        btn.textContent = '恢复原厂 dtbo';
        return refresh(true);
      })
      .then(function () { if (autoOn) startTimer(); });
  }

  function bootRestore() {
    var btn = $('btnRestore');
    if (!btn) return;
    btn.addEventListener('click', function () {
      var d = last;
      var slot = d && d.part ? d.part : '当前槽位';
      var warn = '';
      if (d && d.headMatch === false) {
        warn = '<br><br><strong>当前分区已经不是本模块写入的那份了（系统大概更新过），'
             + '这份备份可能和当前系统对不上。真要不放心就用 fastboot 刷官方 dtbo。</strong>';
      }
      askConfirm(
        '将会把<b>备份的原厂镜像写回</b> <code>' + slot + '</code>，'
        + '之后充电限制就回到官方状态。'
        + '<br><br>写完会回读校验。<strong>这一步会真的改分区。</strong>'
        + '<br>写回后需要<b>重启</b>才生效。' + warn
      ).then(function (ok) {
        if (ok) doRestore();
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
    bootRestore();

    var toggle = $('autoToggle');
    toggle.addEventListener('change', function () {
      autoOn = toggle.checked;
      if (!autoOn) { stopTimer(); stopLogTimer(); return; }
      if (tab === 'logs') { loadLogs(); startLogTimer(); }
      else { refresh(false); startTimer(); }
    });

    document.addEventListener('visibilitychange', function () {
      if (document.hidden) { stopTimer(); stopLogTimer(); }
      else if (!autoOn) { /* 自动刷新关着，回来也不动 */ }
      else if (tab === 'logs') { loadLogs(); startLogTimer(); }
      else { refresh(false); startTimer(); }
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
