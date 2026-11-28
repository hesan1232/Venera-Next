(() => {
  'use strict';

  // ---------------------------------------------------------------- helpers
  const app = document.getElementById('app');
  const loadingEl = document.getElementById('loading');
  const toastEl = document.getElementById('toast');
  const crumbEl = document.getElementById('crumb');
  const topActionsEl = document.getElementById('top-actions');
  const backBtn = document.getElementById('back');
  const authDialog = document.getElementById('auth-dialog');
  const authInput = document.getElementById('auth-input');

  const state = {
    token: localStorage.getItem('venera-web-token') || '',
    theme: localStorage.getItem('venera-web-theme') || 'auto',
    sources: null,
    shelf: null,
    shelfAt: 0,
    details: new Map(),
    reader: null,
    route: null,
    version: 0,
    ui: { q: '', source: 'all', sort: 'recent' },
    // Search results are kept so returning from a comic restores the exact
    // page instead of firing the whole cross-source search again.
    searchCache: new Map(),
  };

  const SEARCH_HISTORY_KEY = 'venera-web-search-history';

  function searchHistory() {
    try {
      const items = JSON.parse(localStorage.getItem(SEARCH_HISTORY_KEY) || '[]');
      return Array.isArray(items)
        ? items.filter((e) => e && typeof e.q === 'string').slice(0, 12)
        : [];
    } catch (_) {
      return [];
    }
  }

  function rememberSearch(q, source) {
    const items = searchHistory().filter(
      (e) => !(e.q === q && (e.source || 'all') === source),
    );
    items.unshift({ q, source, at: Date.now() });
    try {
      localStorage.setItem(SEARCH_HISTORY_KEY, JSON.stringify(items.slice(0, 12)));
    } catch (_) { /* private mode */ }
  }

  const SOURCE_NAMES = new Map();

  function h(tag, attrs, children) {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs || {})) {
      if (value === null || value === undefined || value === false) continue;
      if (key === 'class') node.className = value;
      else if (key === 'text') node.textContent = value;
      else if (key === 'html') node.innerHTML = value;
      else if (key.startsWith('on') && typeof value === 'function') {
        node.addEventListener(key.slice(2).toLowerCase(), value);
      } else if (key === 'value') node.value = value;
      else if (key === 'selected') node.selected = !!value;
      else node.setAttribute(key, value === true ? '' : value);
    }
    for (const child of [].concat(children || [])) {
      if (child === null || child === undefined || child === false) continue;
      node.appendChild(typeof child === 'string' ? document.createTextNode(child) : child);
    }
    return node;
  }

  function clear(node) {
    while (node.firstChild) node.removeChild(node.firstChild);
  }

  let toastTimer;
  function toast(message) {
    toastEl.textContent = message;
    toastEl.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { toastEl.hidden = true; }, 2800);
  }

  let loadingCount = 0;
  function busy(on) {
    loadingCount = Math.max(0, loadingCount + (on ? 1 : -1));
    loadingEl.hidden = loadingCount === 0;
  }

  function withToken(url) {
    if (!url) return url;
    if (!state.token) return url;
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    return url + (url.includes('?') ? '&' : '?') + 'token=' + encodeURIComponent(state.token);
  }

  function safeDecode(value) {
    try { return decodeURIComponent(value); } catch (_) { return value; }
  }

  function sourceName(key) {
    return SOURCE_NAMES.get(key) || key;
  }

  function percentOf(comic) {
    const progress = comic.progress;
    if (!progress || !progress.maxChapter) return 0;
    return Math.max(0, Math.min(100, Math.round((progress.chapter / progress.maxChapter) * 100)));
  }

  // ------------------------------------------------------------------ theme
  function applyTheme() {
    const root = document.documentElement;
    if (state.theme === 'auto') root.removeAttribute('data-theme');
    else root.setAttribute('data-theme', state.theme);
    const label = { auto: '自动', dark: '深色', light: '浅色' }[state.theme];
    const btn = document.getElementById('theme-btn');
    if (btn) btn.textContent = '主题 · ' + label;
  }

  function cycleTheme() {
    state.theme = { auto: 'dark', dark: 'light', light: 'auto' }[state.theme];
    localStorage.setItem('venera-web-theme', state.theme);
    applyTheme();
  }

  // ---------------------------------------------------------------- network
  async function api(path, options = {}) {
    const headers = Object.assign({}, options.headers || {});
    if (state.token) headers.Authorization = 'Bearer ' + state.token;
    let response;
    try {
      response = await fetch(path, Object.assign({}, options, { headers }));
    } catch (error) {
      throw new Error('无法连接到应用：' + error.message);
    }
    if (response.status === 401) {
      askToken();
      throw new Error('需要访问令牌');
    }
    if (response.status === 204) return null;
    if (!response.ok) {
      let message = 'HTTP ' + response.status;
      try {
        const body = await response.json();
        if (body.error) message = body.error;
      } catch (_) { /* keep status */ }
      throw new Error(message);
    }
    return response.json();
  }

  function askToken() {
    authInput.value = state.token;
    if (!authDialog.open) authDialog.showModal();
  }

  document.getElementById('auth-form').addEventListener('submit', (event) => {
    if (event.target.value === 'cancel') return;
    event.preventDefault();
    state.token = authInput.value.trim();
    if (state.token) localStorage.setItem('venera-web-token', state.token);
    else localStorage.removeItem('venera-web-token');
    authDialog.close();
    state.shelf = null;
    state.details.clear();
    render(true);
  });
  document.getElementById('auth-btn').addEventListener('click', askToken);
  document.getElementById('theme-btn').addEventListener('click', cycleTheme);

  async function ensureSources() {
    if (state.sources) return state.sources;
    const data = await api('/api/sources');
    state.sources = data.sources || [];
    for (const source of state.sources) SOURCE_NAMES.set(source.key, source.name);
    return state.sources;
  }

  async function loadShelf(force) {
    const fresh = state.shelf && Date.now() - state.shelfAt < 30000;
    if (state.shelf && fresh && !force) return state.shelf;
    const [data] = await Promise.all([api('/api/bookshelf'), ensureSources().catch(() => null)]);
    state.shelf = data.comics || [];
    state.shelfAt = Date.now();
    return state.shelf;
  }

  // ----------------------------------------------------------------- router
  function parseRoute() {
    const raw = (location.hash || '#/library').replace(/^#/, '');
    const [pathPart, queryPart] = raw.split('?');
    const parts = pathPart.split('/').filter(Boolean).map(safeDecode);
    const query = new URLSearchParams(queryPart || '');
    if (!parts.length) return { name: 'library' };
    const name = parts[0];
    if (name === 'comic' && parts.length > 1) return { name, key: parts.slice(1).join('/') };
    if (name === 'read' && parts.length > 1) {
      return {
        name, key: parts[1],
        chapter: Math.max(1, Number(parts[2]) || 1),
        page: Math.max(1, Number(parts[3]) || 1),
      };
    }
    if (name === 'search') {
      return { name, q: query.get('q') || '', source: query.get('source') || 'all' };
    }
    if (['library', 'sources', 'api'].includes(name)) return { name };
    return { name: 'library' };
  }

  function go(hash) {
    if (location.hash === hash) render();
    else location.hash = hash;
  }

  function setCrumb(items) {
    clear(crumbEl);
    items.forEach((item, index) => {
      if (index) crumbEl.appendChild(h('span', { text: '/' }));
      crumbEl.appendChild(
        item.href
          ? h('a', { href: item.href, text: item.text, class: 'link-btn' })
          : h('b', { text: item.text }),
      );
    });
  }

  function setTopActions(nodes) {
    clear(topActionsEl);
    for (const node of nodes || []) topActionsEl.appendChild(node);
  }

  function setActiveNav(name) {
    for (const item of document.querySelectorAll('.nav-item')) {
      item.classList.toggle('active', item.dataset.route === name);
    }
  }

  function skeletons(container, count) {
    const grid = h('div', { class: 'skeleton-grid' });
    for (let i = 0; i < count; i++) {
      grid.appendChild(h('div', {}, [
        h('div', { class: 'skeleton cover' }),
        h('div', { class: 'skeleton line' }),
        h('div', { class: 'skeleton line short' }),
      ]));
    }
    container.appendChild(grid);
  }

  // ------------------------------------------------------------------ cards
  // Search results often carry a stale or empty cover URL. The detail-backed
  // endpoint always resolves the current one through the source runtime, so
  // use it both when the search result has no cover and as a retry on error.
  function coverSrc(comic, fallback) {
    if (!fallback && comic.cover) return withToken(comic.cover);
    if (comic.source && comic.id) {
      return withToken('/api/cover/' + encodeURIComponent(comic.source)
        + '/' + encodeURIComponent(comic.id));
    }
    return null;
  }

  function coverImage(comic) {
    const image = h('img', {
      src: coverSrc(comic, false) || coverSrc(comic, true),
      alt: '', loading: 'lazy', draggable: 'false',
      onerror: (event) => {
        const el = event.target;
        if (el.dataset.fallback !== '1') {
          const fallback = coverSrc(comic, true);
          if (fallback && fallback !== el.getAttribute('src')) {
            el.dataset.fallback = '1';
            el.setAttribute('src', fallback);
            return;
          }
        }
        el.remove();
      },
    });
    return image;
  }

  function comicCard(comic, onOpen) {
    const cover = h('div', { class: 'cover' });
    cover.appendChild(h('div', { class: 'fallback', text: comic.title }));
    if (coverSrc(comic, false) || coverSrc(comic, true)) {
      cover.appendChild(coverImage(comic));
    }
    if (comic.local) cover.appendChild(h('span', { class: 'badge local', text: '本地' }));
    else if (comic.source) {
      cover.appendChild(h('span', { class: 'badge', text: sourceName(comic.source) }));
    }
    const percent = percentOf(comic);
    if (percent > 0) {
      cover.appendChild(h('div', { class: 'cover-progress' }, [
        h('i', { style: 'width:' + percent + '%' }),
      ]));
    }
    // Komga shows a circular action on hover; keep it lightweight here.
    const progress = comic.progress;
    cover.appendChild(h('div', { class: 'cover-hover' }, [
      h('button', {
        class: 'quick-open', text: progress ? '继续' : '打开',
        title: progress ? '继续阅读' : '查看详情',
        onclick: (event) => { event.stopPropagation(); onOpen(); },
      }),
    ]));
    const meta = progress
      ? '第 ' + progress.chapter + ' 话' + (progress.page ? ' · ' + progress.page + ' 页' : '')
      : (comic.subtitle || sourceName(comic.source));
    return h('article', { class: 'card', onclick: onOpen, title: comic.title }, [
      cover,
      h('div', { class: 'card-body' }, [
        h('div', { class: 'card-title', text: comic.title }),
        h('div', { class: 'card-meta', text: meta }),
      ]),
    ]);
  }

  function openComic(comic) {
    go('#/comic/' + encodeURIComponent(comic.source + ':' + comic.id));
  }

  // ---------------------------------------------------------------- library
  async function renderLibrary(version) {
    setCrumb([{ text: '书架' }]);
    setActiveNav('library');
    backBtn.hidden = true;
    setTopActions([
      h('button', {
        class: 'soft', text: '刷新',
        onclick: () => { state.shelf = null; render(true); },
      }),
    ]);

    clear(app);
    app.appendChild(h('div', { class: 'page-head' }, [
      h('h1', { text: '书架' }),
      h('span', { class: 'count', id: 'shelf-count', text: '' }),
    ]));
    const grid = h('div', { class: 'grid', id: 'shelf-grid' });
    const sourceSelect = h('select', { onchange: (event) => { state.ui.source = event.target.value; paint(); } });
    sourceSelect.appendChild(h('option', { value: 'all', text: '全部来源' }));
    const toolbar = h('div', { class: 'toolbar' }, [
      h('div', { class: 'grow' }, [
        h('input', {
          type: 'search', placeholder: '筛选书架…', value: state.ui.q,
          oninput: (event) => { state.ui.q = event.target.value; paint(); },
        }),
      ]),
      sourceSelect,
      (() => {
        const select = h('select', { onchange: (event) => { state.ui.sort = event.target.value; paint(); } });
        for (const [value, label] of [['recent', '最近阅读'], ['added', '最近收藏'], ['title', '名称'], ['progress', '进度']]) {
          select.appendChild(h('option', { value, text: label }));
        }
        select.value = state.ui.sort;
        return select;
      })(),
    ]);
    app.appendChild(toolbar);
    app.appendChild(grid);
    skeletons(grid, 12);

    let shelf;
    try {
      shelf = await loadShelf();
    } catch (error) {
      if (version !== state.version) return;
      clear(grid);
      grid.appendChild(h('div', { class: 'empty', text: error.message }));
      return;
    }
    if (version !== state.version) return;

    for (const source of state.sources || []) SOURCE_NAMES.set(source.key, source.name);
    for (const source of state.sources || []) {
      sourceSelect.appendChild(h('option', { value: source.key, text: source.name }));
    }
    if (!Array.from(sourceSelect.options).some((option) => option.value === state.ui.source)) {
      state.ui.source = 'all';
    }
    sourceSelect.value = state.ui.source;

    function paint() {
      if (!shelf) return;
      clear(grid);
      const keyword = state.ui.q.trim().toLowerCase();
      let items = shelf.filter((comic) => {
        if (state.ui.source !== 'all' && comic.source !== state.ui.source) return false;
        if (!keyword) return true;
        return (comic.title || '').toLowerCase().includes(keyword) ||
          (comic.subtitle || '').toLowerCase().includes(keyword);
      });
      if (state.ui.sort === 'recent') {
        items = items.slice().sort((a, b) => (b.progress && b.progress.updatedAt || '').localeCompare(a.progress && a.progress.updatedAt || ''));
      } else if (state.ui.sort === 'added') {
        items = items.slice().sort((a, b) => (b.favoriteAt || '').localeCompare(a.favoriteAt || ''));
      } else if (state.ui.sort === 'progress') {
        items = items.slice().sort((a, b) => percentOf(b) - percentOf(a));
      } else {
        items = items.slice().sort((a, b) => (a.title || '').localeCompare(b.title || '', 'zh-Hans-CN'));
      }
      document.getElementById('shelf-count').textContent =
        items.length === shelf.length ? '共 ' + shelf.length + ' 本' : items.length + ' / ' + shelf.length + ' 本';
      if (!items.length) {
        grid.appendChild(h('div', { class: 'empty', text: shelf.length ? '没有匹配的漫画' : '书架还是空的，先在应用里收藏几本吧。' }));
        return;
      }
      for (const comic of items) grid.appendChild(comicCard(comic, () => openComic(comic)));
    }
    paint();
  }

  // ----------------------------------------------------------------- detail
  async function loadDetail(key, force) {
    const cached = state.details.get(key);
    if (cached && !force) return cached;
    const index = key.indexOf(':');
    const source = index < 0 ? key : key.slice(0, index);
    const id = index < 0 ? '' : key.slice(index + 1);
    const detail = await api('/api/comic/' + encodeURIComponent(source) + '/' + encodeURIComponent(id));
    state.details.set(key, detail);
    return detail;
  }

  async function renderDetail(route, version) {
    const key = route.key;
    const index = key.indexOf(':');
    const source = index < 0 ? key : key.slice(0, index);
    const id = index < 0 ? '' : key.slice(index + 1);
    backBtn.hidden = false;
    setActiveNav('');
    setCrumb([{ text: '书架', href: '#/library' }, { text: '详情' }]);
    clear(app);
    const holder = h('div', {});
    app.appendChild(holder);
    skeletons(holder, 6);

    let detail;
    try {
      detail = await loadDetail(key);
    } catch (error) {
      if (version !== state.version) return;
      clear(holder);
      holder.appendChild(h('div', { class: 'empty', text: error.message }));
      return;
    }
    if (version !== state.version) return;

    setCrumb([{ text: '书架', href: '#/library' }, { text: detail.title }]);
    document.title = detail.title + ' · Venera Web';
    clear(holder);

    const progress = detail.progress;
    const hero = h('div', { class: 'hero' });
    if (detail.cover) {
      hero.appendChild(h('div', {
        class: 'hero-bg',
        style: 'background-image:url("' + withToken(detail.cover).replace(/"/g, '%22') + '")',
      }));
    }
    hero.appendChild(h('div', { class: 'hero-shade' }));
    const coverBox = h('div', { class: 'hero-cover' });
    coverBox.appendChild(h('div', { class: 'fallback', text: detail.title }));
    if (coverSrc(detail, false) || coverSrc(detail, true)) {
      coverBox.appendChild(coverImage(detail));
    }

    const actions = h('div', { class: 'hero-actions' });
    if (progress && detail.chapters.length) {
      actions.appendChild(h('button', {
        class: 'primary', text: '继续阅读 · 第 ' + progress.chapter + ' 话',
        onclick: () => openReader(key, progress.chapter, progress.page || 1),
      }));
    }
    if (detail.chapters.length) {
      actions.appendChild(h('button', {
        class: progress ? 'ghost' : 'primary', text: '从头开始',
        onclick: () => openReader(key, 1, 1),
      }));
    }
    if (detail.url) {
      actions.appendChild(h('button', {
        class: 'soft', text: '打开来源页面',
        onclick: () => window.open(detail.url, '_blank', 'noopener'),
      }));
    }

    const desc = detail.description ? h('div', { class: 'hero-desc', text: detail.description }) : null;
    const info = h('div', { class: 'hero-info' }, [
      h('h1', { text: detail.title }),
      h('div', { class: 'hero-sub', text: [detail.subtitle, sourceName(source), detail.updateTime ? '更新 ' + detail.updateTime : ''].filter(Boolean).join(' · ') }),
      detail.tags && detail.tags.length
        ? h('div', { class: 'chip-row' }, detail.tags.slice(0, 12).map((tag) => h('span', { class: 'chip', text: tag })))
        : null,
      desc,
      desc ? h('button', {
        class: 'link-btn', text: '展开简介',
        onclick: (event) => {
          desc.classList.toggle('open');
          event.target.textContent = desc.classList.contains('open') ? '收起简介' : '展开简介';
        },
      }) : null,
      actions,
    ]);
    hero.appendChild(h('div', { class: 'hero-body' }, [coverBox, info]));
    holder.appendChild(hero);

    // chapters ---------------------------------------------------------
    const chapters = detail.chapters || [];
    const listState = { q: '', unreadOnly: false, ascending: true };
    const chapterBox = h('div', { class: 'chapters' });
    const countLabel = h('h2', { text: '目录 · ' + chapters.length });
    const tools = h('div', { class: 'chapter-tools' }, [
      h('input', {
        type: 'search', placeholder: '搜索话数…',
        oninput: (event) => { listState.q = event.target.value.trim().toLowerCase(); paintChapters(); },
      }),
      h('button', {
        class: 'soft on', text: '只看未读',
        onclick: (event) => {
          listState.unreadOnly = !listState.unreadOnly;
          event.target.classList.toggle('on', listState.unreadOnly);
          paintChapters();
        },
      }),
      h('button', {
        class: 'soft', text: '正序',
        onclick: (event) => {
          listState.ascending = !listState.ascending;
          event.target.textContent = listState.ascending ? '正序' : '倒序';
          paintChapters();
        },
      }),
    ]);
    holder.appendChild(h('div', { class: 'section-head' }, [countLabel, h('span', { class: 'spacer' }), tools]));
    holder.appendChild(chapterBox);

    const readSet = new Set((progress && progress.readChapters || []).map(String));
    function paintChapters() {
      clear(chapterBox);
      let items = chapters.filter((chapter) => {
        if (listState.q) {
          const label = (chapter.title || '') + ' ' + chapter.index;
          if (!label.toLowerCase().includes(listState.q)) return false;
        }
        if (listState.unreadOnly) {
          if (readSet.has(String(chapter.index)) || (progress && progress.chapter === chapter.index)) return false;
        }
        return true;
      });
      if (!listState.ascending) items = items.slice().reverse();
      if (!items.length) {
        chapterBox.appendChild(h('div', { class: 'empty', text: '没有匹配的话数' }));
        return;
      }
      let lastGroup;
      for (const chapter of items) {
        if (chapter.groupTitle && chapter.groupTitle !== lastGroup) {
          lastGroup = chapter.groupTitle;
          chapterBox.appendChild(h('div', { class: 'group-title', text: lastGroup }));
        }
        const isCurrent = progress && progress.chapter === chapter.index;
        const isRead = readSet.has(String(chapter.index));
        chapterBox.appendChild(h('button', {
          class: 'chapter' + (isCurrent ? ' current' : '') + (isRead ? ' read' : ''),
          onclick: () => openReader(key, chapter.index, 1),
        }, [
          h('span', { class: 'num', text: String(chapter.index) }),
          h('span', { class: 'name', text: chapter.title || '未命名' }),
          isRead && !isCurrent ? h('span', { class: 'tick', text: '✓' }) : null,
        ]));
      }
    }
    paintChapters();
    window.scrollTo(0, 0);
  }

  // ----------------------------------------------------------------- search
  function renderSearch(route) {
    setActiveNav('search');
    backBtn.hidden = true;
    setCrumb([{ text: '搜索' }]);
    setTopActions([]);
    clear(app);

    const input = h('input', { type: 'search', placeholder: '输入漫画名…', value: route.q || '' });
    const select = h('select', {});
    select.appendChild(h('option', { value: 'all', text: '全部来源' }));
    select.value = route.source || 'all';
    const history = h('div', { class: 'search-history' });
    const results = h('div', {});
    const form = h('form', { class: 'search-form' }, [input, select,
      h('button', { class: 'primary', type: 'submit', text: '搜索' })]);
    app.appendChild(h('div', { class: 'page-head' }, [h('h1', { text: '搜索' })]));
    app.appendChild(form);
    app.appendChild(history);
    app.appendChild(results);

    // Komga's search box shows recent terms as one-click chips. Do the same,
    // and keep the source qualifier so re-running a scoped search is one tap.
    function paintHistory() {
      clear(history);
      const items = searchHistory();
      if (route.q || !items.length) {
        history.hidden = true;
        return;
      }
      history.hidden = false;
      history.appendChild(h('span', { class: 'count', text: '最近搜索' }));
      for (const item of items) {
        const label = item.q + (
          item.source && item.source !== 'all' ? ' · ' + sourceName(item.source) : ''
        );
        history.appendChild(h('button', {
          class: 'chip', text: label, title: item.q,
          onclick: () => go('#/search?q=' + encodeURIComponent(item.q)
            + '&source=' + encodeURIComponent(item.source || 'all')),
        }));
      }
      history.appendChild(h('button', {
        class: 'link-btn', text: '清空',
        onclick: () => {
          try { localStorage.removeItem(SEARCH_HISTORY_KEY); } catch (_) {}
          paintHistory();
        },
      }));
    }
    paintHistory();

    ensureSources().then((sources) => {
      for (const source of sources) {
        if (!source.searchable) continue;
        select.appendChild(h('option', { value: source.key, text: source.name }));
      }
      if (!Array.from(select.options).some((option) => option.value === (route.source || 'all'))) {
        select.value = 'all';
      } else {
        select.value = route.source || 'all';
      }
      paintHistory();
    }).catch(() => {});

    // Komga's search view splits results into labelled sections. Grouping by
    // source keeps a big cross-source search scannable and makes it obvious
    // which source a result came from.
    function appendResults(grid, comics, onOpen) {
      const groups = new Map();
      for (const comic of comics || []) {
        const key = comic.source || 'other';
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(comic);
      }
      const existing = new Set(
        Array.from(grid.querySelectorAll('.result-group-title'))
          .map((e) => e.dataset.source),
      );
      for (const [src, items] of groups) {
        if (groups.size > 1 || src !== 'all') {
          if (!existing.has(src)) {
            grid.appendChild(h('div', {
              class: 'result-group-title', 'data-source': src,
              text: sourceName(src),
            }));
            existing.add(src);
          }
        }
        for (const comic of items) grid.appendChild(comicCard(comic, onOpen));
      }
    }

    const runSearch = async (q, source, refresh) => {
      clear(results);
      if (!q) return;
      const cacheKey = JSON.stringify([q, source]);
      const openFromSearch = (comic) => {
        const entry = state.searchCache.get(cacheKey);
        if (entry) entry.scrollY = window.scrollY;
        openComic(comic);
      };
      const cached = state.searchCache.get(cacheKey);
      if (cached && !refresh) {
        paint(cached.data);
        if (cached.scrollY) {
          requestAnimationFrame(() => requestAnimationFrame(() => {
            if (state.route && state.route.name === 'search') {
              window.scrollTo(0, cached.scrollY);
            }
          }));
        }
        return;
      }

      const grid = h('div', { class: 'grid' });
      const foot = h('div', { class: 'result-foot' });
      results.appendChild(grid);
      results.appendChild(foot);
      skeletons(grid, 8);
      let page = 1;
      let next = null;
      const load = async (append) => {
        busy(true);
        try {
          let url = '/api/search?q=' + encodeURIComponent(q) + '&source=' + encodeURIComponent(source) + '&page=' + page;
          if (next) url += '&next=' + encodeURIComponent(next);
          const data = await api(url);
          if (!append) {
            clear(grid);
            state.searchCache.set(cacheKey, { data, scrollY: 0 });
            rememberSearch(q, source);
          }
          if (!data.comics.length && !append) {
            clear(foot);
            foot.appendChild(h('div', {
              class: 'empty',
              text: data.partial ? '部分来源尚未响应，请稍后重试' : '没有找到结果',
            }));
            return;
          }
          appendResults(grid, data.comics, openFromSearch);
          clear(foot);
          if (data.partial) {
            foot.appendChild(h('span', { class: 'count', text: '部分来源未响应' }));
          }
          foot.appendChild(h('button', {
            class: 'ghost', text: '重新搜索',
            onclick: () => runSearch(q, source, true),
          }));
          if (data.hasMore) {
            foot.appendChild(h('button', {
              class: 'ghost', text: '加载更多',
              onclick: async () => {
                if (data.next) next = data.next; else page += 1;
                await load(true);
              },
            }));
          } else {
            foot.appendChild(h('span', { class: 'count', text: '已显示全部结果' }));
          }
        } catch (error) {
          toast(error.message);
        } finally {
          busy(false);
        }
      };

      function paint(data) {
        clear(results);
        const grid = h('div', { class: 'grid' });
        const foot = h('div', { class: 'result-foot' });
        results.appendChild(grid);
        results.appendChild(foot);
        appendResults(grid, data.comics, openFromSearch);
        if (!(data.comics || []).length) {
          grid.appendChild(h('div', { class: 'empty', text: '没有找到结果' }));
        }
        foot.appendChild(h('span', { class: 'count', text: '已保存的搜索结果' }));
        foot.appendChild(h('button', {
          class: 'ghost', text: '重新搜索',
          onclick: () => runSearch(q, source, true),
        }));
      }

      await load(false);
    };

    form.addEventListener('submit', (event) => {
      event.preventDefault();
      const q = input.value.trim();
      const source = select.value;
      if (!q) return;
      go('#/search?q=' + encodeURIComponent(q) + '&source=' + encodeURIComponent(source));
    });
    if (route.q) runSearch(route.q, route.source || 'all', false);
  }

  // ---------------------------------------------------------------- sources
  async function renderSources(version) {
    setActiveNav('sources');
    backBtn.hidden = true;
    setCrumb([{ text: '来源' }]);
    setTopActions([]);
    clear(app);
    app.appendChild(h('div', { class: 'page-head' }, [h('h1', { text: '来源' })]));
    const list = h('div', {});
    app.appendChild(list);
    skeletons(list, 4);
    try {
      const sources = await ensureSources();
      if (version !== state.version) return;
      clear(list);
      for (const source of sources) {
        const counts = (state.shelf || []).filter((comic) => comic.source === source.key).length;
        list.appendChild(h('div', { class: 'api-item' }, [
          h('strong', { text: source.name }),
          h('span', { class: 'chip' + (source.local ? ' accent' : ''), text: source.local ? '本地' : '在线' }),
          source.searchable ? h('span', { class: 'chip outline', text: '可搜索' }) : null,
          h('span', { class: 'desc', text: counts ? '书架 ' + counts + ' 本' : '' }),
          h('button', {
            class: 'copy', text: '在书中搜索',
            onclick: () => go('#/search?source=' + encodeURIComponent(source.key)),
          }),
        ]));
      }
    } catch (error) {
      if (version !== state.version) return;
      clear(list);
      list.appendChild(h('div', { class: 'empty', text: error.message }));
    }
  }

  // -------------------------------------------------------------------- api
  function renderApi() {
    setActiveNav('api');
    backBtn.hidden = true;
    setCrumb([{ text: '接口' }]);
    setTopActions([]);
    clear(app);
    const origin = location.origin;
    app.appendChild(h('div', { class: 'page-head' }, [h('h1', { text: '接口' })]));
    app.appendChild(h('p', { class: 'count', text: '除图片外的接口都返回 JSON。带令牌时用 Authorization: Bearer、X-API-Key 或 ?token=。' }));

    const groups = [
      ['书架 / 阅读', [
        ['GET /api/bookshelf', '书架 + 阅读进度'],
        ['GET /api/sources', '可用漫画源'],
        ['GET /api/search?q=&source=&page=', '搜索（source=all 跨源）'],
        ['GET /api/comic/{source}/{id}', '详情 + 目录'],
        ['GET /api/cover/{source}/{id}', '封面（按详情重新解析，可回退）'],
        ['GET|PUT /api/progress/{source}/{id}', '读取 / 写入进度'],
        ['GET /api/chapter/{source}/{id}/{chapter}', '章节图片列表'],
        ['GET /api/image?ref=&kind=&source=&cid=&eid=', '图片代理'],
      ]],
      ['Komga 兼容（/api/v1）', [
        ['GET /api/v1/users/me', '身份信息'],
        ['GET /api/v1/libraries', '书源即书库（数组）'],
        ['GET /api/v1/series?page=&size=&search=', '系列分页（Komga 封套）'],
        ['GET /api/v1/series/{id}/books', '系列下的章节'],
        ['GET /api/v1/books/{id}/pages', '页面清单（数组）'],
        ['GET /api/v1/books/{id}/pages/{n}', '单页图片'],
        ['PATCH /api/v1/books/{id}/read-progress', '上报阅读进度'],
        ['GET /api/v1/books/{id}/next', '下一话'],
        ['GET /api/v1/search?q=', '书架内搜索'],
      ]],
      ['OPDS', [
        ['GET /opds', 'OPDS 1.2 根目录'],
        ['GET /opds/v1.2/catalog', 'Komga 路径别名'],
        ['GET /opds/libraries', '按来源浏览'],
        ['GET /opds/search?q=', 'OPDS 搜索'],
        ['GET /opds/cbz/{source}/{id}/{chapter}', '整章 CBZ 下载'],
        ['GET /opds/page/{source}/{id}/{chapter}/{page}', 'OPDS-PSE 逐页流式'],
      ]],
    ];

    for (const [title, items] of groups) {
      const group = h('div', { class: 'api-group' }, [h('h2', { text: title })]);
      for (const [path, desc] of items) {
        const full = path.startsWith('GET /opds') ? origin + path.slice(4).split('?')[0] : path;
        group.appendChild(h('div', { class: 'api-item' }, [
          h('code', { text: path }),
          h('span', { class: 'desc', text: desc }),
          h('button', {
            class: 'copy', text: '复制',
            onclick: async () => {
              try {
                await navigator.clipboard.writeText(full);
                toast('已复制');
              } catch (_) { toast('复制失败'); }
            },
          }),
        ]));
      }
      app.appendChild(group);
    }
  }

  // ----------------------------------------------------------------- reader
  function openReader(key, chapter, page) {
    go('#/read/' + encodeURIComponent(key) + '/' + chapter + (page > 1 ? '/' + page : ''));
  }

  function closeReader() {
    const reader = state.reader;
    if (!reader) return;
    saveProgress(true);
    disposeReader();
    go('#/comic/' + encodeURIComponent(reader.key));
  }

  function disposeReader() {
    const reader = state.reader;
    if (!reader) return;
    if (reader.keyHandler) window.removeEventListener('keydown', reader.keyHandler);
    if (reader.overlay) reader.overlay.remove();
    if (reader.timer) clearTimeout(reader.timer);
    if (reader.saveTimer) clearTimeout(reader.saveTimer);
    if (reader.scrollTimer) clearTimeout(reader.scrollTimer);
    reader.scrollSeq = (reader.scrollSeq || 0) + 1;
    state.reader = null;
  }

  async function renderReader(route, version) {
    const key = route.key;
    const chapter = route.chapter || 1;
    backBtn.hidden = true;
    setActiveNav('');
    setTopActions([]);
    setCrumb([{ text: '阅读' }]);
    document.title = '阅读 · Venera Web';

    let detail;
    try {
      detail = await loadDetail(key);
    } catch (error) {
      toast(error.message);
      go('#/library');
      return;
    }
    if (version !== state.version) return;

    const index = key.indexOf(':');
    const source = index < 0 ? key : key.slice(0, index);
    const id = index < 0 ? '' : key.slice(index + 1);
    const existing = state.reader;
    if (existing && existing.key === key) {
      // Same session (chapter switch via hash): keep chrome, load new chapter.
      existing.chapters = detail.chapters;
      existing.detail = detail;
      await gotoChapter(chapter, 1, false);
      return;
    }
    disposeReader();

    const reader = {
      key, source, id, detail, chapters: detail.chapters || [],
      chapter, page: 1, mode: 'vertical', fit: 'width',
      images: [], overlay: null, scroller: null, nodes: [], timer: null,
      saveTimer: null, currentPage: 1, keyHandler: null, chapterId: null,
      pageLabels: [],
    };
    state.reader = reader;
    clear(app);

    const overlay = h('div', { class: 'reader-overlay' });
    reader.overlay = overlay;
    document.body.appendChild(overlay);

    const scroll = h('div', { class: 'reader-scroll vertical' });
    reader.scroller = scroll;

    const title = h('div', { class: 'reader-title', text: detail.title });
    const meta = h('div', { class: 'reader-meta', text: '' });
    const metaBottom = h('div', { class: 'reader-meta', text: '' });
    reader.pageLabels = [meta, metaBottom];
    const select = h('select', { class: 'reader-select' });
    for (const item of reader.chapters) {
      select.appendChild(h('option', {
        value: item.index,
        text: item.index + '. ' + (item.title || '未命名'),
        selected: item.index === chapter,
      }));
    }
    select.addEventListener('change', () => gotoSafely(Number(select.value)));
    reader.select = select;

    const top = h('div', { class: 'reader-bars top' }, [
      h('button', { class: 'reader-btn icon', text: '←', title: '返回', onclick: closeReader }),
      title,
      meta,
      h('span', { class: 'reader-spacer' }),
      select,
      h('button', {
        class: 'reader-btn icon', text: '⛶', title: '全屏',
        onclick: () => toggleFullscreen(),
      }),
    ]);
    reader.top = top;

    const slider = h('input', {
      class: 'reader-slider', type: 'range', min: '1', max: '1', value: '1',
      oninput: (event) => scrollToPage(Number(event.target.value), true),
    });
    reader.slider = slider;

    const prevBtn = h('button', {
      class: 'reader-btn', text: '上一话',
      onclick: () => gotoChapter(reader.chapter - 1, 1, true),
    });
    const nextBtn = h('button', {
      class: 'reader-btn', text: '下一话',
      onclick: () => gotoChapter(reader.chapter + 1, 1, true),
    });
    reader.prevBtn = prevBtn;
    reader.nextBtn = nextBtn;

    const bottom = h('div', { class: 'reader-bars bottom' }, [
      prevBtn,
      h('button', { class: 'reader-btn icon', text: '⇤', title: '第一页', onclick: () => scrollToPage(1, false) }),
      h('button', { class: 'reader-btn icon', text: '◀', title: '上一页', onclick: () => turnPage(-1) }),
      slider,
      metaBottom,
      h('button', { class: 'reader-btn icon', text: '▶', title: '下一页', onclick: () => turnPage(1) }),
      h('button', {
        class: 'reader-btn icon', text: '⇥', title: '最后一页',
        onclick: () => scrollToPage(reader.images.length, false),
      }),
      nextBtn,
      h('button', {
        class: 'reader-btn', text: '纵向',
        onclick: (event) => {
          reader.mode = reader.mode === 'vertical' ? 'horizontal' : 'vertical';
          event.target.textContent = reader.mode === 'vertical' ? '纵向' : '横向';
          applyMode();
          scrollToPage(reader.page || 1, false);
        },
      }),
      h('button', {
        class: 'reader-btn', text: '重载', title: '重新加载本章图片',
        onclick: () => {
          reader.imageErrorShown = false;
          renderPages();
        },
      }),
      h('button', {
        class: 'reader-btn', text: '适应宽度',
        onclick: (event) => {
          reader.fit = { width: 'height', height: 'original', original: 'width' }[reader.fit];
          event.target.textContent = { width: '适应宽度', height: '适应高度', original: '原始尺寸' }[reader.fit];
          applyMode();
          scrollToPage(reader.page || 1, false);
        },
      }),
    ]);

    overlay.appendChild(scroll);
    overlay.appendChild(top);
    overlay.appendChild(bottom);
    if (!hintShown) {
      hintShown = true;
      const hint = h('div', { class: 'reader-hint', text: '点击两侧翻页 · 方向键/空格翻页 · Esc 返回' });
      overlay.appendChild(hint);
      setTimeout(() => hint.remove(), 5200);
    }

    scroll.addEventListener('scroll', onScroll, { passive: true });
    // Any manual input wins over the "settle on the saved page" retries.
    overlay.addEventListener('wheel', () => { reader.autoScrollUntil = 0; }, { passive: true });
    overlay.addEventListener('touchstart', () => { reader.autoScrollUntil = 0; }, { passive: true });
    overlay.addEventListener('click', onOverlayClick);
    overlay.addEventListener('mousemove', showBars, { passive: true });

    reader.keyHandler = (event) => {
      if (event.key === 'Escape') { event.preventDefault(); closeReader(); return; }
      if (event.key === 'ArrowRight' || event.key === 'PageDown' || event.key === ' ') {
        event.preventDefault(); turnPage(1); return;
      }
      if (event.key === 'ArrowLeft' || event.key === 'PageUp') {
        event.preventDefault(); turnPage(-1); return;
      }
      if (event.key === 'f' || event.key === 'F') toggleFullscreen();
    };
    window.addEventListener('keydown', reader.keyHandler);

    hideBarsLater();
    await gotoChapter(chapter, route.page || 1, false);
  }

  let hintShown = false;

  async function gotoChapter(chapter, page, updateHash) {
    const reader = state.reader;
    if (!reader) return;
    const chapters = reader.chapters || [];
    if (chapter < 1 || chapter > chapters.length) return;
    // Invalidate an in-flight scroll from the previous chapter before its
    // image nodes are replaced; otherwise a late retry can land on the new
    // DOM at the old offset and bounce the view.
    reader.scrollSeq = (reader.scrollSeq || 0) + 1;
    if (reader.scrollTimer) {
      clearTimeout(reader.scrollTimer);
      reader.scrollTimer = null;
    }
    saveProgress(true);
    busy(true);
    try {
      const data = await api('/api/chapter/' + encodeURIComponent(reader.source) + '/' + encodeURIComponent(reader.id) + '/' + chapter);
      reader.chapter = chapter;
      reader.chapterId = data.chapterId;
      reader.images = data.images || [];
      reader.title = data.title;
      reader.page = Math.max(1, Math.min(page || 1, reader.images.length || 1));
      if (reader.select) reader.select.value = String(chapter);
      if (reader.prevBtn) reader.prevBtn.disabled = chapter <= 1;
      if (reader.nextBtn) reader.nextBtn.disabled = chapter >= chapters.length;
      if (updateHash !== false) {
        history.replaceState(null, '', '#/read/' + encodeURIComponent(reader.key) + '/' + chapter);
      }
      renderPages();
    } catch (error) {
      toast(error.message);
    } finally {
      busy(false);
    }
  }

  function gotoSafely(chapter) {
    if (chapter < 1 || chapter > (state.reader.chapters || []).length) return;
    gotoChapter(chapter, 1, true);
  }

  function renderPages() {
    const reader = state.reader;
    if (!reader) return;
    const scroll = reader.scroller;
    scroll.innerHTML = '';
    reader.nodes = [];
    reader.images.forEach((src, position) => {
      const img = h('img', {
        src: withToken(src), alt: '', loading: position < 3 ? 'eager' : 'lazy',
        draggable: 'false',
        onerror: () => {
          if (!reader.imageErrorShown) {
            reader.imageErrorShown = true;
            toast('部分图片加载失败，可点底部「重载」重试');
          }
        },
      });
      scroll.appendChild(img);
      reader.nodes.push(img);
    });
    reader.positionOfPage = (page) => page - 1;
    applyMode();
    preloadNextChapter();
    const target = reader.page || 1;
    requestAnimationFrame(() => requestAnimationFrame(() => scrollToPage(target, false)));
  }

  function applyMode() {
    const reader = state.reader;
    if (!reader) return;
    const scroll = reader.scroller;
    scroll.className = 'reader-scroll ' + reader.mode + ' fit-' + reader.fit;
    const total = reader.images.length || 1;
    reader.slider.max = String(total);
    reader.slider.value = String(reader.page || 1);
    setPageLabel((reader.page || 1) + ' / ' + total);
  }

  function setPageLabel(text) {
    const reader = state.reader;
    if (!reader) return;
    for (const el of reader.pageLabels || []) el.textContent = text;
  }

  function scrollToPage(page, smooth) {
    const reader = state.reader;
    if (!reader) return;
    const target = Math.max(1, Math.min(page, reader.images.length || 1));
    reader.page = target;
    reader.currentPage = target;
    const position = reader.positionOfPage ? reader.positionOfPage(target) : target - 1;
    const node = reader.nodes[position];
    if (!node) return;

    // A new request invalidates every pending retry from an older one. Without
    // this generation token, "chapter load" + "restore saved page" could keep
    // applying two different scroll positions in turn (the flashing pages).
    reader.scrollSeq = (reader.scrollSeq || 0) + 1;
    const seq = reader.scrollSeq;
    if (reader.scrollTimer) {
      clearTimeout(reader.scrollTimer);
      reader.scrollTimer = null;
    }

    const horizontal = reader.mode === 'horizontal';
    const behavior = smooth && !horizontal ? 'smooth' : 'auto';
    const apply = () => {
      if (state.reader !== reader || seq !== reader.scrollSeq) return;
      if (horizontal) {
        // Each page is exactly one viewport wide, so the geometry is known
        // before the image decodes. Assign directly and only once per frame.
        const left = position * reader.scroller.clientWidth;
        if (Math.abs(reader.scroller.scrollLeft - left) > 1) {
          reader.scroller.scrollLeft = left;
        }
      } else {
        const top = node.getBoundingClientRect().top
          - reader.scroller.getBoundingClientRect().top
          + reader.scroller.scrollTop;
        reader.scroller.scrollTo({ top, behavior });
      }
    };

    if (horizontal) {
      // One immediate jump, one after layout settles (toolbar/chapter switch
      // can change the available height). No repeating timer, no snap.
      apply();
      reader.autoScrollUntil = Date.now() + 120;
      requestAnimationFrame(() => {
        apply();
        reader.autoScrollUntil = Date.now() + 120;
      });
    } else {
      // Vertical pages have no known height until decoded, so a deep link can
      // land short. Retry briefly, giving up as soon as the user scrolls.
      const deadline = Date.now() + (smooth ? 450 : 1600);
      reader.autoScrollUntil = deadline;
      let attempts = 0;
      const attempt = () => {
        if (state.reader !== reader || seq !== reader.scrollSeq) return;
        if (Date.now() > reader.autoScrollUntil) return;
        apply();
        if (attempts++ < 7) {
          reader.scrollTimer = setTimeout(attempt, 220);
        }
      };
      if (node.complete) attempt();
      else {
        node.addEventListener('load', attempt, { once: true });
        node.addEventListener('error', attempt, { once: true });
        reader.scrollTimer = setTimeout(attempt, 220);
      }
    }
    reader.slider.value = String(target);
    setPageLabel(target + ' / ' + (reader.images.length || 1));
    onPageChanged(target);
  }

  let scrollFrame = 0;
  function onScroll() {
    const reader = state.reader;
    if (!reader || scrollFrame) return;
    if (Date.now() < (reader.autoScrollUntil || 0)) return;
    scrollFrame = requestAnimationFrame(() => {
      scrollFrame = 0;
      const scroll = reader.scroller;
      let page;
      if (reader.mode === 'horizontal') {
        const unit = scroll.clientWidth || 1;
        page = Math.round(scroll.scrollLeft / unit) + 1;
      } else {
        const rect = scroll.getBoundingClientRect();
        const marker = rect.height * 0.4;
        page = 1;
        for (let i = 0; i < reader.nodes.length; i++) {
          const top = reader.nodes[i].getBoundingClientRect().top - rect.top;
          if (top <= marker) page = i + 1; else break;
        }
      }
      page = Math.max(1, Math.min(page, reader.images.length || 1));
      if (page !== reader.currentPage) {
        reader.currentPage = page;
        reader.page = page;
        reader.slider.value = String(page);
        setPageLabel(page + ' / ' + (reader.images.length || 1));
        onPageChanged(page);
      }
    });
  }

  function onPageChanged(page) {
    const reader = state.reader;
    if (!reader) return;
    if (reader.saveTimer) clearTimeout(reader.saveTimer);
    reader.saveTimer = setTimeout(() => saveProgress(false), 2500);
    if (reader.mode === 'vertical' && page >= reader.images.length) {
      // Near the end of the chapter: warm the next one for a seamless turn.
      preloadNextChapter();
    }
  }

  function turnPage(delta) {
    const reader = state.reader;
    if (!reader) return;
    const next = (reader.page || 1) + delta;
    if (next < 1) {
      if (reader.chapter > 1) gotoChapter(reader.chapter - 1, 1, true);
      else toast('已经是第一话');
      return;
    }
    if (next > reader.images.length) {
      if (reader.chapter < reader.chapters.length) gotoChapter(reader.chapter + 1, 1, true);
      else toast('已经是最后一话');
      return;
    }
    scrollToPage(next, true);
  }

  function onOverlayClick(event) {
    const reader = state.reader;
    if (!reader) return;
    if (event.target.closest('.reader-bars')) return;
    if (event.target.tagName !== 'IMG' && !event.target.classList.contains('reader-scroll')) {
      if (reader.mode === 'vertical') toggleBars();
      return;
    }
    if (reader.mode !== 'horizontal') { toggleBars(); return; }
    const ratio = event.clientX / window.innerWidth;
    if (ratio < 0.32) turnPage(-1);
    else if (ratio > 0.68) turnPage(1);
    else toggleBars();
  }

  function toggleBars() {
    const reader = state.reader;
    if (!reader) return;
    reader.overlay.classList.toggle('bars-hidden');
    if (!reader.overlay.classList.contains('bars-hidden')) hideBarsLater();
  }

  function showBars() {
    const reader = state.reader;
    if (!reader) return;
    if (reader.overlay.classList.contains('bars-hidden')) return;
    hideBarsLater();
  }

  function hideBarsLater() {
    const reader = state.reader;
    if (!reader) return;
    if (reader.timer) clearTimeout(reader.timer);
    reader.timer = setTimeout(() => {
      if (state.reader === reader) reader.overlay.classList.add('bars-hidden');
    }, 3200);
  }

  function toggleFullscreen() {
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
    else document.documentElement.requestFullscreen().catch(() => {});
  }

  function preloadNextChapter() {
    const reader = state.reader;
    if (!reader || reader.preloaded === reader.chapter + 1) return;
    const next = reader.chapter + 1;
    if (next > reader.chapters.length) return;
    reader.preloaded = next;
    api('/api/chapter/' + encodeURIComponent(reader.source) + '/' + encodeURIComponent(reader.id) + '/' + next)
      .then((data) => {
        for (const src of (data.images || []).slice(0, 3)) {
          const img = new Image();
          img.src = withToken(src);
        }
      })
      .catch(() => {});
  }

  async function saveProgress(silent) {
    const reader = state.reader;
    if (!reader || !reader.currentPage) return;
    const chapter = (reader.chapters || []).find((item) => item.index === reader.chapter);
    const page = reader.currentPage;
    try {
      await api('/api/progress/' + encodeURIComponent(reader.source) + '/' + encodeURIComponent(reader.id), {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          chapter: reader.chapter,
          page,
          chapterTitle: chapter ? chapter.title : null,
          group: chapter ? chapter.group : null,
          groupTitle: chapter ? chapter.groupTitle : null,
        }),
      });
      // Keep the cached detail and shelf card in sync so "continue reading"
      // and the progress bar reflect the page that was just read.
      const detail = state.details.get(reader.key);
      if (detail) {
        detail.progress = Object.assign({}, detail.progress || {}, {
          chapter: reader.chapter,
          page,
          chapterTitle: chapter ? chapter.title : null,
          updatedAt: new Date().toISOString(),
        });
      }
      const card = (state.shelf || []).find(
        (comic) => comic.source + ':' + comic.id === reader.key,
      );
      if (card) {
        card.progress = Object.assign({}, card.progress || {}, {
          chapter: reader.chapter,
          page,
          updatedAt: new Date().toISOString(),
        });
      }
    } catch (error) {
      if (!silent) toast(error.message);
    }
  }

  window.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden' && state.reader) saveProgress(true);
  });

  // ----------------------------------------------------------------- render
  async function render(force) {
    const version = ++state.version;
    const route = parseRoute();
    state.route = route;
    if (route.name !== 'read') {
      if (state.reader) disposeReader();
      document.title = 'Venera Web';
    }
    if (!force) window.scrollTo(0, 0);
    renderServerHint();
    try {
      if (route.name === 'library') await renderLibrary(version);
      else if (route.name === 'search') renderSearch(route);
      else if (route.name === 'sources') await renderSources(version);
      else if (route.name === 'api') renderApi();
      else if (route.name === 'comic') await renderDetail(route, version);
      else if (route.name === 'read') await renderReader(route, version);
    } catch (error) {
      toast(error.message);
    }
  }

  function renderServerHint() {
    const hint = document.getElementById('server-hint');
    if (!hint) return;
    const tokenState = state.token ? '已设置令牌' : '无令牌';
    hint.textContent = location.host + ' · ' + tokenState;
  }

  backBtn.addEventListener('click', () => {
    if (history.length > 1) history.back();
    else go('#/library');
  });

  window.addEventListener('hashchange', () => render());

  applyTheme();
  render();
  ensureSources().catch(() => {});
})();
