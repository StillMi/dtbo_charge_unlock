'use strict';

// Node-only regression probes. Reads production app.js; no browser or shell bridge.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const appPath = path.resolve(__dirname, '../webroot/app.js');
let source = fs.readFileSync(appPath, 'utf8');
assert.match(source, /refresh\(true\)\.then\(startTimer\);/);
// Skip only boot-time live collection: these probes exercise the logs view.
source = source.replace('refresh(true).then(startTimer);', '/* live boot collection omitted by test */');
assert.match(source, /\}\)\(\);\s*$/);
source = source.replace(/\}\)\(\);\s*$/, `window.__test = {
  boot, loadLogs, startLogTimer, openSession, backToList, listSig, setLogMax,
  getLocks: function () { return {busy: logBusy, maxBusy: logMaxBusy}; },
  setTab: function (value) { tab = value; },
  setLogBusy: function (value) { logBusy = value; },
  getList: function () { return logList; },
  getCur: function () { return logCur; }
};})();`);

function harness() {
  const elements = new Map(), pending = [], intervals = new Map(), timeouts = new Map();
  const documentEvents = new Map(), windowEvents = new Map();
  let sequence = 0, canvasDraws = 0;
  function element(id) {
    if (elements.has(id)) return elements.get(id);
    const classes = new Set(id === 'logDetail' ? ['hidden'] : []);
    const events = new Map();
    let ownText = '', html = '';
    const node = {
      id, style: {}, className: '', children: [], options: [{value: '10'}], value: '10',
      checked: true, clientWidth: 300, clientHeight: 72, tagName: 'DIV',
      classList: {
        add: value => classes.add(value), remove: value => classes.delete(value),
        contains: value => classes.has(value),
        toggle(value, enabled) { if (enabled === undefined) enabled = !classes.has(value); if (enabled) classes.add(value); else classes.delete(value); }
      },
      appendChild(child) { node.children.push(child); child.parentNode = node; return child; },
      addEventListener(name, fn) { events.set(name, fn); },
      removeEventListener(name) { events.delete(name); },
      dispatch(name) { assert.ok(events.has(name), 'missing element event: ' + name); events.get(name).call(node, {}); },
      getContext() {
        return new Proxy({}, {get(_, name) {
          if (name === 'clearRect') return () => { canvasDraws++; };
          if (name === 'createLinearGradient') return () => ({addColorStop() {}});
          return () => {};
        }});
      }
    };
    Object.defineProperties(node, {
      textContent: {get() { return ownText + node.children.map(child => child.textContent).join(''); }, set(value) { ownText = String(value); node.children = []; }},
      innerHTML: {get() { return html; }, set(value) { html = String(value); ownText = ''; node.children = []; }}
    });
    elements.set(id, node);
    return node;
  }
  const document = {
    readyState: 'loading', hidden: false,
    getElementById: element, querySelectorAll: () => [],
    createElement: tag => { const node = element('created-' + (++sequence)); node.tagName = tag.toUpperCase(); return node; },
    addEventListener: (name, fn) => documentEvents.set(name, fn)
  };
  const context = {
    console, Promise, Date, Math, Number, String, Object, isFinite, document,
    setTimeout(fn, delay) { const id = ++sequence; timeouts.set(id, {fn, delay}); return id; },
    clearTimeout: id => timeouts.delete(id),
    setInterval(fn) { const id = ++sequence; intervals.set(id, fn); return id; },
    clearInterval: id => intervals.delete(id),
    requestAnimationFrame: fn => fn(),
    addEventListener: (name, fn) => windowEvents.set(name, fn),
    ksu: {exec(command, options, callback) { pending.push({command, callback, settled: false}); }}
  };
  context.window = context;
  vm.runInNewContext(source, context, {filename: appPath});
  return {
    api: context.__test, document, element, pending,
    tick() { for (const fn of [...intervals.values()]) fn(); },
    runResize() { windowEvents.get('resize')(); for (const [id, timer] of [...timeouts]) if (timer.delay === 150) { timeouts.delete(id); timer.fn(); } },
    visibility(hidden) { document.hidden = hidden; documentEvents.get('visibilitychange')(); },
    requests(fragment) { return pending.filter(item => item.command.includes(fragment)); },
    reply(request, text, errno = 0, stderr = '') {
      assert.ok(request && !request.settled, 'reply must target one outstanding request');
      request.settled = true;
      context[request.callback](errno, text, stderr);
    },
    getDraws: () => canvasDraws
  };
}
const drain = () => new Promise(resolve => setImmediate(resolve));
const list = (name, samples = 1) => `log.list_count=1\nlog_count=1\nlog_list_done=1\nlog_dir_ok=1\nlog_running=1\nlog.0.name=${name}\nlog.0.samples=${samples}\nlog.0.start=1\n`;
const session = (start = 1) => `session.count=0\nsession.start=${start}\nsession.end=${start + 1}\n`;
const tests = [];
function test(name, fn) { tests.push({name, fn}); }

test('single-flight: repeated 5-second ticks share one list request', async () => {
  const h = harness(); h.api.setTab('logs'); h.api.startLogTimer(); h.tick(); h.tick(); h.tick();
  assert.equal(h.requests('--logs').length, 1);
  const first = h.api.loadLogs(true), second = h.api.loadLogs(true);
  assert.equal(first, second);
  h.reply(h.requests('--logs')[0], list('current.log')); await drain();
  h.tick(); assert.equal(h.requests('--logs').length, 2);
});

