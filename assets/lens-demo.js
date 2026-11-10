/* macOS Lens site: the frozen-screen demos (.lx) and the page's small behaviours (the reel, the copy
   buttons, the capability wells). A demo is plain DOM: its words are spans, and the brackets, the hole
   and the results sheet sit in fractions of the screen, so a resize keeps them in place. */

const RM = matchMedia('(prefers-reduced-motion: reduce)');
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const el = (tag, cls, html) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (html != null) e.innerHTML = html;
  return e;
};
const esc = s => s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const trunc = (s, n) => (s.length > n ? s.slice(0, n - 1).trimEnd() + '…' : s);

const I = d => `<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`;
const ICON = {
  copy: I('<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/>'),
  translate: I('<path d="M4 5h9M8.5 3v2M11 5c-1 4-3.5 7-7 9M6.5 9c1.2 2 3 3.6 5 4.5"/><path d="M13 21l4-9 4 9M14.5 18h5"/>'),
  listen: I('<path d="M4 9v6h4l5 4V5L8 9z"/><path d="M16.5 8.5a5 5 0 0 1 0 7M19 6a8.5 8.5 0 0 1 0 12"/>'),
  stop: I('<rect x="7" y="7" width="10" height="10" rx="1.5"/>'),
  search: I('<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4.5 4.5"/>'),
  close: I('<path d="M6 6l12 12M18 6L6 18"/>'),
  text: I('<path d="M5 6V4.5h14V6M12 4.5v15M9 19.5h6"/>'),
  open: I('<path d="M14 4h6v6M20 4l-9 9M18 14v4a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4"/>'),
  email: I('<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3.5 6.5L12 13l8.5-6.5"/>'),
  phone: I('<path d="M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2"/>'),
  address: I('<path d="M12 21s-7-6.2-7-11.5a7 7 0 0 1 14 0C19 14.8 12 21 12 21z"/><circle cx="12" cy="9.5" r="2.5"/>'),
  url: I('<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>'),
  track: I('<path d="M3 7.5L12 3l9 4.5v9L12 21l-9-4.5z"/><path d="M3 7.5L12 12l9-4.5M12 12v9"/>'),
  date: I('<rect x="3.5" y="5" width="17" height="15" rx="2"/><path d="M3.5 10h17M8 3v4M16 3v4"/>'),
};

/* the smart actions, named as the app names them */
const ACTION = {
  email: ['Send email', v => `New email to ${v}`],
  phone: ['Call', v => `Calling ${v}`],
  address: ['Maps', v => `Maps: ${v}`],
  url: ['Open website', v => `Opening ${v}`],
  track: ['Track package', v => `Tracking ${v}`],
  date: ['Add to calendar', v => `New event: ${v}`],
};

/* the hero's results. sepia(1) brings any photo to one warm hue first, so a hue-rotate lands each
   colour the same way whatever the photograph's own colour */
const CHAIR = 'assets/demo/chair.jpg';
const HUE = { red: [0, 1.6, 1], orange: [25, 1.8, 1.05], yellow: [50, 2, 1.1], olive: [68, 1.1, .85], green: [125, 1.3, .95],
  teal: [175, 1.3, .95], blue: [215, 1.8, 1], navy: [225, 1.6, .62], purple: [275, 1.3, .9], pink: [330, 1.4, 1.1],
  tan: [36, .9, 1.05], brown: [25, 1.2, .7], black: [0, 0, .42], grey: [0, 0, .9], gray: [0, 0, .9], white: [0, 0, 1.45] };
const tint = c => {
  const [h, s, b] = HUE[c];
  return s === 0 ? `grayscale(1) brightness(${b})` : `sepia(1) hue-rotate(${h - 38}deg) saturate(${s * 2.2}) brightness(${b})`;
};
const MATCHES = [
  { t: 'Butterfly sling chair, {c} leather', c: 'black', site: 'loftline.example', price: '$164' },
  { t: 'Folding lounge chair, {c} suede', c: 'olive', site: 'harbourhome.example', price: '$210' },
  { t: 'Sling chair with steel frame, {c}', c: 'tan', site: 'northfield.example', price: '$189' },
  { t: 'Replacement cover for butterfly chairs, {c}', c: 'navy', site: 'fabricshed.example', price: '$48' },
];
const WEB = [
  { site: 'hollisfurniture.shop › chairs', t: 'Butterfly chair, leather and steel', p: 'A folding steel frame with a cognac leather sling. Ships flat in one box.' },
  { site: 'designnotes.example', t: 'How the butterfly chair got its shape', p: 'One bent steel frame, four corners, and a sling that hangs between them.' },
  { site: 'smallspaces.example', t: 'Nine folding chairs for a small balcony', p: 'We folded, carried and sat in each one for a week.' },
];
const ITALIAN = /comod|uso|sera|balcone|chiude|attimo|giulia|bologna/i;
const WEB_IT = [
  { site: 'Translate · Italian to English', t: '“Very comfortable. I use it every evening on the balcony.”', p: 'Comodissima. La uso ogni sera sul balcone.' },
  { site: 'dictionary.example', t: 'comodissimo, comodissima', p: 'Italian adjective, the superlative of comodo: very comfortable.' },
  { site: 'phrasebook.example', t: 'Si chiude in un attimo', p: 'It folds (or closes) in a moment.' },
];

const area = r => r.w * r.h;
const overlap = (a, b) => {
  const w = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
  const h = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y);
  return w > 0 && h > 0 ? (w * h) / Math.min(area(a), area(b)) : 0;
};
const inside = (r, x, y) => x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
const pad = (r, p) => ({ left: r.left - p, right: r.right + p, top: r.top - p, bottom: r.bottom + p });

const lenses = [];
let active = null;

class Lens {
  constructor(root) {
    this.root = root;
    this.kind = root.dataset.lens;
    this.hero = this.kind === 'hero';
    this.screen = $('.lx__screen', root);
    this.ov = $('.ov', root);
    this.sheet = $('.sheet', root);
    this.state = 'idle';
    this.sel = null;
    this.region = null;
    this.speaking = null;
    this.wrapWords();
    this.build();
    this.bind();
    lenses.push(this);
  }

