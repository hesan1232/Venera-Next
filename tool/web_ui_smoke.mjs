// Headless-Chrome smoke test for the bundled web client.
// Run from the repo root: node tool/web_ui_smoke.mjs
// It serves assets/web with a fake API on 18099 and drives Chrome over CDP.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import os from 'node:os';

const ROOT = process.cwd();
const WEB = path.join(ROOT, 'assets', 'web');
const PORT = 18099;
const CDP = 19333;

const svg = (label) => `<svg xmlns="http://www.w3.org/2000/svg" width="600" height="900"><rect width="600" height="900" fill="#7a2f4a"/><text x="300" y="450" font-size="80" fill="#fff" text-anchor="middle" font-family="sans-serif">${label}</text></svg>`;

const comics = [
  { key: 'demo:1', id: '1', source: 'demo', title: '测试漫画一', subtitle: '作者甲', tags: ['奇幻'], cover: '/img/cover-1.svg', local: false, progress: { chapter: 2, page: 2, maxChapter: 3, readChapters: ['1'], updatedAt: '2026-11-18T04:00:00Z' } },
  { key: 'demo:2', id: '2', source: 'demo', title: '测试漫画二', subtitle: '作者乙', tags: [], cover: '/img/cover-2.svg', local: false, favoriteAt: '2026-11-17T04:00:00Z' },
  { key: 'other:3', id: '3', source: 'other', title: 'Local Thing', subtitle: '', tags: [], cover: null, local: true },
];

const chapters = [1, 2, 3].map((i) => ({ index: i, id: 'ep_' + i, title: '第 ' + i + ' 话', group: null, groupTitle: null }));

// Search results whose cover is missing exercise the detail-backed fallback.
const noCover = { key: 'demo:9', id: '9', source: 'demo', title: '无封面测试', subtitle: '', tags: [], cover: null, local: false };
let searchCalls = 0;

function json(res, code, body) {
  const text = JSON.stringify(body);
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(text);
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  const p = url.pathname;

  if (p === '/' || p === '/index.html') return sendFile(res, 'index.html', 'text/html; charset=utf-8');
  if (p === '/app.js') return sendFile(res, 'app.js', 'text/javascript; charset=utf-8');
  if (p === '/style.css') return sendFile(res, 'style.css', 'text/css; charset=utf-8');
  if (p === '/favicon.svg') return sendFile(res, 'favicon.svg', 'image/svg+xml');

  if (p === '/api/sources') return json(res, 200, { sources: [
    { key: 'demo', name: 'Demo', searchable: true, local: false },
    { key: 'other', name: 'Other', searchable: false, local: true },
  ] });
  if (p === '/api/_debug') return json(res, 200, { searchCalls });
  if (p === '/api/bookshelf') return json(res, 200, { comics, total: comics.length });
  if (p === '/api/search') {
    searchCalls++;
    return json(res, 200, { comics: [comics[0], noCover], source: 'all', page: 1, maxPage: 1, next: null, hasMore: false });
  }
  if (p.startsWith('/api/comic/')) {
    const [source, id] = p.split('/').slice(3).map(decodeURIComponent);
    const comic = comics.find((c) => c.source === source && c.id === id);
    return json(res, 200, {
      ...comic,
      chapters,
      groups: [],
      url: 'https://example.com/' + id,
      stars: 4.5,
      recommendations: [],
      description: '这是一段用于测试的简介。'.repeat(4),
    });
  }
  if (p.startsWith('/api/chapter/')) {
    const parts = p.split('/').slice(3).map(decodeURIComponent);
    const chapter = Number(parts[2]);
    return json(res, 200, {
      chapter,
      chapterId: 'ep_' + chapter,
      title: '第 ' + chapter + ' 话',
      count: 2,
      images: ['/img/p' + chapter + '-1.svg', '/img/p' + chapter + '-2.svg'],
    });
  }
  if (p === '/api/progress/' || p.startsWith('/api/progress/')) {
    if (req.method === 'PUT') {
      req.resume();
      return json(res, 200, { progress: { chapter: 1, page: 1 } });
    }
    return json(res, 200, { progress: { chapter: 2, page: 2 } });
  }
  if (p === '/api/image' || p.startsWith('/api/cover/')) {
    res.writeHead(200, { 'Content-Type': 'image/svg+xml', 'Cache-Control': 'public, max-age=60' });
    return res.end(svg(p.startsWith('/api/cover/') ? 'COVER' : 'IMG'));
  }
  if (p.startsWith('/img/')) {
    res.writeHead(200, { 'Content-Type': 'image/svg+xml' });
    return res.end(svg(p.replace('/img/', '').replace('.svg', '')));
  }
  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('not found: ' + p);
});

