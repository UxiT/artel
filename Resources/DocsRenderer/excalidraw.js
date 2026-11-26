// Read-only renderer of .excalidraw scenes to SVG, with rough.js — the library Excalidraw itself draws with, so the
// element seeds give the same hand-drawn strokes. Covers shapes, lines and arrows (with arrowheads), free drawing,
// text, images and frames; editing is left to Excalidraw.
(function () {
  'use strict';
  const NS = 'http://www.w3.org/2000/svg';
  const el = (name, attrs, parent) => {
    const node = document.createElementNS(NS, name);
    for (const [k, v] of Object.entries(attrs || {})) if (v !== undefined && v !== null) node.setAttribute(k, v);
    if (parent) parent.appendChild(node);
    return node;
  };

  const FONTS = {
    1: '"Virgil", "Bradley Hand", "Segoe Print", "Comic Sans MS", cursive',
    5: '"Excalifont", "Bradley Hand", "Segoe Print", "Comic Sans MS", cursive',
    2: '"Helvetica Neue", Helvetica, Arial, sans-serif',
    6: '"Nunito", -apple-system, "Helvetica Neue", sans-serif',
    7: '"Lilita One", "Arial Rounded MT Bold", sans-serif',
    8: '"Comic Shanns", "Comic Sans MS", cursive',
    3: '"Cascadia Code", ui-monospace, Menlo, monospace',
  };

  function bounds(elements) {
    let minX = Infinity; let minY = Infinity; let maxX = -Infinity; let maxY = -Infinity;
    const add = (x, y) => { minX = Math.min(minX, x); minY = Math.min(minY, y); maxX = Math.max(maxX, x); maxY = Math.max(maxY, y); };
    for (const e of elements) {
      if (Array.isArray(e.points) && e.points.length) {
        for (const [px, py] of e.points) add(e.x + px, e.y + py);
      } else {
        // Rotation can push corners out: use the rotated box.
        const cx = e.x + e.width / 2; const cy = e.y + e.height / 2;
        const a = e.angle || 0;
        for (const [dx, dy] of [[-1, -1], [1, -1], [1, 1], [-1, 1]]) {
          const x = (dx * e.width) / 2; const y = (dy * e.height) / 2;
          add(cx + x * Math.cos(a) - y * Math.sin(a), cy + x * Math.sin(a) + y * Math.cos(a));
        }
      }
    }
    if (!isFinite(minX)) return { minX: 0, minY: 0, maxX: 100, maxY: 100 };
    return { minX, minY, maxX, maxY };
  }

  function options(e) {
    const sw = e.strokeWidth || 1;
    const fill = e.backgroundColor && e.backgroundColor !== 'transparent' ? e.backgroundColor : undefined;
    const o = {
      seed: e.seed || 1,
      roughness: e.roughness === undefined ? 1 : e.roughness,
      stroke: e.strokeColor || '#1e1e1e',
      strokeWidth: sw,
      fill,
      fillStyle: e.fillStyle === 'cross-hatch' ? 'cross-hatch' : e.fillStyle === 'zigzag' ? 'zigzag' : e.fillStyle === 'solid' ? 'solid' : 'hachure',
      fillWeight: sw / 2,
      hachureGap: sw * 4,
      disableMultiStroke: e.strokeStyle && e.strokeStyle !== 'solid',
      preserveVertices: (e.roughness || 0) < 2,
    };
    if (e.strokeStyle === 'dashed') o.strokeLineDash = [8, 8 + sw];
    if (e.strokeStyle === 'dotted') o.strokeLineDash = [1.5, 6 + sw];
    return o;
  }

  function cornerRadius(e) {
    if (!e.roundness) return 0;
    const m = Math.min(Math.abs(e.width), Math.abs(e.height));
    if (e.roundness.type === 3) {
      const fixed = e.roundness.value || 32;
      return m * 0.25 > fixed ? fixed : m * 0.25;
    }
    return m * 0.25;
  }

  function arrowhead(rc, g, kind, tip, from, e) {
    if (!kind) return;
    const o = options(e);
    const angle = Math.atan2(tip[1] - from[1], tip[0] - from[0]);
    const len = Math.hypot(tip[0] - from[0], tip[1] - from[1]);
    const size = Math.min(kind === 'bar' ? 10 : 20 + o.strokeWidth * 2, len * 0.6 || 10);
    const at = (a, r) => [tip[0] - r * Math.cos(angle + a), tip[1] - r * Math.sin(angle + a)];
    const solid = { ...o, fill: o.stroke, fillStyle: 'solid', strokeLineDash: undefined };
    const outline = { ...o, fill: undefined, strokeLineDash: undefined };
    let node;
    switch (kind) {
      case 'bar': node = rc.line(...at(Math.PI / 2, -size), ...at(-Math.PI / 2, -size), outline); break;
      case 'dot': case 'circle': node = rc.circle(...at(0, size / 3), size * 0.66, solid); break;
      case 'circle_outline': node = rc.circle(...at(0, size / 3), size * 0.66, outline); break;
      case 'triangle': node = rc.polygon([tip, at(0.4, size), at(-0.4, size)], solid); break;
      case 'triangle_outline': node = rc.polygon([tip, at(0.4, size), at(-0.4, size)], outline); break;
      case 'diamond': node = rc.polygon([tip, at(0.35, size * 0.6), at(0, size * 1.1), at(-0.35, size * 0.6)], solid); break;
      case 'diamond_outline': node = rc.polygon([tip, at(0.35, size * 0.6), at(0, size * 1.1), at(-0.35, size * 0.6)], outline); break;
      default: node = rc.linearPath([at(0.45, size), tip, at(-0.45, size)], outline);
    }
    g.appendChild(node);
  }

  function freedrawPath(points) {
    if (points.length < 2) {
      const [x, y] = points[0] || [0, 0];
      return `M ${x} ${y} l 0.01 0`;
    }
    let d = `M ${points[0][0]} ${points[0][1]}`;
    for (let i = 1; i < points.length - 1; i++) {
      const [x0, y0] = points[i];
      const [x1, y1] = points[i + 1];
      d += ` Q ${x0} ${y0} ${(x0 + x1) / 2} ${(y0 + y1) / 2}`;
    }
    const last = points[points.length - 1];
    return `${d} L ${last[0]} ${last[1]}`;
  }

  function drawText(g, e) {
    const size = e.fontSize || 20;
    const lineHeight = e.lineHeight || 1.25;
    const anchor = e.textAlign === 'center' ? 'middle' : e.textAlign === 'right' ? 'end' : 'start';
    const x = anchor === 'middle' ? e.width / 2 : anchor === 'end' ? e.width : 0;
    const lines = String(e.text || '').split('\n');
    const text = el('text', {
      'font-family': FONTS[e.fontFamily] || FONTS[5],
      'font-size': size,
      fill: e.strokeColor || '#1e1e1e',
      'text-anchor': anchor,
      'dominant-baseline': 'alphabetic',
      direction: 'ltr',
    }, g);
    lines.forEach((line, i) => {
      const span = el('tspan', { x, y: (i + 0.8) * size * lineHeight - (lineHeight - 1) * size * 0.5 }, text);
      span.textContent = line || ' ';
    });
  }

  function render(scene) {
    if (!scene || !Array.isArray(scene.elements)) throw new Error('это не сцена Excalidraw');
    const elements = scene.elements.filter((e) => !e.isDeleted);
    const files = scene.files || {};
    const pad = 16;
    const b = bounds(elements);
    const width = b.maxX - b.minX + pad * 2;
    const height = b.maxY - b.minY + pad * 2;
    const svg = el('svg', {
      xmlns: NS,
      class: 'excalidraw-svg',
      viewBox: `${b.minX - pad} ${b.minY - pad} ${width} ${height}`,
      width: Math.round(width),
      height: Math.round(height),
    });
    const background = scene.appState && scene.appState.viewBackgroundColor;
    if (background && background !== 'transparent') {
      el('rect', { x: b.minX - pad, y: b.minY - pad, width, height, fill: background }, svg);
    }
    const rc = rough.svg(svg);

    for (const e of elements) {
      const angle = ((e.angle || 0) * 180) / Math.PI;
      const g = el('g', {
        transform: `translate(${e.x} ${e.y}) rotate(${angle} ${e.width / 2} ${e.height / 2})`,
        opacity: e.opacity === undefined ? undefined : e.opacity / 100,
      }, svg);
      const o = options(e);
      try {
        switch (e.type) {
          case 'rectangle': {
            const r = cornerRadius(e);
            const w = e.width; const h = e.height;
            g.appendChild(r ? rc.path(`M ${r} 0 L ${w - r} 0 Q ${w} 0, ${w} ${r} L ${w} ${h - r} Q ${w} ${h}, ${w - r} ${h} L ${r} ${h} Q 0 ${h}, 0 ${h - r} L 0 ${r} Q 0 0, ${r} 0`, o)
              : rc.rectangle(0, 0, w, h, o));
            break;
          }
          case 'ellipse': g.appendChild(rc.ellipse(e.width / 2, e.height / 2, e.width, e.height, o)); break;
          case 'diamond': {
            const w = e.width; const h = e.height;
            g.appendChild(rc.polygon([[w / 2, 0], [w, h / 2], [w / 2, h], [0, h / 2]], o));
            break;
          }
          case 'line': case 'arrow': {
            const pts = (e.points || []).map(([x, y]) => [x, y]);
            if (pts.length < 2) break;
            const closed = e.type === 'line' && pts.length > 2 && Math.hypot(pts[0][0] - pts[pts.length - 1][0], pts[0][1] - pts[pts.length - 1][1]) < 1;
            const curved = e.roundness && !e.elbowed && pts.length > 2;
            if (closed && o.fill) g.appendChild(rc.polygon(pts, o));
            else g.appendChild(curved ? rc.curve(pts, { ...o, fill: undefined }) : rc.linearPath(pts, { ...o, fill: undefined }));
            if (e.type === 'arrow') {
              const end = e.endArrowhead === undefined ? 'arrow' : e.endArrowhead;
              arrowhead(rc, g, end, pts[pts.length - 1], pts[pts.length - 2], e);
              arrowhead(rc, g, e.startArrowhead, pts[0], pts[1], e);
            }
            break;
          }
          case 'freedraw': {
            el('path', {
              d: freedrawPath(e.points || []),
              fill: 'none',
              stroke: e.strokeColor || '#1e1e1e',
              'stroke-width': (e.strokeWidth || 1) * 1.6,
              'stroke-linecap': 'round',
              'stroke-linejoin': 'round',
            }, g);
            break;
          }
          case 'text': drawText(g, e); break;
          case 'image': {
            const file = files[e.fileId];
            if (file && file.dataURL) el('image', { href: file.dataURL, width: e.width, height: e.height, preserveAspectRatio: 'none' }, g);
            else g.appendChild(rc.rectangle(0, 0, e.width, e.height, { ...o, strokeLineDash: [6, 6] }));
            break;
          }
          case 'frame': case 'magicframe': {
            el('rect', { width: e.width, height: e.height, rx: 8, fill: 'none', stroke: '#bbb', 'stroke-width': 1 }, g);
            if (e.name) {
              const t = el('text', { x: 0, y: -6, 'font-size': 14, fill: '#888', 'font-family': FONTS[2] }, g);
              t.textContent = e.name;
            }
            break;
          }
          case 'embeddable': case 'iframe': {
            g.appendChild(rc.rectangle(0, 0, e.width, e.height, o));
            if (e.link) {
              const t = el('text', { x: 8, y: 22, 'font-size': 14, fill: o.stroke, 'font-family': FONTS[2] }, g);
              t.textContent = e.link;
            }
            break;
          }
          default: break;
        }
      } catch (err) { /* one broken element must not hide the rest */ }
    }
    return svg;
  }

  window.ArtelExcalidraw = { render };
})();