  /* every word of a [data-words] block becomes a span, translations included (a hidden one has no box) */
  wrapWords() {
    $$('[data-words]', this.screen).forEach(box => {
      const walk = document.createTreeWalker(box, NodeFilter.SHOW_TEXT);
      const nodes = [];
      for (let n = walk.nextNode(); n; n = walk.nextNode()) if (n.textContent.trim()) nodes.push(n);
      nodes.forEach(n => {
        const frag = document.createDocumentFragment();
        n.textContent.split(/(\s+)/).forEach(part => {
          if (!part) return;
          if (/^\s+$/.test(part)) frag.append(part);
          else { const s = el('span', 'w'); s.textContent = part; frag.append(s); }
        });
        n.replaceWith(frag);
      });
    });
    this.words = $$('.w', this.screen);
    this.words.forEach((w, i) => { w.dataset.i = i; });
  }

  build() {
    const NS = 'http://www.w3.org/2000/svg';
    this.hit = el('div', 'ov__hit');
    this.ink = document.createElementNS(NS, 'svg');
    this.ink.setAttribute('class', 'ov__ink');
    this.ink.setAttribute('aria-hidden', 'true');
    this.path = document.createElementNS(NS, 'path');
    this.ink.append(this.path);
    this.hole = el('div', 'hole');
    this.brk = el('div', 'brk', '<i></i><i></i><i></i><i></i>');
    this.x = el('button', 'ov__x', ICON.close);
    this.x.type = 'button';
    this.x.setAttribute('aria-label', 'Close');
    this.hint = el('p', 'ov__hint', 'Circle, tap or highlight to search');
    this.hint.setAttribute('aria-hidden', 'true');
    this.chips = el('div', 'ov__chips');
    this.chips.setAttribute('role', 'toolbar');
    this.chips.setAttribute('aria-label', 'Actions for the selected text');
    this.selchip = el('button', 'ov__selchip', ICON.text + '<span>Select text</span>');
    this.selchip.type = 'button';
    this.ha = el('i', 'ov__handle ov__handle--a');
    this.hb = el('i', 'ov__handle ov__handle--b');
    this.bar = el('form', 'ov__bar', `<input type="text" placeholder="Add to your search" aria-label="Add to your search" enterkeyhint="search" autocomplete="off"><button type="button">${ICON.translate}<span>Translate</span></button>`);
    this.input = $('input', this.bar);
    this.trBtn = $('button', this.bar);
    this.toastEl = el('p', 'ov__toast');
    this.toastEl.setAttribute('aria-hidden', 'true');
    [this.hole, this.brk, this.chips, this.selchip, this.ha, this.hb].forEach(e => { e.hidden = true; });
    this.ov.append(this.hit, this.ink, this.hole, this.brk, this.x, this.hint, this.chips, this.selchip, this.ha, this.hb, this.bar, this.toastEl);
    this.wake = el('button', 'lx__wake', '<kbd>⌘</kbd><kbd>⇧</kbd><kbd>2</kbd><span>Search the screen</span>');
    this.wake.type = 'button';
    this.screen.append(this.wake);
    this.live = this.hero ? $('#hero-live') : null;
    if (!this.live) {
      this.live = el('p', 'sr-only');
      this.live.setAttribute('aria-live', 'polite');
      this.root.append(this.live);
    }
  }

  /* ---------------------------------------------------------------- geometry */
  S() { return this.screen.getBoundingClientRect(); }
  frac(node, p = 0) {
    const s = this.S(), r = node.getBoundingClientRect();
    const x = clamp((r.left - s.left) / s.width - p, 0, 1), y = clamp((r.top - s.top) / s.height - p, 0, 1);
    return { x, y, w: Math.min(r.width / s.width + 2 * p, 1 - x), h: Math.min(r.height / s.height + 2 * p, 1 - y) };
  }
  /* an original under its translation, or a translation not yet shown, is not on screen */
  shown(w) {
    const o = w.closest('.orig, .tr');
    if (!o) return true;
    const on = o.parentElement.classList.contains('is-translated');
    return o.classList.contains('tr') ? on : !on;
  }
  visible() {
    const live = this.screen.getClientRects().length > 0;
    return this.words.filter(w => this.shown(w) && (!live || w.getClientRects().length));
  }
  wordAt(cx, cy, p = 2) { return this.visible().find(w => inside(pad(w.getBoundingClientRect(), p), cx, cy)); }
  nearestWord(cx, cy) {
    let best = null, bd = Infinity;
    for (const w of this.visible()) {
      const r = w.getBoundingClientRect();
      const dx = cx < r.left ? r.left - cx : cx > r.right ? cx - r.right : 0;
      const dy = cy < r.top ? r.top - cy : cy > r.bottom ? cy - r.bottom : 0;
      const d = dx + dy * 3;
      if (d < bd) { bd = d; best = w; }
    }
    return best;
  }
  wordsIn(reg) {
    const s = this.S();
    return this.visible().filter(w => {
      const r = w.getBoundingClientRect();
      const x = (r.left + r.width / 2 - s.left) / s.width, y = (r.top + r.height / 2 - s.top) / s.height;
      return x >= reg.x && x <= reg.x + reg.w && y >= reg.y && y <= reg.y + reg.h;
    });
  }
  say(msg) { this.live.textContent = ''; requestAnimationFrame(() => { this.live.textContent = msg; }); }
  toast(msg) {
    this.toastEl.textContent = msg;
    this.toastEl.classList.add('is-on');
    clearTimeout(this.tt);
    this.tt = setTimeout(() => this.toastEl.classList.remove('is-on'), 2000);
    this.say(msg);
  }