function sendFile(res, name, type) {
  const file = path.join(WEB, name);
  if (!fs.existsSync(file)) {
    res.writeHead(404);
    return res.end('missing ' + name);
  }
  res.writeHead(200, { 'Content-Type': type });
  res.end(fs.readFileSync(file));
}

class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.id = 0;
    this.pending = new Map();
    this.errors = [];
    ws.addEventListener('message', (event) => {
      const msg = JSON.parse(event.data);
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
        return;
      }
      if (msg.method === 'Runtime.exceptionThrown') {
        this.errors.push('exception: ' + (msg.params.exceptionDetails.exception?.description || msg.params.exceptionDetails.text));
      }
      if (msg.method === 'Runtime.consoleAPICalled' && msg.params.type === 'error') {
        this.errors.push('console: ' + msg.params.args.map((a) => a.value ?? a.description).join(' '));
      }
      if (msg.method === 'Log.entryAdded' && msg.params.entry.level === 'error') {
        this.errors.push('log: ' + msg.params.entry.text + ' ' + (msg.params.entry.url || ''));
      }
    });
  }

  send(method, params = {}) {
    const id = ++this.id;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
  }

  async evaluate(expression) {
    const result = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.text);
    return result.result.value;
  }
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

async function fetchJson(url) {
  const res = await fetch(url);
  return res.json();
}

