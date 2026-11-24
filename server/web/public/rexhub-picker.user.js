// ==UserScript==
// @name         RexHub 链接拾取器
// @namespace    rexhub.local
// @version      1.0.0
// @description  在 RexHub 搜索页点选 / 批量收集 magnet·ed2k·115 分享链接，一键填入「115 转存」输入框
// @author       RexHub
// @match        http://127.0.0.1:3020/*
// @match        http://localhost:3020/*
// @match        http://192.168.*.*:3020/*
// @match        http://10.*.*.*:3020/*
// @run-at       document-idle
// @grant        none
// ==/UserScript==

(function () {
  'use strict';

  // ---------- 链接识别 ----------
  const LINK_RE =
    /(?:magnet:\?[^\s"'<>]+|ed2k:\/\/[^\s"'<>]+|https?:\/\/(?:www\.)?(?:115\.com|115cdn\.com)\/s\/[^\s"'<>]+)/gi;

  const STORE_KEY = 'rexhub.picker.buffer';

  function trimJunk(u) {
    return String(u || '')
      .replace(/[)\]}>.,;，。；、"'”’]+$/g, '')
      .trim();
  }

  function linksIn(text) {
    const out = [];
    if (!text) return out;
    for (const m of String(text).matchAll(LINK_RE)) {
      const link = trimJunk(m[0]);
      if (link && !out.includes(link)) out.push(link);
    }
    return out;
  }

  // ---------- 缓冲区（跨页面持久） ----------
  function loadBuf() {
    try {
      const raw = localStorage.getItem(STORE_KEY);
      const arr = raw ? JSON.parse(raw) : [];
      return Array.isArray(arr) ? arr.filter((x) => typeof x === 'string') : [];
    } catch {
      return [];
    }
  }

  function saveBuf(list) {
    try {
      localStorage.setItem(STORE_KEY, JSON.stringify(list));
    } catch {
      /* 隐私模式忽略 */
    }
  }

  let buf = loadBuf();

  function pushLinks(list) {
    let added = 0;
    for (const link of list) {
      if (!buf.includes(link)) {
        buf.push(link);
        added += 1;
      }
    }
    if (added) saveBuf(buf);
    render();
    return added;
  }

  // ---------- React 受控 textarea 写入 ----------
  function findTextarea() {
    return (
      document.querySelector('textarea.p115-paste__textarea') ||
      document.querySelector('.p115-paste__textarea')
    );
  }

  function setReactValue(el, value) {
    const proto =
      el instanceof HTMLTextAreaElement
        ? HTMLTextAreaElement.prototype
        : HTMLInputElement.prototype;
    const desc = Object.getOwnPropertyDescriptor(proto, 'value');
    if (desc && desc.set) desc.set.call(el, value);
    else el.value = value;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function fillTextarea(mode) {
    const ta = findTextarea();
    if (!ta) {
      toast('未找到转存输入框，请先打开「115 转存」页面');
      return false;
    }
    if (!buf.length) {
      toast('缓冲区为空');
      return false;
    }
    let next = '';
    if (mode === 'append') {
      const cur = (ta.value || '').trim();
      const merged = [];
      for (const l of [...linksIn(cur), ...buf]) {
        if (!merged.includes(l)) merged.push(l);
      }
      next = merged.join('\n');
    } else {
      next = buf.join('\n');
    }
    setReactValue(ta, next);
    ta.focus();
    const n = linksIn(next).length;
    toast(`已填入 ${n} 条` + (n > 50 ? '（超过后端 50 条上限，会自动分批或需分次提交）' : ''));
    return true;
  }

  // ---------- 页面链接收集 ----------
  function collectPageLinks() {
    const found = [];
    // 1) 文本节点里的链接
    const text = document.body ? document.body.innerText : '';
    found.push(...linksIn(text));
    // 2) href / title / data-* 属性里的链接
    for (const el of document.querySelectorAll('[href], [title], [data-link], [data-url]')) {
      for (const attr of ['href', 'title', 'data-link', 'data-url']) {
        const v = el.getAttribute && el.getAttribute(attr);
        if (v && /magnet:|ed2k:|\/s\//i.test(v)) found.push(...linksIn(v));
      }
    }
    return Array.from(new Set(found));
  }

  // ---------- 拾取模式 ----------
  let picking = false;
  let hoverEl = null;

  function setHover(el) {
    if (hoverEl === el) return;
    if (hoverEl) hoverEl.style.outline = hoverEl.dataset.__rexOutline || '';
    hoverEl = el;
    if (hoverEl) {
      hoverEl.dataset.__rexOutline = hoverEl.style.outline || '';
      hoverEl.style.outline = '2px solid #2f7cf6';
    }
  }

  function onPickMove(e) {
    if (!picking) return;
    const el = e.target;
    if (!el || el.closest('#rexhub-picker-host')) return;
    setHover(el);
  }

  /** 从点击元素向上找最近一个「含链接文本」的祖先 */
  function resolveLinkSource(el) {
    let node = el;
    for (let depth = 0; node && depth < 8; depth += 1) {
      const direct = linksIn(node.textContent || '');
      if (direct.length) return direct;
      node = node.parentElement;
    }
    // 兜底：属性里带链接
    for (let n = el, d = 0; n && d < 8; n = n.parentElement, d += 1) {
      for (const attr of ['href', 'title', 'data-link', 'data-url']) {
        const v = n.getAttribute && n.getAttribute(attr);
        const got = linksIn(v || '');
        if (got.length) return got;
      }
    }
    return [];
  }

  function onPickClick(e) {
    if (!picking) return;
    if (e.target.closest('#rexhub-picker-host')) return;
    e.preventDefault();
    e.stopPropagation();
    const got = resolveLinkSource(e.target);
    if (!got.length) {
      toast('这个元素里没有链接，换个位置点');
      return;
    }
    const added = pushLinks(got);
    toast(added ? `+${added} 条（共 ${buf.length}）` : `已在缓冲区内（共 ${buf.length}）`);
  }

  function togglePick() {
    picking = !picking;
    document.documentElement.style.cursor = picking ? 'crosshair' : '';
    if (!picking) setHover(null);
    render();
    toast(picking ? '拾取模式：点页面上的链接，ESC 退出' : '已退出拾取模式');
  }

  document.addEventListener('mousemove', onPickMove, true);
  document.addEventListener('click', onPickClick, true);
  document.addEventListener(
    'keydown',
    (e) => {
      if (e.key === 'Escape' && picking) {
        e.stopPropagation();
        togglePick();
      }
    },
    true,
  );

  // ---------- 浮层 UI（Shadow DOM 隔离样式） ----------
  const host = document.createElement('div');
  host.id = 'rexhub-picker-host';
  host.style.cssText =
    'position:fixed;z-index:2147483000;right:14px;bottom:calc(14px + env(safe-area-inset-bottom,0px));';
  const shadow = host.attachShadow({ mode: 'open' });
  shadow.innerHTML = `
    <style>
      :host { all: initial; }
      .panel {
        font: 13px/1.4 -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif;
        color: #e8e8ea;
        background: rgba(24, 24, 27, .94);
        border: 1px solid rgba(255, 255, 255, .12);
        border-radius: 14px;
        box-shadow: 0 8px 28px rgba(0, 0, 0, .45);
        padding: 10px 10px 9px;
        width: 196px;
        backdrop-filter: blur(12px);
        -webkit-backdrop-filter: blur(12px);
        user-select: none;
        -webkit-user-select: none;
      }
      .head { display: flex; align-items: center; gap: 6px; margin-bottom: 8px; }
      .dot { width: 7px; height: 7px; border-radius: 50%; background: #3f3f46; flex: none; }
      .dot.on { background: #2f7cf6; box-shadow: 0 0 0 3px rgba(47,124,246,.22); }
      .title { font-weight: 600; font-size: 12px; letter-spacing: .2px; flex: 1; }
      .count { font-variant-numeric: tabular-nums; font-size: 12px; color: #a1a1aa; }
      .row { display: flex; gap: 6px; margin-top: 6px; }
      button {
        font: inherit; font-size: 12px; color: #e8e8ea; cursor: pointer;
        background: rgba(255,255,255,.08); border: 1px solid rgba(255,255,255,.10);
        border-radius: 9px; padding: 6px 0; flex: 1; text-align: center;
        transition: background .12s ease, border-color .12s ease;
        -webkit-tap-highlight-color: transparent;
      }
      button:hover { background: rgba(255,255,255,.14); }
      button:active { transform: scale(.98); }
      button.primary { background: #2f7cf6; border-color: #2f7cf6; color: #fff; font-weight: 600; }
      button.primary:hover { background: #3d87f7; }
      button.on { background: rgba(47,124,246,.28); border-color: rgba(47,124,246,.6); color: #cfe0ff; }
      .hint { margin-top: 7px; font-size: 11px; color: #71717a; line-height: 1.35; }
      .toast {
        position: fixed; right: 14px; bottom: calc(190px + env(safe-area-inset-bottom,0px));
        max-width: 240px; font-size: 12px; color: #fff; background: rgba(24,24,27,.96);
        border: 1px solid rgba(255,255,255,.14); border-radius: 10px; padding: 7px 10px;
        opacity: 0; transform: translateY(6px); transition: opacity .16s, transform .16s;
        pointer-events: none; line-height: 1.4;
      }
      .toast.show { opacity: 1; transform: translateY(0); }
    </style>
    <div class="panel">
      <div class="head">
        <span class="dot" id="dot"></span>
        <span class="title">链接拾取</span>
        <span class="count" id="count">0</span>
      </div>
      <div class="row">
        <button id="pick">拾取模式</button>
        <button id="collect">收集本页</button>
      </div>
      <div class="row">
        <button id="fill" class="primary">填入转存框</button>
      </div>
      <div class="row">
        <button id="copy">复制</button>
        <button id="clear">清空</button>
      </div>
      <div class="hint" id="hint">点「拾取模式」后点页面上的链接</div>
    </div>
    <div class="toast" id="toast"></div>
  `;
  document.documentElement.appendChild(host);

  const $ = (id) => shadow.getElementById(id);
  let toastTimer = null;

  function toast(text) {
    const el = $('toast');
    if (!el) return;
    el.textContent = text;
    el.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove('show'), 2200);
  }

  function render() {
    const onTextarea = Boolean(findTextarea());
    $('count').textContent = String(buf.length);
    $('dot').classList.toggle('on', picking);
    $('pick').classList.toggle('on', picking);
    $('pick').textContent = picking ? '退出拾取' : '拾取模式';
    $('hint').textContent = !onTextarea
      ? '当前不在转存页 · 链接先攒着，进页面再填'
      : buf.length
        ? `已攒 ${buf.length} 条，点「填入转存框」`
        : '点「拾取模式」后点页面上的链接';
  }

  $('pick').addEventListener('click', togglePick);

  $('collect').addEventListener('click', () => {
    const found = collectPageLinks();
    if (!found.length) {
      toast('本页没找到 magnet / ed2k / 115 分享链接');
      return;
    }
    const added = pushLinks(found);
    toast(added ? `本页收 ${found.length} 条，新增 ${added} 条` : `本页 ${found.length} 条，全在缓冲区`);
  });

  $('fill').addEventListener('click', () => fillTextarea('replace'));

  $('copy').addEventListener('click', async () => {
    if (!buf.length) {
      toast('缓冲区为空');
      return;
    }
    const text = buf.join('\n');
    try {
      await navigator.clipboard.writeText(text);
      toast(`已复制 ${buf.length} 条`);
    } catch {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.cssText = 'position:fixed;opacity:0;';
      document.body.appendChild(ta);
      ta.select();
      try {
        document.execCommand('copy');
        toast(`已复制 ${buf.length} 条`);
      } catch {
        toast('复制失败，请手动全选');
      }
      ta.remove();
    }
  });

  $('clear').addEventListener('click', () => {
    buf = [];
    saveBuf(buf);
    render();
    toast('已清空');
  });

  // 输入框挂载 / 卸载时刷新提示
  const mo = new MutationObserver(() => render());
  mo.observe(document.documentElement, { childList: true, subtree: true });

  // 路由切换（Next App Router 用 history API）后也刷新一次
  const origPush = history.pushState;
  history.pushState = function (...args) {
    const r = origPush.apply(this, args);
    setTimeout(render, 120);
    return r;
  };
  window.addEventListener('popstate', () => setTimeout(render, 120));

  render();
})();