  /* ---------------------------------------------------------------- states: idle, open, search, text */
  set(state) {
    if (state !== 'text') this.clearSel();
    this.state = state;
    this.root.dataset.state = state;
    this.brk.hidden = state !== 'search';
    this.hole.hidden = state !== 'search';
    this.chips.hidden = state !== 'text' || !this.sel;
    this.ha.hidden = this.hb.hidden = state !== 'text' || !this.sel;
    if (state !== 'search') { this.selchip.hidden = true; this.root.classList.remove('has-sheet'); }
    if (state !== 'idle') active = this;
    this.syncTr();
  }
  open(how = 'search') {
    this.cancelIntro();
    this.stopSpeech();
    if (this.state === 'idle' && !RM.matches) {
      this.root.classList.add('is-opening');
      setTimeout(() => this.root.classList.remove('is-opening'), 950);
    }
    this.root.classList.remove('is-touched');
    if (how === 'text') {
      this.selectAll();
      this.say('Every word on the screen is selected. Copy, Translate, Listen or Search.');
      return;
    }
    this.region = { x: .015, y: .022, w: .97, h: .956 };
    this.place();
    this.set('open');
    this.say('The screen is frozen and nothing is selected yet. Circle anything to search for it, or drag across words to select them.');
  }
  close() {
    this.cancelIntro();
    this.stopSpeech();
    this.set('idle');
    this.say('Closed. Press Command Shift 2 to freeze the screen again.');
  }
  place() {
    const r = this.region;
    const css = { left: r.x * 100 + '%', top: r.y * 100 + '%', width: r.w * 100 + '%', height: r.h * 100 + '%' };
    Object.assign(this.brk.style, css);
    Object.assign(this.hole.style, css);
  }
  morph() {
    if (RM.matches) return;
    this.root.classList.remove('is-morph');
    void this.root.offsetWidth;
    this.root.classList.add('is-morph');
    clearTimeout(this.mt);
    this.mt = setTimeout(() => this.root.classList.remove('is-morph'), 360);
  }
  search(reg, { animate = true, text = null } = {}) {
    this.region = reg;
    this.place();
    this.set('search');
    if (animate) this.morph();
    const ws = this.wordsIn(reg);
    this.selchip.hidden = !ws.length || !!text;
    this.layout();
    if (this.hero) this.results(reg, text || null);
    else this.say(ws.length ? 'Area selected. It has words in it: choose Select text to select them.' : 'Area selected.');
  }

  /* the hero's results sheet: the chair's visual matches, web results for words, or nothing */
  results(reg, text) {
    const chair = $('[data-obj]', this.screen);
    const onChair = !text && overlap(reg, this.frac(chair)) > .3;
    const words = text || this.wordsIn(reg).map(w => w.textContent).join(' ');
    this.sheet.classList.add('is-loading');
    this.root.classList.add('has-sheet');
    clearTimeout(this.rt);
    this.rt = setTimeout(() => {
      if (onChair) this.renderMatches();
      else if (words) this.renderWeb(words);
      else this.renderEmpty();
      this.sheet.classList.remove('is-loading');
    }, RM.matches ? 0 : 420);
  }
  head(thumb, q, sub) {
    return `<div class="sheet__head">${thumb ? `<span class="sheet__thumb" style="background-image:url(${thumb})"></span>` : ''}
      <p class="sheet__q"><b>${esc(q)}</b><span>${esc(sub)}</span></p></div>`;
  }
  foot() { return `<div class="sheet__foot"><button class="sheet__open" type="button">${ICON.open}<span>Open in browser</span></button></div>`; }
  renderMatches(refine = '') {
    const colour = Object.keys(HUE).find(c => new RegExp(`\\b${c}\\b`, 'i').test(refine));
    let list = MATCHES.map(m => ({ ...m, c: colour || m.c }));
    if (refine && !colour) list = [list[2], list[0], list[3], list[1]];
    const q = refine ? `Butterfly chair · ${refine}` : 'Butterfly chair';
    this.sheet.innerHTML = this.head(CHAIR, q, 'Visual matches') + `<div class="sheet__body"><p class="sheet__label">Visual matches</p><div class="sheet__grid">${
      list.map(m => `<div class="res"><span class="res__img" style="background-image:url(${CHAIR});--f:${tint(m.c)}"></span><b>${esc(m.t.replace('{c}', m.c))}</b><span>${m.site}</span><em>${m.price}</em></div>`).join('')
    }</div></div>` + this.foot();
    this.mode = 'matches';
    this.say(`Visual matches for the butterfly chair${refine ? `, ${refine}` : ''}: ${list.length} shops.`);
  }
  renderWeb(words) {
    const list = ITALIAN.test(words) ? WEB_IT : WEB;
    this.sheet.innerHTML = this.head(null, `“${trunc(words, 42)}”`, 'Search results') + `<div class="sheet__body"><p class="sheet__label">Top results</p><div class="sheet__list">${
      list.map(r => `<div class="sheet__item"><span>${esc(r.site)}</span><b>${esc(r.t)}</b><p>${esc(r.p)}</p></div>`).join('')
    }</div></div>` + this.foot();
    this.mode = 'web';
    this.query = words;
    this.say(`Search results for ${trunc(words, 60)}.`);
  }
  renderEmpty() {
    this.sheet.innerHTML = this.head(null, 'This area', 'No matches') + '<div class="sheet__body"><p class="sheet__empty">Nothing to match in this area. Try circling the chair.</p></div>' + this.foot();
    this.mode = 'empty';
    this.say('No matches in this area.');
  }