async function main() {
  await new Promise((r) => server.listen(PORT, '127.0.0.1', r));

  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'venera-ui-'));
  const chrome = spawn('C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe', [
    '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    '--disable-extensions', '--hide-scrollbars',
    '--remote-debugging-port=' + CDP, '--user-data-dir=' + profile, 'about:blank',
  ], { stdio: 'ignore' });

  let targets = null;
  for (let i = 0; i < 60; i++) {
    try {
      targets = await fetchJson('http://127.0.0.1:' + CDP + '/json/list');
      if (targets.length) break;
    } catch (_) { /* not up yet */ }
    await wait(250);
  }
  if (!targets || !targets.length) throw new Error('chrome did not start');

  const page = targets.find((t) => t.type === 'page');
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve);
    ws.addEventListener('error', reject);
  });
  const cdp = new Cdp(ws);
  await cdp.send('Runtime.enable');
  await cdp.send('Log.enable');
  await cdp.send('Page.enable');

  const results = [];
  const check = (name, ok, detail) => {
    results.push({ name, ok, detail });
    console.log((ok ? 'PASS ' : 'FAIL ') + name + (detail === undefined ? '' : ' → ' + JSON.stringify(detail)));
  };

  async function goto(hash, expectSelector, expectCount) {
    await cdp.evaluate(`location.hash = ${JSON.stringify(hash)}`);
    await wait(1400);
    const count = await cdp.evaluate(`document.querySelectorAll(${JSON.stringify(expectSelector)}).length`);
    check('route ' + hash + ' renders ' + expectSelector, count === expectCount, count);
  }

  await cdp.send('Page.navigate', { url: 'http://127.0.0.1:' + PORT + '/' });
  await wait(1800);

  const title = await cdp.evaluate('document.title');
  check('shell loads', typeof title === 'string', title);
  const cards = await cdp.evaluate("document.querySelectorAll('.card').length");
  check('library renders cards', cards === 3, cards);
  const coverTag = await cdp.evaluate("document.querySelector('.card .cover img') ? 'img' : 'none'");
  check('cover image element present', coverTag === 'img', coverTag);
  const meta = await cdp.evaluate("document.querySelector('.card .card-meta').textContent");
  check('card meta shows chapter', /第 2 话/.test(meta), meta);

  await goto('#/comic/demo%3A1', '.chapter', 3);
  const heroTitle = await cdp.evaluate("document.querySelector('.hero h1').textContent");
  check('detail shows title', heroTitle === '测试漫画一', heroTitle);
  const continueText = await cdp.evaluate("document.querySelector('.hero-actions button').textContent");
  check('continue reading button', /继续阅读/.test(continueText), continueText);

  await goto('#/read/demo%3A1/2/2', '.reader-scroll img', 2);
  const label = await cdp.evaluate("document.querySelector('.reader-bars.bottom .reader-meta').textContent");
  check('reader page label', label.trim() === '2 / 2', label);
  const selected = await cdp.evaluate("document.querySelector('.reader-select').value");
  check('reader chapter select', selected === '2', selected);
  const selectTheme = await cdp.evaluate(`(() => {
    document.documentElement.setAttribute('data-theme', 'light');
    const el = document.querySelector('.reader-select');
    const style = getComputedStyle(el);
    const option = getComputedStyle(el.options[0]);
    const result = {
      scheme: style.colorScheme,
      color: style.color,
      optionColor: option.color,
      optionBg: option.backgroundColor,
    };
    document.documentElement.removeAttribute('data-theme');
    return result;
  })()`);
  check('reader select stays dark under light theme',
    selectTheme.scheme === 'dark' &&
      selectTheme.color === 'rgb(255, 255, 255)' &&
      selectTheme.optionColor === 'rgb(255, 255, 255)',
    selectTheme);

  await cdp.evaluate("window.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft' }))");
  await wait(700);
  const afterLeft = await cdp.evaluate("document.querySelector('.reader-bars.bottom .reader-meta').textContent");
  check('keyboard turns page', afterLeft.trim() === '1 / 2', afterLeft);

  // Horizontal paging must jump immediately, with no smooth animation.
  const switched = await cdp.evaluate(`(() => {
    const button = [...document.querySelectorAll('.reader-bars.bottom button')]
      .find((e) => e.textContent === '纵向');
    if (!button) return false;
    button.click();
    return document.querySelector('.reader-scroll').classList.contains('horizontal');
  })()`);
  check('reader can switch to horizontal', switched === true, switched);
  await cdp.evaluate("window.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight' }))");
  await wait(120);
  const horizontalTurn = await cdp.evaluate(`(() => {
    const scroller = document.querySelector('.reader-scroll');
    return { left: scroller.scrollLeft, width: scroller.clientWidth };
  })()`);
  check('horizontal page turn is instant',
    Math.abs(horizontalTurn.left - horizontalTurn.width) <= 2,
    horizontalTurn);
  await wait(420);
  const horizontalStable = await cdp.evaluate("document.querySelector('.reader-scroll').scrollLeft");
  check('horizontal page does not bounce back',
    Math.abs(horizontalStable - horizontalTurn.left) <= 2,
    { first: horizontalTurn.left, later: horizontalStable });

  await cdp.evaluate("window.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight' }))");
  await wait(1600);
  const nextChapter = await cdp.evaluate("document.querySelector('.reader-select').value");
  check('page turn at end moves to next chapter', nextChapter === '3', nextChapter);

  await cdp.evaluate("window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))");
  await wait(900);
  const backToDetail = await cdp.evaluate("!!document.querySelector('.hero h1')");
  check('escape returns to detail', backToDetail === true, backToDetail);

  await goto('#/api', '.api-group', 3);
  await goto('#/sources', '.api-item', 2);
  await goto('#/search?q=%E6%B5%8B%E8%AF%95&source=all', '.card', 2);
  const coverFallback = await cdp.evaluate(`(() => {
    const cards = [...document.querySelectorAll('.card')];
    const card = cards.find((e) => e.textContent.includes('无封面测试'));
    const img = card && card.querySelector('.cover img');
    return img ? img.getAttribute('src') : null;
  })()`);
  check('coverless result uses detail-backed cover',
    !!coverFallback && coverFallback.includes('/api/cover/demo/9'), coverFallback);

  const callsBefore = (await fetchJson('http://127.0.0.1:' + PORT + '/api/_debug')).searchCalls;
  await cdp.evaluate(`(() => {
    const card = [...document.querySelectorAll('.card')]
      .find((e) => e.textContent.includes('测试漫画一'));
    card.click();
  })()`);
  await wait(700);
  check('search result opens detail', await cdp.evaluate("!!document.querySelector('.hero h1')"), true);
  await cdp.evaluate('history.back()');
  await wait(700);
  const restored = await cdp.evaluate("document.querySelectorAll('.card').length");
  const callsAfter = (await fetchJson('http://127.0.0.1:' + PORT + '/api/_debug')).searchCalls;
  check('returning from detail restores results', restored === 2, restored);
  check('restored results do not re-search', callsAfter === callsBefore, { callsBefore, callsAfter });

  await cdp.evaluate("location.hash = '#/search'");
  await wait(600);
  const historyCount = await cdp.evaluate("document.querySelectorAll('.search-history .chip').length");
  check('recent searches are listed', historyCount >= 1, historyCount);

  await cdp.evaluate("location.hash = '#/library'");
  await wait(800);
  const filterWorks = await cdp.evaluate(`(() => {
    const input = document.querySelector('.toolbar input[type=search]');
    input.value = '二';
    input.dispatchEvent(new Event('input', { bubbles: true }));
    return document.querySelectorAll('.card').length;
  })()`);
  check('library filter narrows the grid', filterWorks === 1, filterWorks);

  check('no runtime errors', cdp.errors.length === 0, cdp.errors);

  const failed = results.filter((r) => !r.ok);
  console.log('\n' + (failed.length ? failed.length + ' FAILED' : 'ALL ' + results.length + ' CHECKS PASSED'));

  ws.close();
  chrome.kill();
  server.close();
  process.exit(failed.length ? 1 : 0);
}

main().catch((error) => {
  console.error('SMOKE ERROR', error);
  process.exit(2);
});
