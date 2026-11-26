// Markdown preview of Artel: markdown-it with Docusaurus-style admonitions, KaTeX math, Mermaid and Excalidraw
// diagrams, highlight.js code. The native side calls `artel.render(options)` and listens on the `artel` message
// handler for links, the selection (with source lines) and readiness.
(function () {
  'use strict';

  const post = (msg) => {
    try { window.webkit.messageHandlers.artel.postMessage(msg); } catch (e) { /* outside WKWebView */ }
  };
  // Errors reach the debug log of the app ($ARTEL_DEBUG_LOG).
  const consoleError = console.error.bind(console);
  console.error = (...args) => {
    consoleError(...args);
    post({ type: 'log', text: args.map((a) => (a && a.stack) || String(a)).join(' ') });
  };
  const escapeHTML = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const dark = () => window.matchMedia('(prefers-color-scheme: dark)').matches;

  let lineOffset = 0;

  const md = window.markdownit({
    html: true,
    linkify: true,
    typographer: false,
    highlight(code, lang) {
      if (lang && window.hljs && hljs.getLanguage(lang)) {
        try { return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value; } catch (e) { /* plain */ }
      }
      return '';
    },
  });

  // Source lines on every block, so a selection in the preview maps back to the file.
  md.core.ruler.push('artel_source_lines', (state) => {
    for (const t of state.tokens) {
      if (t.map && t.nesting >= 0 && t.type !== 'inline') {
        t.attrSet('data-line', String(t.map[0] + lineOffset));
        t.attrSet('data-line-end', String(t.map[1] + lineOffset));
      }
    }
  });

  // Heading anchors, Docusaurus-like: lower case, punctuation dropped, spaces → "-", duplicates numbered.
  const slugify = (s) => s.trim().toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/\s+/g, '-');
  md.core.ruler.push('artel_anchors', (state) => {
    const seen = {};
    const tokens = state.tokens;
    for (let i = 0; i < tokens.length; i++) {
      if (tokens[i].type !== 'heading_open') continue;
      const inline = tokens[i + 1];
      const text = inline && inline.children ? inline.children.filter((c) => c.type === 'text' || c.type === 'code_inline').map((c) => c.content).join('') : '';
      let id = slugify(text) || 'section';
      if (seen[id] !== undefined) { seen[id] += 1; id = `${id}-${seen[id]}`; } else { seen[id] = 0; }
      tokens[i].attrSet('id', id);
    }
  });

  // GitHub task lists: "- [ ] item" / "- [x] item".
  md.core.ruler.push('artel_tasks', (state) => {
    const tokens = state.tokens;
    for (let i = 2; i < tokens.length; i++) {
      const t = tokens[i];
      if (t.type !== 'inline' || tokens[i - 1].type !== 'paragraph_open' || tokens[i - 2].type !== 'list_item_open') continue;
      const m = /^\[([ xX])\](\s+|$)/.exec(t.content);
      if (!m || !t.children.length || t.children[0].type !== 'text') continue;
      t.children[0].content = t.children[0].content.replace(/^\[([ xX])\](\s+|$)/, '');
      const box = new state.Token('html_inline', '', 0);
      box.content = `<input type="checkbox" disabled${m[1] !== ' ' ? ' checked' : ''}>`;
      t.children.unshift(box);
      tokens[i - 2].attrJoin('class', 'task');
    }
  });

  // Math: $inline$, $$display$$ (inline or as a block).
  function mathInline(state, silent) {
    const src = state.src;
    const start = state.pos;
    if (src[start] !== '$') return false;
    const display = src[start + 1] === '$';
    const open = display ? 2 : 1;
    let end = start + open;
    for (;;) {
      end = src.indexOf(display ? '$$' : '$', end);
      if (end === -1) return false;
      if (src[end - 1] === '\\') { end += 1; continue; }
      break;
    }
    const content = src.slice(start + open, end);
    if (!content.trim()) return false;
    if (!display && (/^\s/.test(content) || /\s$/.test(content) || /\d/.test(src[end + 1] || ''))) return false;
    if (!silent) {
      const t = state.push('math_inline', 'math', 0);
      t.content = content;
      t.markup = display ? '$$' : '$';
    }
    state.pos = end + open;
    return true;
  }
  function mathBlock(state, startLine, endLine, silent) {
    if (state.sCount[startLine] - state.blkIndent >= 4) return false;
    let pos = state.bMarks[startLine] + state.tShift[startLine];
    let max = state.eMarks[startLine];
    if (state.src.slice(pos, pos + 2) !== '$$') return false;
    const firstLine = state.src.slice(pos + 2, max);
    let next = startLine;
    let content;
    if (firstLine.trim().endsWith('$$')) {
      content = firstLine.trim().slice(0, -2);
    } else {
      const lines = [firstLine];
      let found = false;
      for (next = startLine + 1; next < endLine; next++) {
        pos = state.bMarks[next] + state.tShift[next];
        max = state.eMarks[next];
        const line = state.src.slice(pos, max);
        if (line.trim().endsWith('$$')) { lines.push(line.trim().slice(0, -2)); found = true; break; }
        lines.push(line);
      }
      if (!found) return false;
      content = lines.join('\n');
    }
    if (silent) return true;
    state.line = next + 1;
    const t = state.push('math_block', 'math', 0);
    t.block = true;
    t.content = content;
    t.map = [startLine, state.line];
    return true;
  }
  const katexHTML = (tex, displayMode) => {
    try { return katex.renderToString(tex, { displayMode, throwOnError: false, output: 'htmlAndMathml' }); } catch (e) {
      return `<span class="math-error">${escapeHTML(tex)}</span>`;
    }
  };
  md.inline.ruler.after('escape', 'math_inline', mathInline);
  md.block.ruler.before('fence', 'math_block', mathBlock, { alt: ['paragraph', 'reference', 'blockquote', 'list'] });
  md.renderer.rules.math_inline = (tokens, idx) => katexHTML(tokens[idx].content, tokens[idx].markup === '$$');
  md.renderer.rules.math_block = (tokens, idx, opts, env, self) =>
    `<div class="math"${self.renderAttrs(tokens[idx])}>${katexHTML(tokens[idx].content, true)}</div>\n`;

  // Docusaurus admonitions: ":::note Title" / ":::tip[Title]" … ":::".
  const admonitions = {
    note: 'Note', tip: 'Tip', info: 'Info', warning: 'Warning', caution: 'Caution',
    danger: 'Danger', important: 'Important', success: 'Success',
  };
  for (const [name, defaultTitle] of Object.entries(admonitions)) {
    md.use(window.markdownitContainer, name, {
      validate: (params) => new RegExp(`^${name}(\\[|\\s|$)`).test(params.trim()),
      render(tokens, idx, opts, env, self) {
        const t = tokens[idx];
        if (t.nesting !== 1) return '</div>\n';
        const rest = t.info.trim().slice(name.length).trim();
        const m = /^\[(.*)\]/.exec(rest);
        const title = (m ? m[1] : rest) || defaultTitle;
        t.attrJoin('class', `admonition admonition-${name}`);
        return `<div${self.renderAttrs(t)}><div class="admonition-title">${md.renderInline(title)}</div>\n`;
      },
    });
  }

  // Fenced diagrams and math.
  const defaultFence = md.renderer.rules.fence;
  md.renderer.rules.fence = (tokens, idx, opts, env, self) => {
    const t = tokens[idx];
    const lang = (t.info || '').trim().split(/\s+/)[0].toLowerCase();
    const attrs = self.renderAttrs(t);
    if (lang === 'mermaid') {
      return `<div class="diagram mermaid-block"${attrs} data-source="${escapeHTML(t.content)}"><span class="pending">Diagram…</span></div>\n`;
    }
    if (lang === 'excalidraw') {
      return `<div class="diagram excalidraw-block"${attrs} data-source="${escapeHTML(t.content)}"><span class="pending">Diagram…</span></div>\n`;
    }
    if (lang === 'math' || lang === 'latex' || lang === 'katex' || lang === 'tex') {
      return `<div class="math"${attrs}>${katexHTML(t.content, true)}</div>\n`;
    }
    return defaultFence(tokens, idx, opts, env, self);
  };

  // ![alt](diagram.excalidraw) embeds the drawing.
  const defaultImage = md.renderer.rules.image;
  md.renderer.rules.image = (tokens, idx, opts, env, self) => {
    const src = tokens[idx].attrGet('src') || '';
    if (/\.excalidraw(\.json)?$/i.test(src.split(/[?#]/)[0])) {
      return `<span class="diagram excalidraw-block" style="display:block" data-url="${escapeHTML(src)}"><span class="pending">Diagram…</span></span>`;
    }
    return defaultImage(tokens, idx, opts, env, self);
  };

  // MDX: import/export lines are code, not content.
  function stripMDX(text) {
    let fence = false;
    return text.split('\n').map((line) => {
      if (/^\s*(```|~~~)/.test(line)) fence = !fence;
      if (!fence && /^(import|export)\s/.test(line)) return '';
      return line;
    }).join('\n');
  }

  // MARK: Diagrams

  let mermaidLoading = null;
  function loadMermaid() {
    if (window.mermaid) return Promise.resolve(window.mermaid);
    if (!mermaidLoading) {
      mermaidLoading = new Promise((resolve, reject) => {
        const s = document.createElement('script');
        s.src = 'artel-res://local/app/vendor/mermaid.min.js';
        s.onload = () => resolve(window.mermaid);
        s.onerror = () => reject(new Error('mermaid failed to load'));
        document.head.appendChild(s);
      });
    }
    return mermaidLoading;
  }

  let renderGeneration = 0;
  let mermaidCounter = 0;
  const errorBox = (title, detail, source) =>
    `<div class="diagram-error"><b>${escapeHTML(title)}</b>${detail ? `: ${escapeHTML(detail)}` : ''}${source ? `<pre>${escapeHTML(source)}</pre>` : ''}</div>`;

  async function renderMermaid(root, generation) {
    const blocks = Array.from(root.querySelectorAll('.mermaid-block'));
    if (!blocks.length) return;
    let mermaid;
    try { mermaid = await loadMermaid(); } catch (e) {
      blocks.forEach((b) => { b.innerHTML = errorBox('Mermaid is unavailable', e.message); });
      return;
    }
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      theme: dark() ? 'dark' : 'default',
      fontFamily: getComputedStyle(document.body).fontFamily,
    });
    for (const block of blocks) {
      if (generation !== renderGeneration) return;
      const source = block.dataset.source;
      try {
        const { svg } = await mermaid.render(`mermaid-${++mermaidCounter}`, source);
        if (generation !== renderGeneration) return;
        block.innerHTML = svg;
      } catch (e) {
        block.innerHTML = errorBox('Mermaid diagram error', (e && e.message || String(e)).split('\n')[0], source);
        document.querySelectorAll(`#dmermaid-${mermaidCounter}, #mermaid-${mermaidCounter}`).forEach((n) => n.remove());
      }
    }
  }

  // Excalidraw's own export (the optional Excalidraw download, see ExcalidrawAddon.swift). null = not available.
  let excalidrawModule = null;
  let excalidrawModuleURL = null;
  function loadExcalidrawModule(url) {
    if (!url) return Promise.resolve(null);
    if (url !== excalidrawModuleURL) {
      excalidrawModuleURL = url;
      // Its fonts are served from the same folder.
      window.EXCALIDRAW_ASSET_PATH = url.replace(/[^/]*$/, '');
      excalidrawModule = import(url).catch((e) => { console.error('excalidraw module', e); return null; });
    }
    return excalidrawModule;
  }

  async function officialExcalidraw(json, url) {
    const mod = await loadExcalidrawModule(url);
    if (!mod || !mod.sceneToSvg) return null;
    const svg = await mod.sceneToSvg(json, dark() ? 'dark' : 'light');
    svg.classList.add('excalidraw-official');
    return svg;
  }

  async function renderExcalidraw(root, generation) {
    const url = lastOptions && lastOptions.excalidrawModule;
    for (const block of Array.from(root.querySelectorAll('.excalidraw-block'))) {
      try {
        let json = block.dataset.source;
        if (!json && block.dataset.url) {
          const res = await fetch(new URL(block.dataset.url, document.baseURI));
          if (!res.ok) throw new Error(`file not found: ${block.dataset.url}`);
          json = await res.text();
        }
        if (generation !== renderGeneration) return;
        let svg = null;
        try { svg = await officialExcalidraw(json, url); } catch (e) { console.error('excalidraw export', e); }
        if (generation !== renderGeneration) return;
        if (!svg) svg = window.ArtelExcalidraw.render(JSON.parse(json));
        block.innerHTML = '';
        block.appendChild(svg);
        if (block.dataset.url) {
          // Like Obsidian: a click opens the drawing (to edit it).
          block.classList.add('linked');
          block.title = 'Open the drawing';
          block.addEventListener('click', () => post({ type: 'link', href: block.dataset.url }));
        }
      } catch (e) {
        block.innerHTML = errorBox("Couldn't render the Excalidraw drawing", e.message);
      }
    }
  }

  // MARK: Search highlight

  function highlightText(root, query) {
    const words = (query || '').split(/\s+/).filter(Boolean).map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
    if (!words.length) return;
    const re = new RegExp(`(${words.join('|')})`, 'giu');
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => (n.parentElement.closest('svg, .katex, script, style, mark') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
    });
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    let first = null;
    for (const node of nodes) {
      if (!re.test(node.nodeValue)) continue;
      re.lastIndex = 0;
      const frag = document.createDocumentFragment();
      let last = 0;
      node.nodeValue.replace(re, (m, _g, offset) => {
        frag.appendChild(document.createTextNode(node.nodeValue.slice(last, offset)));
        const mark = document.createElement('mark');
        mark.textContent = m;
        frag.appendChild(mark);
        if (!first) first = mark;
        last = offset + m.length;
        return m;
      });
      frag.appendChild(document.createTextNode(node.nodeValue.slice(last)));
      node.parentNode.replaceChild(frag, node);
    }
    if (first) first.scrollIntoView({ block: 'center' });
  }

  // MARK: Rendering

  let lastOptions = null;

  function render(options) {
    lastOptions = options;
    const generation = ++renderGeneration;
    const root = document.getElementById('content');
    const style = document.documentElement.style;
    if (options.font) style.setProperty('--font', options.font);
    if (options.fontSize) style.setProperty('--font-size', `${options.fontSize}px`);
    if (options.codeFont) style.setProperty('--code-font', options.codeFont);
    document.querySelector('base').href = options.base || 'artel-res://local/app/';
    lineOffset = options.lineOffset || 0;
    let text = options.markdown || '';
    if (options.mdx) text = stripMDX(text);
    let html = md.render(text);
    if (options.title && !/^\s*#\s/m.test(text)) html = `<h1>${escapeHTML(options.title)}</h1>\n${html}`;
    if (!text.trim() && !options.title) html = `<p class="empty">${escapeHTML(options.emptyText || 'Empty')}</p>`;
    const scroll = window.scrollY;
    root.innerHTML = html;
    if (options.keepScroll) window.scrollTo(0, scroll);
    else window.scrollTo(0, 0);
    if (options.highlight) highlightText(root, options.highlight);
    if (options.anchor) {
      const target = document.getElementById(options.anchor);
      if (target) target.scrollIntoView({ block: 'start' });
    }
    renderMermaid(root, generation);
    renderExcalidraw(root, generation);
  }

  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    if (lastOptions && document.querySelector('.mermaid-block, .excalidraw-block')) render({ ...lastOptions, keepScroll: true, highlight: null });
  });

  // MARK: Native bridge

  document.addEventListener('click', (e) => {
    const a = e.target.closest('a');
    if (!a) return;
    const href = a.getAttribute('href');
    if (!href) return;
    e.preventDefault();
    if (href.startsWith('#')) {
      const target = document.getElementById(decodeURIComponent(href.slice(1)));
      if (target) target.scrollIntoView({ behavior: 'smooth', block: 'start' });
      return;
    }
    post({ type: 'link', href });
  });

  const blockOf = (node) => {
    const el = node && (node.nodeType === 1 ? node : node.parentElement);
    return el ? el.closest('[data-line]') : null;
  };
  let selectionTimer = null;
  document.addEventListener('selectionchange', () => {
    clearTimeout(selectionTimer);
    selectionTimer = setTimeout(() => {
      const sel = window.getSelection();
      const text = sel ? sel.toString() : '';
      if (!sel || sel.isCollapsed || !text.trim() || !sel.rangeCount) { post({ type: 'selection', text: '' }); return; }
      const range = sel.getRangeAt(0);
      const start = blockOf(range.startContainer);
      const end = blockOf(range.endContainer);
      const first = start ? Number(start.dataset.line) : null;
      const last = end ? Number(end.dataset.lineEnd) : null;
      post({ type: 'selection', text, firstLine: first, lastLine: last });
    }, 120);
  });

  window.artel = { render };
  post({ type: 'ready' });
})();