  /* ---------------------------------------------------------------- text */
  clearSel() {
    $$('.w.is-sel', this.screen).forEach(w => w.classList.remove('is-sel'));
    this.sel = null;
  }
  selWords() {
    if (!this.sel) return [];
    const [a, b] = this.sel;
    const vis = new Set(this.visible());
    return this.words.slice(a, b + 1).filter(w => vis.has(w));
  }
  select(a, b, { act = null, quiet = false } = {}) {
    if (a > b) [a, b] = [b, a];
    this.stopSpeech();
    this.set('text');
    this.clearSel();
    this.sel = [a, b];
    const ws = this.selWords();
    ws.forEach(w => w.classList.add('is-sel'));
    this.chips.hidden = this.ha.hidden = this.hb.hidden = !ws.length;
    this.renderChips(act);
    this.layout();
    if (!quiet) this.say(`${ws.length} word${ws.length === 1 ? '' : 's'} selected: ${trunc(ws.map(w => w.textContent).join(' '), 80)}`);
  }
  selectNodes(ws, opts) {
    if (!ws.length) return;
    const ix = ws.map(w => +w.dataset.i);
    this.select(Math.min(...ix), Math.max(...ix), opts);
  }
  selectAll() {
    const vis = this.visible();
    if (vis.length) this.selectNodes(vis, { quiet: true });
  }
  entOf(ws) {
    const ents = [...new Set(ws.map(w => w.closest('[data-ent]')))];
    return ents.length === 1 && ents[0] ? ents[0] : null;
  }
  trsOf(ws) { return [...new Set(ws.map(w => w.closest('[data-tr]')).filter(Boolean))]; }
  renderChips(act = this.act) {
    this.act = act;
    const ws = this.selWords();
    const ent = this.entOf(ws);
    const trs = this.trsOf(ws);
    const shownTr = trs.length && trs.every(t => t.classList.contains('is-translated'));
    const chips = [];
    if (ent) chips.push([ent.dataset.ent, ACTION[ent.dataset.ent][0]]);
    chips.push(['copy', 'Copy'], ['translate', shownTr ? 'Show original' : 'Translate'], [this.speaking ? 'stop' : 'listen', this.speaking ? 'Stop' : 'Listen'], ['search', 'Search']);
    this.chips.innerHTML = chips.map(([k, label]) =>
      `<button type="button" data-k="${k}"${k === act ? ' class="is-act"' : ''}>${ICON[k === 'stop' ? 'stop' : k]}<span>${label}</span></button>`).join('');
  }
  chip(k) {
    const ws = this.selWords();
    if (!ws.length) return;
    const text = ws.map(w => w.textContent).join(' ');
    this.act = null;
    if (k === 'copy') { copyText(text); this.toast('Copied'); }
    else if (k === 'translate') this.translate(this.trsOf(ws));
    else if (k === 'listen' || k === 'stop') { if (this.speaking) this.stopSpeech(); else this.speak(ws); }
    else if (k === 'search') {
      if (this.hero) {
        const s = this.S();
        const r = ws.map(w => w.getBoundingClientRect()).reduce((u, b) => ({ left: Math.min(u.left, b.left), top: Math.min(u.top, b.top), right: Math.max(u.right, b.right), bottom: Math.max(u.bottom, b.bottom) }));
        const p = 6;
        const x = clamp((r.left - p - s.left) / s.width, 0, 1), y = clamp((r.top - p - s.top) / s.height, 0, 1);
        this.search({ x, y, w: Math.min((r.right - r.left + 2 * p) / s.width, 1 - x), h: Math.min((r.bottom - r.top + 2 * p) / s.height, 1 - y) }, { text });
      } else this.toast(`Searching Google for “${trunc(text, 32)}”`);
      return;
    } else if (ACTION[k]) this.toast(ACTION[k][1](this.entOf(ws).textContent.trim()));
    this.renderChips(null);
    this.layout();
  }
  translate(trs) {
    if (!trs.length) { this.toast('This text is already in English'); return; }
    const on = !trs.every(t => t.classList.contains('is-translated'));
    trs.forEach(t => t.classList.toggle('is-translated', on));
    this.toast(on ? 'Translated from Italian' : 'Showing the original');
    if (this.state === 'text') this.selectNodes(trs.flatMap(t => $$('.w', t)).filter(w => this.shown(w)), { quiet: true });
    this.syncTr();
  }
  translateAll() {
    const trs = $$('[data-tr]', this.screen);
    if (!trs.length) { this.toast('This screen is already in English'); return; }
    const on = !trs.every(t => t.classList.contains('is-translated'));
    trs.forEach(t => t.classList.toggle('is-translated', on));
    this.toast(on ? 'Translated from Italian' : 'Showing the original');
    if (this.state === 'text' && this.sel) {
      const vis = this.visible();
      const keep = vis.filter(w => !w.closest('[data-tr]') && w.classList.contains('is-sel'));
      this.selectNodes(keep.length ? keep : trs.flatMap(t => $$('.w', t)).filter(w => this.shown(w)), { quiet: true });
    } else this.layout();
    this.syncTr();
  }
  syncTr() {
    const trs = $$('[data-tr]', this.screen);
    const on = trs.length && trs.every(t => t.classList.contains('is-translated'));
    $('span', this.trBtn).textContent = on ? 'Show original' : 'Translate';
  }

  /* Listen: the browser's own voice, the word being read lit; a browser with no word events steps along */
  speak(ws) {
    const words = ws.map(w => w.textContent);
    let off = 0;
    const starts = words.map(t => { const s = off; off += t.length + 1; return s; });
    const mark = i => ws.forEach((w, j) => w.classList.toggle('is-speaking', j === i));
    const run = { ws, done: false };
    this.speaking = run;
    const finish = () => {
      if (run.done) return;
      run.done = true;
      clearInterval(run.timer);
      ws.forEach(w => w.classList.remove('is-speaking'));
      if (this.speaking === run) this.speaking = null;
      if (this.state === 'text') { this.renderChips(null); this.layout(); }
    };
    run.finish = finish;
    const step = (own) => {
      let i = 0;
      mark(0);
      run.timer = setInterval(() => {
        i += 1;
        if (i >= ws.length) { clearInterval(run.timer); if (own) finish(); else mark(-1); return; }
        mark(i);
      }, 330);
    };
    const synth = window.speechSynthesis;
    if (synth && window.SpeechSynthesisUtterance) {
      const u = new SpeechSynthesisUtterance(words.join(' '));
      u.lang = ws.every(w => w.closest('.orig')) ? 'it-IT' : 'en-US';
      let got = false;
      u.onboundary = e => {
        if (e.name && e.name !== 'word') return;
        if (!got) { got = true; clearInterval(run.timer); }
        let i = 0;
        while (i + 1 < starts.length && starts[i + 1] <= e.charIndex) i++;
        mark(i);
      };
      u.onend = u.onerror = finish;
      synth.cancel();
      synth.speak(u);
      setTimeout(() => { if (!got && !run.done) step(false); }, 700);
    } else {
      this.toast('This browser has no voice to read with');
      step(true);
    }
    this.renderChips(null);
    this.layout();
    this.say('Reading the selection aloud.');
  }
  stopSpeech() {
    const run = this.speaking;
    if (!run) return;
    try { window.speechSynthesis?.cancel(); } catch { /* no voice */ }
    run.finish();
  }