test('mutation revalidation: coalesced refresh schedules exactly one fresh read', async () => {
  const h = harness(); h.api.loadLogs(true); h.api.setLogBusy(true);
  h.api.loadLogs(true); h.api.loadLogs(true);
  h.reply(h.requests('--logs')[0], list('old.log')); await drain();
  assert.equal(h.requests('--logs').length, 2);
  h.reply(h.requests('--logs')[1], list('fresh.log')); await drain();
  assert.equal(h.requests('--logs').length, 2);
  assert.equal(h.api.getList()[0].name, 'fresh.log');
});

test('A/B stale success: older detail response cannot replace the newer selection', async () => {
  const h = harness(); h.api.openSession('A.log'); h.api.backToList(); h.api.openSession('B.log');
  h.reply(h.requests('--log ')[1], session(20)); await drain();
  h.reply(h.requests('--log ')[0], session(1)); await drain();
  assert.equal(h.element('logTitle').textContent, 'B'); assert.equal(h.api.getCur().name, 'B.log');
});

test('A/B stale error: older rejected detail cannot replace current stats', async () => {
  const h = harness(); h.api.openSession('A.log'); h.api.openSession('B.log');
  h.reply(h.requests('--log ')[1], session(20)); await drain();
  const stats = h.element('logStats').textContent;
  h.reply(h.requests('--log ')[0], 'log_err=stale A failure\n', 1); await drain();
  assert.equal(h.element('logStats').textContent, stats); assert.equal(h.api.getCur().name, 'B.log');
});

test('back invalidates pending detail; resize leaves returned list intact', async () => {
  const h = harness(); h.api.boot(); h.api.setTab('logs');
  h.api.openSession('A.log'); h.api.backToList();
  h.reply(h.requests('--log ')[0], session()); await drain();
  const draws = h.getDraws(); h.runResize();
  assert.equal(h.api.getCur(), null); assert.equal(h.getDraws(), draws);
  assert.equal(h.element('logDetail').classList.contains('hidden'), true);
});

test('resize during B load does not redraw previously loaded A', async () => {
  const h = harness(); h.api.boot(); h.api.setTab('logs'); h.api.openSession('A.log');
  h.reply(h.requests('--log ')[0], session()); await drain(); h.api.openSession('B.log');
  const draws = h.getDraws(); h.runResize();
  assert.equal(h.api.getCur(), null); assert.equal(h.getDraws(), draws);
  assert.equal(h.element('logStats').textContent, '读取中…');
});

test('visibility and auto refresh restoration preserve an open detail', async () => {
  const h = harness(); h.api.boot(); h.api.setTab('logs'); h.api.openSession('A.log');
  h.reply(h.requests('--log ')[0], session()); await drain();
  h.visibility(true); h.visibility(false); h.visibility(false);
  assert.equal(h.requests('--logs').length, 1);
  h.reply(h.requests('--logs')[0], list('A.log')); await drain();
  assert.equal(h.element('logDetail').classList.contains('hidden'), false);
  assert.equal(h.api.getCur().name, 'A.log');
  const toggle = h.element('autoToggle'); toggle.checked = false; toggle.dispatch('change');
  toggle.checked = true; toggle.dispatch('change');
  h.reply(h.requests('--logs')[1], list('A.log')); await drain();
  assert.equal(h.element('logDetail').classList.contains('hidden'), false);
  h.tick(); assert.equal(h.requests('--logs').length, 2, 'detail must suppress periodic list scans');
});

test('detail errors surface errno/log_err rather than rendering an empty session', async () => {
  const h = harness(); h.api.openSession('missing.log');
  h.reply(h.requests('--log ')[0], 'log_err=missing session\n', 1); await drain();
  assert.equal(h.api.getCur(), null); assert.match(h.element('logStats').textContent, /missing session/);
});

test('list signature tracks every visible summary field', async () => {
  const h = harness(); const row = {name:'a',start:1,end:2,aborted:false,samples:3,cap0:10,cap1:20,pmax:5,tmax:30};
  for (const key of Object.keys(row)) {
    const changed = {...row, [key]: key === 'name' ? 'b' : key === 'aborted' ? true : row[key] + 1};
    assert.notEqual(h.api.listSig([row]), h.api.listSig([changed]), key + ' must invalidate signature');
  }
});

test('retention locks last until command and list response finish, including failure', async () => {
  for (const failure of [false, true]) {
    const h = harness();
    const promise = h.api.setLogMax('40');
    assert.equal(h.api.getLocks().busy, true);
    assert.equal(h.api.getLocks().maxBusy, true);
    assert.equal(h.requests('--setmax').length, 1);
    await h.api.setLogMax('80');
    assert.equal(h.requests('--setmax').length, 1);
    h.reply(h.requests('--setmax')[0], failure ? 'del_err=read only\n' : 'del_ok=1\ndel_count=0\n', failure ? 1 : 0);
    await drain();
    assert.equal(h.api.getLocks().busy, true);
    assert.equal(h.api.getLocks().maxBusy, false);
    h.reply(h.requests('--logs')[0], list('A.log') + 'log_max=' + (failure ? '10' : '40') + '\n');
    await promise;
    assert.equal(h.element('logMax').value, failure ? '10' : '40');
    assert.equal(h.api.getLocks().busy, false);
    assert.equal(h.api.getLocks().maxBusy, false);
  }
});

(async () => {
  let failed = 0;
  for (const {name, fn} of tests) {
    try { await fn(); console.log('PASS ' + name); }
    catch (error) { failed++; console.error('FAIL ' + name + '\n' + error.stack); }
  }
  console.log(`${tests.length - failed}/${tests.length} probes passed`);
  process.exitCode = failed ? 1 : 0;
})();