  /* ---------------------------------------------------------------- where the chips, handles and the Select text chip sit */
  layout() {
    const s = this.S();
    if (!s.width) return;
    const room = this.hero && this.root.classList.contains('has-sheet') && this.sheet.getBoundingClientRect().left > s.left + s.width / 2
      ? this.sheet.getBoundingClientRect().left - s.left - 8 : s.width - 8;
    if (this.state === 'text' && this.sel) {
      const rs = this.selWords().flatMap(w => [...w.getClientRects()]).filter(r => r.width);
      if (!rs.length) return;
      const top = Math.min(...rs.map(r => r.top)) - s.top, bottom = Math.max(...rs.map(r => r.bottom)) - s.top;
      const left = Math.min(...rs.map(r => r.left)) - s.left, right = Math.max(...rs.map(r => r.right)) - s.left;
      const cw = this.chips.offsetWidth, ch = this.chips.offsetHeight;
      const below = top < ch + 16;
      this.chips.classList.toggle('is-below', below);
      this.chips.style.left = clamp((left + right) / 2, cw / 2 + 8, Math.max(cw / 2 + 8, s.width - cw / 2 - 8)) + 'px';
      this.chips.style.top = (below ? bottom : top) + 'px';
      const a = rs[0], b = rs[rs.length - 1];
      Object.assign(this.ha.style, { left: a.left - s.left + 'px', top: a.bottom - s.top + 'px' });
      Object.assign(this.hb.style, { left: b.right - s.left + 'px', top: b.bottom - s.top + 'px' });
    }
    if (this.state === 'search' && !this.selchip.hidden) {
      const r = this.region, sw = this.selchip.offsetWidth;
      const bottom = (r.y + r.h) * s.height;
      const low = bottom > s.height - 64;
      this.selchip.classList.toggle('is-above', low);
      this.selchip.style.left = clamp((r.x + r.w / 2) * s.width, sw / 2 + 8, Math.max(sw / 2 + 8, room - sw / 2)) + 'px';
      this.selchip.style.top = bottom + 'px';
    }
  }

  /* ---------------------------------------------------------------- gestures */
  local(e) { const s = this.S(); return [e.clientX - s.left, e.clientY - s.top]; }
  em() { return parseFloat(getComputedStyle(this.screen).fontSize) || 16; }
  touched() {
    this.cancelIntro();
    this.root.classList.add('is-touched');
  }
  down(e) {
    if (e.button > 0 || this.state === 'idle') return;
    this.touched();
    this.hit.setPointerCapture(e.pointerId);
    const s = this.S();
    const [x, y] = this.local(e);
    const r = this.region;
    const inRegion = r && x >= r.x * s.width && x <= (r.x + r.w) * s.width && y >= r.y * s.height && y <= (r.y + r.h) * s.height;
    this.g = { id: e.pointerId, x0: e.clientX, y0: e.clientY, pts: [[x, y]], moved: false,
      move: this.state === 'search' && inRegion && !this.wordAt(e.clientX, e.clientY) ? { ...r } : null };
    this.ink.classList.remove('is-fading');
  }
  drag(e) {
    const g = this.g;
    if (!g || g.id !== e.pointerId) return;
    if (!g.moved && Math.hypot(e.clientX - g.x0, e.clientY - g.y0) < 8) return;
    g.moved = true;
    if (g.move) {
      const s = this.S();
      const r = this.region;
      r.x = clamp(g.move.x + (e.clientX - g.x0) / s.width, 0, 1 - r.w);
      r.y = clamp(g.move.y + (e.clientY - g.y0) / s.height, 0, 1 - r.h);
      this.root.classList.add('is-dragging');
      this.selchip.hidden = true;
      this.place();
      return;
    }
    g.pts.push(this.local(e));
    this.path.setAttribute('d', 'M' + g.pts.map(p => p.map(n => n.toFixed(1)).join(' ')).join(' L'));
  }
  up(e) {
    const g = this.g;
    if (!g || g.id !== e.pointerId) return;
    this.g = null;
    if (e.type === 'pointercancel') { this.path.setAttribute('d', ''); this.root.classList.remove('is-dragging'); return; }
    if (g.move && g.moved) {
      this.root.classList.remove('is-dragging');
      this.search(this.region, { animate: false });
      return;
    }
    if (!g.moved) { this.tap(e.clientX, e.clientY); return; }
    this.stroke(g.pts);
  }
  tap(cx, cy) {
    this.root.classList.add('is-engaged');
    const w = this.wordAt(cx, cy);
    if (w) {
      const ent = w.closest('[data-ent]');
      if (ent) this.selectNodes($$('.w', ent), { act: ent.dataset.ent });
      else this.selectNodes([w]);
      return;
    }
    const obj = $$('[data-obj]', this.screen).find(o => inside(o.getBoundingClientRect(), cx, cy));
    if (obj) { this.search(this.frac(obj, .012)); return; }
    if (this.state === 'search' || this.state === 'text') { this.open(); return; }
    this.say('Drag around anything to search for it, or across words to select them.');
  }
  stroke(pts) {
    const s = this.S();
    const xs = pts.map(p => p[0]), ys = pts.map(p => p[1]);
    const box = { l: Math.min(...xs), t: Math.min(...ys), r: Math.max(...xs), b: Math.max(...ys) };
    const bw = box.r - box.l, bh = box.b - box.t;
    const [sx, sy] = pts[0], [ex, ey] = pts[pts.length - 1];
    const closed = Math.hypot(ex - sx, ey - sy) < .35 * Math.max(bw, bh);
    const hits = [...new Set(pts.map(([x, y]) => this.wordAt(x + s.left, y + s.top, 3)).filter(Boolean))];
    const fade = () => {
      this.ink.classList.add('is-fading');
      setTimeout(() => { if (!this.g) { this.path.setAttribute('d', ''); this.ink.classList.remove('is-fading'); } }, 260);
    };
    if (hits.length) {
      const hs = hits.map(w => w.getBoundingClientRect().height).sort((a, b) => a - b);
      const lineH = hs[hs.length >> 1];
      const a = this.wordAt(sx + s.left, sy + s.top, 6), b = this.wordAt(ex + s.left, ey + s.top, 6);
      if (bh <= lineH * 1.7 || (!closed && a && b)) {
        fade();
        if (!closed && a && b) this.select(+a.dataset.i, +b.dataset.i);
        else this.selectNodes(hits);
        return;
      }
    }
    fade();
    const min = .06;
    let w = Math.max(bw / s.width, min), h = Math.max(bh / s.height, min);
    let x = (box.l + bw / 2) / s.width - w / 2, y = (box.t + bh / 2) / s.height - h / 2;
    w = Math.min(w, 1); h = Math.min(h, 1);
    x = clamp(x, 0, 1 - w); y = clamp(y, 0, 1 - h);
    this.search({ x, y, w, h });
  }

  /* the corners resize the region; a search again on release, without the morph */
  corner(e, k) {
    if (e.button > 0) return;
    e.stopPropagation();
    this.touched();
    const t = e.currentTarget;
    t.setPointerCapture(e.pointerId);
    const s = this.S();
    const r0 = { ...this.region };
    const left = k === 0 || k === 2, topEdge = k < 2;
    const min = .06;
    const mv = ev => {
      const dx = (ev.clientX - e.clientX) / s.width, dy = (ev.clientY - e.clientY) / s.height;
      const r = this.region;
      if (left) { r.x = clamp(r0.x + dx, 0, r0.x + r0.w - min); r.w = r0.x + r0.w - r.x; }
      else r.w = clamp(r0.w + dx, min, 1 - r0.x);
      if (topEdge) { r.y = clamp(r0.y + dy, 0, r0.y + r0.h - min); r.h = r0.y + r0.h - r.y; }
      else r.h = clamp(r0.h + dy, min, 1 - r0.y);
      this.root.classList.add('is-dragging');
      this.selchip.hidden = true;
      this.place();
    };
    const end = ev => {
      t.removeEventListener('pointermove', mv);
      t.removeEventListener('pointerup', end);
      t.removeEventListener('pointercancel', end);
      this.root.classList.remove('is-dragging');
      if (ev.type !== 'pointercancel') this.search(this.region, { animate: false });
    };
    t.addEventListener('pointermove', mv);
    t.addEventListener('pointerup', end);
    t.addEventListener('pointercancel', end);
  }

  /* the selection handles: the nearest word above the finger becomes that end */
  handle(e, end) {
    if (e.button > 0 || !this.sel) return;
    e.stopPropagation();
    this.touched();
    const t = e.currentTarget;
    t.setPointerCapture(e.pointerId);
    let [a, b] = this.sel;
    const lift = this.em() * .9;
    const mv = ev => {
      const w = this.nearestWord(ev.clientX, ev.clientY - lift);
      if (!w) return;
      const i = +w.dataset.i;
      if (end === 'a') a = i; else b = i;
      this.select(Math.min(a, b), Math.max(a, b), { quiet: true });
    };
    const done = () => {
      t.removeEventListener('pointermove', mv);
      t.removeEventListener('pointerup', done);
      t.removeEventListener('pointercancel', done);
      const ws = this.selWords();
      this.say(`${ws.length} word${ws.length === 1 ? '' : 's'} selected.`);
    };
    t.addEventListener('pointermove', mv);
    t.addEventListener('pointerup', done);
    t.addEventListener('pointercancel', done);
  }

  /* ---------------------------------------------------------------- the bar and the sheet */
  chairRegion() { return this.frac($('[data-obj]', this.screen), .012); }
  refine(q) {
    if (!this.hero) { this.toast(`Searching Google for “${trunc(q, 32)}”`); return; }
    const was = this.state === 'search' ? this.mode : 'matches';
    if (this.state !== 'search') this.search(this.chairRegion());
    this.sheet.classList.add('is-loading');
    clearTimeout(this.rt);
    this.rt = setTimeout(() => {
      if (was === 'web') this.renderWeb(`${this.query} ${q}`);
      else if (was === 'empty') this.renderWeb(q);
      else this.renderMatches(q);
      this.sheet.classList.remove('is-loading');
    }, RM.matches ? 0 : 420);
  }

  bind() {
    this.hit.addEventListener('pointerdown', e => this.down(e));
    this.hit.addEventListener('pointermove', e => this.drag(e));
    this.hit.addEventListener('pointerup', e => this.up(e));
    this.hit.addEventListener('pointercancel', e => this.up(e));
    $$('i', this.brk).forEach((c, k) => c.addEventListener('pointerdown', e => this.corner(e, k)));
    this.ha.addEventListener('pointerdown', e => this.handle(e, 'a'));
    this.hb.addEventListener('pointerdown', e => this.handle(e, 'b'));
    this.x.addEventListener('click', e => { e.stopPropagation(); this.close(); this.screen.focus({ preventScroll: true }); });
    this.selchip.addEventListener('click', () => { this.touched(); this.selectNodes(this.wordsIn(this.region)); });
    this.chips.addEventListener('click', e => {
      const b = e.target.closest('button[data-k]');
      if (b) { this.touched(); this.chip(b.dataset.k); }
    });
    this.bar.addEventListener('submit', e => {
      e.preventDefault();
      const q = this.input.value.trim();
      if (q) { this.touched(); this.refine(q); }
    });
    this.trBtn.addEventListener('click', () => { this.touched(); this.translateAll(); });
    this.sheet?.addEventListener('click', e => {
      if (!e.target.closest('.sheet__open')) return;
      this.toast(this.mode === 'matches' ? 'Opens in your browser, with the image you circled' : 'Opens the search in your browser');
    });
    this.screen.addEventListener('click', () => { if (this.state === 'idle') this.open(); });
    this.screen.addEventListener('keydown', e => {
      if (e.target !== this.screen || (e.key !== 'Enter' && e.key !== ' ')) return;
      e.preventDefault();
      this.touched();
      if (this.state === 'idle') this.open();
      else if (this.hero) this.search(this.chairRegion());
      else this.selectAll();
    });
    new ResizeObserver(() => { this.path.setAttribute('d', ''); this.layout(); }).observe(this.screen);
    new IntersectionObserver(([en]) => {
      this.ratio = en.intersectionRatio;
      if (en.intersectionRatio < .2) { this.root.classList.remove('is-engaged'); this.stopSpeech(); }
      if (this.hero && en.intersectionRatio >= .5 && !this.introDone) this.intro();
    }, { threshold: [0, .2, .5, .8, 1] }).observe(this.root);
  }

  /* the hero draws its own circle around the chair once, the first time it is on screen */
  intro() {
    this.introDone = true;
    if (RM.matches) { this.search(this.chairRegion(), { animate: false }); return; }
    this.it = setTimeout(() => {
      const s = this.S(), c = $('[data-obj]', this.screen).getBoundingClientRect();
      const cx = c.left + c.width / 2 - s.left, cy = c.top + c.height / 2 - s.top;
      const rx = c.width * .56, ry = c.height * .52;
      const t0 = performance.now(), dur = 1100;
      const pts = [];
      const frame = now => {
        const k = Math.max(0, Math.min((now - t0) / dur, 1));
        const e = 1 - Math.pow(1 - k, 3);
        const n = Math.round(e * 64);
        while (pts.length <= n) {
          const a = -Math.PI * .62 + (pts.length / 64) * Math.PI * 2.08;
          const wob = 1 + .035 * Math.sin(pts.length * .7);
          pts.push([cx + Math.cos(a) * rx * wob, cy + Math.sin(a) * ry * wob]);
        }
        this.path.setAttribute('d', 'M' + pts.map(p => p.map(v => v.toFixed(1)).join(' ')).join(' L'));
        if (k < 1) this.raf = requestAnimationFrame(frame);
        else {
          this.raf = null;
          this.ink.classList.add('is-fading');
          setTimeout(() => { this.path.setAttribute('d', ''); this.ink.classList.remove('is-fading'); }, 260);
          this.search(this.chairRegion());
        }
      };
      this.raf = requestAnimationFrame(frame);
    }, 900);
  }
  cancelIntro() {
    this.introDone = true;
    clearTimeout(this.it);
    if (this.raf) { cancelAnimationFrame(this.raf); this.raf = null; this.path.setAttribute('d', ''); }
  }

  start() {
    if (this.hero) {
      this.root.classList.remove('has-sheet');
      this.region = { x: .015, y: .022, w: .97, h: .956 };
      this.place();
      this.set('open');
      return;
    }
    const first = $('[data-start]', this.screen);
    if (this.kind === 'translate') {
      $$('[data-tr]', this.screen).forEach(t => t.classList.add('is-translated'));
      this.set('text');
      return;
    }
    const act = { copy: 'copy', listen: 'listen' }[this.kind] || first?.dataset.ent || null;
    if (first) this.selectNodes($$('.w', first), { act, quiet: true });
    else this.set('text');
  }
}

/* ---------------------------------------------------------------- the page */
function copyText(text) {
  if (navigator.clipboard?.writeText) return navigator.clipboard.writeText(text).catch(() => fallbackCopy(text));
  fallbackCopy(text);
  return Promise.resolve();
}
function fallbackCopy(text) {
  const t = el('textarea');
  t.value = text;
  t.setAttribute('readonly', '');
  t.style.cssText = 'position:fixed;left:-9999px;top:0';
  document.body.append(t);
  t.select();
  try { document.execCommand('copy'); } catch { /* nothing to copy with */ }
  t.remove();
}

$$('.lx[data-lens]').forEach(root => new Lens(root));
lenses.forEach(l => l.start());
active = null;
const hero = lenses.find(l => l.hero);

const mostVisible = () => lenses.filter(l => (l.ratio || 0) > .35).sort((a, b) => b.ratio - a.ratio)[0];
const pressKey = mode => {
  const b = $(`.keybtn[data-lens-key="${mode}"]`);
  if (!b) return;
  b.classList.add('is-down');
  setTimeout(() => b.classList.remove('is-down'), 150);
};
const shortcut = (mode, lens = mostVisible() || hero) => {
  if (!lens) return;
  pressKey(mode);
  if ((lens.ratio || 0) < .35) lens.root.scrollIntoView({ behavior: RM.matches ? 'auto' : 'smooth', block: 'center' });
  lens.touched();
  lens.open(mode);
};

document.addEventListener('keydown', e => {
  const typing = e.target.closest?.('input, textarea, [contenteditable]') && !e.target.closest('.lx');
  if ((e.metaKey || e.ctrlKey) && e.shiftKey && !e.altKey && (e.code === 'Digit2' || e.code === 'Digit1')) {
    if (typing) return;
    e.preventDefault();
    shortcut(e.code === 'Digit2' ? 'search' : 'text');
    return;
  }
  if (e.key === 'Escape') {
    const l = lenses.find(x => x.root.contains(document.activeElement) && x.state !== 'idle')
      || lenses.filter(x => x.state !== 'idle' && (x.ratio || 0) > .35).sort((a, b) => b.ratio - a.ratio)[0];
    if (l) { e.preventDefault(); l.close(); if (l.root.contains(document.activeElement)) l.screen.focus(); }
  }
});
$$('.keybtn[data-lens-key]').forEach(b => b.addEventListener('click', () => shortcut(b.dataset.lensKey, hero)));
$$('[role="tab"]').forEach(t => t.addEventListener('click', () => lenses.forEach(l => l.stopSpeech())));
document.addEventListener('visibilitychange', () => { if (document.hidden) lenses.forEach(l => l.stopSpeech()); });

/* the reel plays while it is on screen, unless paused or motion is reduced; it starts muted */
const video = $('video[data-reel]');
if (video) {
  const btn = $('.reel__pause');
  const snd = $('.reel__sound');
  const hasSrc = !!video.querySelector('source') || !!video.getAttribute('src');
  let paused = false;
  const play = () => video.play().catch(err => {
    if (err && err.name === 'NotAllowedError' && !video.muted) { video.muted = true; video.play().catch(() => {}); }
  });
  if (btn) {
    btn.hidden = !hasSrc;
    btn.addEventListener('click', () => {
      paused = !paused;
      btn.setAttribute('aria-pressed', String(paused));
      btn.setAttribute('aria-label', paused ? 'Play the video' : 'Pause the video');
      if (paused) video.pause(); else play();
    });
  }
  if (snd) {
    snd.hidden = !hasSrc;
    const sync = () => snd.setAttribute('aria-pressed', String(!video.muted));
    snd.addEventListener('click', () => {
      video.muted = !video.muted;
      if (!video.muted && !paused && video.paused) play();
    });
    video.addEventListener('volumechange', sync);
    sync();
  }
  if (hasSrc && !RM.matches) {
    new IntersectionObserver(([en]) => {
      if (en.intersectionRatio >= .65 && !paused) play();
      else if (en.intersectionRatio < .65) video.pause();
    }, { threshold: [0, .65, 1] }).observe(video);
  } else if (hasSrc) {
    video.controls = true;
    if (btn) btn.hidden = true;
    if (snd) snd.hidden = true;
  }
  const ctl = $('.reel__controls');
  if (ctl) ctl.hidden = [btn, snd].every(b => !b || b.hidden);
  /* chapters jump the reel; the current one follows playback */
  const chapters = $('.chapters');
  if (chapters && hasSrc) {
    chapters.hidden = false;
    const marks = $$('button[data-t]', chapters);
    marks.forEach(m => m.addEventListener('click', () => {
      video.currentTime = Number(m.dataset.t);
      if (!RM.matches) { paused = false; if (btn) { btn.setAttribute('aria-pressed', 'false'); btn.setAttribute('aria-label', 'Pause the video'); } }
      play();
    }));
    video.addEventListener('timeupdate', () => {
      let cur = null;
      marks.forEach(m => { if (video.currentTime >= Number(m.dataset.t)) cur = m; });
      marks.forEach(m => m === cur ? m.setAttribute('aria-current', 'true') : m.removeAttribute('aria-current'));
    });
  }
}

/* install commands */
$$('[data-copy]').forEach(b => b.addEventListener('click', () => {
  const code = b.parentElement.querySelector('code');
  if (!code) return;
  copyText(code.textContent.trim());
  const label = b.getAttribute('aria-label');
  b.dataset.done = '';
  b.setAttribute('aria-label', 'Copied');
  clearTimeout(b._t);
  b._t = setTimeout(() => { b.setAttribute('aria-label', label === 'Copied' ? 'Copy the command' : label); delete b.dataset.done; }, 1600);
}));

/* the nav marks the section on screen */
{
  const links = $$('.nav__links > .nav__item > .nav__link[href^="#"]');
  const map = new Map([['#more', '#text']]);
  const ids = ['#watch', '#text', '#more', '#privacy', '#install', '#faq'].filter(id => $(id));
  const seen = new Map();
  const mark = () => {
    let cur = null;
    for (const id of ids) if (seen.get(id)) { cur = map.get(id) || id; break; }
    links.forEach(a => a.getAttribute('href') === cur ? a.setAttribute('aria-current', 'location') : a.removeAttribute('aria-current'));
  };
  const io = new IntersectionObserver(es => { es.forEach(e => seen.set('#' + e.target.id, e.isIntersecting)); mark(); }, { rootMargin: '-45% 0px -50% 0px' });
  ids.forEach(id => io.observe($(id)));
}

/* the capability wells take turns, one live at a time, while the grid is on screen */
const caps = $('.caps');
if (caps && !RM.matches) {
  const wells = $$('.well', caps);
  let i = Math.max(0, wells.findIndex(w => w.classList.contains('is-live'))), timer = null;
  const next = () => {
    wells[i].classList.remove('is-live');
    i = (i + 1) % wells.length;
    wells[i].classList.add('is-live');
  };
  new IntersectionObserver(([en]) => {
    if (en.isIntersecting && !timer) timer = setInterval(next, 6400);
    else if (!en.isIntersecting && timer) { clearInterval(timer); timer = null; }
  }, { threshold: .25 }).observe(caps);
  $$('.cap', caps).forEach((c, k) => c.addEventListener('pointerenter', () => {
    if (k === i) return;
    wells[i].classList.remove('is-live');
    i = k;
    wells[i].classList.add('is-live');
  }));
}

/* a DMG download: the download goes ahead as normal, and a tip in the corner says how to get past
   macOS's "Not Opened" dialog (Done, then Open Anyway). It never takes focus, and stays until closed. */
const gk = $('#gk');
if (gk) {
  const live = $('#gk-live');
  const onMac = /Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints < 2;
  if (!onMac) {
    $$('[data-mac-only]').forEach(e => { e.hidden = true; });
    $$('a[href^="x-apple.systempreferences:"]:not([data-mac-only])').forEach(a => a.replaceWith(document.createTextNode(a.textContent)));
  }
  let from = null;
  const hide = (to = from) => {
    if (gk.hidden) return;
    const back = gk.contains(document.activeElement);
    gk.hidden = true;
    live.textContent = '';
    // after the click's own default (a jump to #install moves focus to the page)
    if (back && to?.isConnected) setTimeout(() => to.focus({ preventScroll: true }));
  };
  const show = a => {
    from = a;
    if (!gk.hidden) return;
    gk.hidden = false;
    if (!RM.matches) gk.animate([{ opacity: 0, transform: 'translateY(12px)' }, { opacity: 1, transform: 'none' }], { duration: 320, easing: 'cubic-bezier(.2,.8,.2,1)' });
    else gk.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 160 });
    live.textContent = 'If macOS says macOS Lens Not Opened, click Done, not Move to Trash. Then click Open Anyway in System Settings, Privacy and Security.';
  };
  document.addEventListener('click', e => {
    const a = e.target.closest?.('a[href$="/macOS-Lens.dmg"]');
    if (a) show(a);
  });
  $('.gk__x', gk).addEventListener('click', () => hide());
  $('[data-gk-terminal]', gk).addEventListener('click', () => {
    const tab = $('#tab-curl');
    tab?.click();
    hide(tab);
  });
  document.addEventListener('keydown', e => { if (e.key === 'Escape') hide(); });
}
