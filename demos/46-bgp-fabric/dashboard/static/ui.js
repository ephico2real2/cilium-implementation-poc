/* Pure helpers for the bgp-fabric dashboard. Loaded in the browser as
   globalThis.bgpUI; required by node --test as a CommonJS module. */
(function (root) {
  function esc(s) {
    return String(s).replace(/[&<>"']/g, (ch) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      "\"": "&quot;",
      "'": "&#39;",
    })[ch]);
  }

  function relativeTime(iso, now) {
    if (!iso) return "never";
    const t = Date.parse(iso);
    if (!Number.isFinite(t)) return String(iso);
    const clock = now == null ? Date.now() : (typeof now === "number" ? now : Date.parse(now));
    if (!Number.isFinite(clock)) return String(iso);
    let s = Math.round((clock - t) / 1000);
    if (s < 0) s = 0;
    if (s < 60) return s + "s ago";
    const m = Math.round(s / 60);
    if (m < 60) return m + "m ago";
    const h = Math.round(m / 60);
    if (h < 48) return h + "h ago";
    return Math.round(h / 24) + "d ago";
  }

  function eventMatches(ev, filter) {
    if (!ev) return false;
    const kind = filter && filter.kind ? filter.kind : "";
    const router = filter && filter.router ? filter.router : "";
    if (kind && ev.kind !== kind) return false;
    if (router && ev.router !== router) return false;
    return true;
  }

  function groupECMP(rows) {
    const groups = [];
    const byPrefix = new Map();
    const sorted = (rows || []).slice().sort((a, b) => {
      const p = String(a.prefix || "").localeCompare(String(b.prefix || ""));
      if (p) return p;
      return (b.bestpath ? 1 : 0) - (a.bestpath ? 1 : 0);
    });
    for (const r of sorted) {
      const prefix = r.prefix || "";
      let g = byPrefix.get(prefix);
      if (!g) {
        g = { prefix: prefix, paths: [] };
        byPrefix.set(prefix, g);
        groups.push(g);
      }
      g.paths.push(r);
    }
    return groups;
  }

  // Label-sized node estimate. 0.62em is slightly generous vs the measured
  // 122 px ellipse for "eg-poc1 (kube-vip)\n172.19.0.2" at 12 px, so the
  // grid spaces nodes a bit wider than they paint and they do not collide.
  function nodeBox(n, fontSize, padding) {
    const lines = String((n && n.label) || (n && n.id) || "").split("\n");
    const cols = Math.max.apply(null, lines.map((l) => l.length).concat([1]));
    return {
      w: cols * fontSize * 0.62 + padding * 2,
      h: lines.length * fontSize * 1.25 + padding * 2,
    };
  }

  function overlapPx(a, b) {
    const ax1 = a.x - a.w / 2, ax2 = a.x + a.w / 2;
    const ay1 = a.y - a.h / 2, ay2 = a.y + a.h / 2;
    const bx1 = b.x - b.w / 2, bx2 = b.x + b.w / 2;
    const by1 = b.y - b.h / 2, by2 = b.y + b.h / 2;
    const iw = Math.min(ax2, bx2) - Math.max(ax1, bx1);
    const ih = Math.min(ay2, by2) - Math.max(ay1, by1);
    if (iw <= 0 || ih <= 0) return { w: 0, h: 0, area: 0 };
    return { w: iw, h: ih, area: iw * ih };
  }

  function classifyExternals(nodes, sessions) {
    const seenBy = {};
    const externals = [];
    for (const n of nodes || []) {
      if (n.kind === "external") {
        externals.push(n);
        seenBy[n.id] = {};
      }
    }
    for (const sess of sessions || []) {
      if (seenBy[sess.peer]) seenBy[sess.peer][sess.router] = true;
    }
    externals.sort((a, b) => String(a.id).localeCompare(String(b.id), undefined, { numeric: true }));
    const only1 = [], only2 = [], both = [];
    for (const n of externals) {
      const v = seenBy[n.id] || {};
      if (v.leaf1 && v.leaf2) both.push(n);
      else if (v.leaf1) only1.push(n);
      else if (v.leaf2) only2.push(n);
      else both.push(n);
    }
    return { only1: only1, only2: only2, both: both, all: only1.concat(both, only2) };
  }

  function wrapItems(items, maxW, gap) {
    const rows = [];
    let row = [];
    let rowW = 0;
    for (const it of items) {
      const add = it.w + (row.length ? gap : 0);
      if (row.length && rowW + add > maxW) {
        rows.push(row);
        row = [it];
        rowW = it.w;
      } else {
        row.push(it);
        rowW += add;
      }
    }
    if (row.length) rows.push(row);
    return rows;
  }

  function placeRows(rows, centerX, startY, gap, minX, maxX) {
    const placed = [];
    let y = startY;
    for (const row of rows) {
      const rowH = Math.max.apply(null, row.map((i) => i.h));
      const total = row.reduce((s, i) => s + i.w, 0) + gap * (row.length - 1);
      let x = centerX - total / 2;
      if (x < minX) x = minX;
      if (x + total > maxX) x = Math.max(minX, maxX - total);
      for (const it of row) {
        placed.push({ id: it.id, x: x + it.w / 2, y: y + rowH / 2, w: it.w, h: it.h });
        x += it.w + gap;
      }
      y += rowH + gap;
    }
    return { placed: placed, endY: y };
  }

  function sized(list, fontSize, padding) {
    return list.map((n) => {
      const b = nodeBox(n, fontSize, padding);
      return { id: n.id, w: b.w, h: b.h, node: n };
    });
  }

  // Positions in pane pixels (zoom stays 1). Externals sit in an ordered
  // grid that wraps on label width, so a 375 px pane does not stack four
  // 122 px ellipses 81 px apart.
  function layoutGraph(opts) {
    const width = Math.max(opts.width || 0, 1);
    const height = Math.max(opts.height || 0, 1);
    const fontSize = opts.fontSize || 12;
    const padding = opts.padding == null ? 8 : opts.padding;
    const gap = opts.gap == null ? 12 : opts.gap;
    const nodes = opts.nodes || [];
    const sessions = opts.sessions || [];
    const boxes = {};
    const routers = { edge: true, spine: true, leaf1: true, leaf2: true };
    const pad = 10;

    boxes.edge = Object.assign({ x: width / 2, y: height * 0.12 }, nodeBox({ label: "edge\nAS 65000" }, fontSize, padding));
    boxes.spine = Object.assign({ x: width / 2, y: height * 0.32 }, nodeBox({ label: "spine\nAS 65100" }, fontSize, padding));
    boxes.leaf1 = Object.assign({ x: width * 0.22, y: height * 0.54 }, nodeBox({ label: "leaf1\nAS 65101" }, fontSize, padding));
    boxes.leaf2 = Object.assign({ x: width * 0.78, y: height * 0.54 }, nodeBox({ label: "leaf2\nAS 65102" }, fontSize, padding));

    for (const n of nodes) {
      if (routers[n.id] && n.label) {
        const b = nodeBox(n, fontSize, padding);
        boxes[n.id].w = b.w;
        boxes[n.id].h = b.h;
      }
    }
    // Keep every router fully inside the pane. At 375 px a leaf centred at
    // 0.78·w sat 40 px past the right edge (ellipse/label wider than the
    // fraction assumed).
    for (const id of ["edge", "spine", "leaf1", "leaf2"]) {
      const b = boxes[id];
      const half = b.w / 2;
      if (b.x - half < pad) b.x = pad + half;
      if (b.x + half > width - pad) b.x = width - pad - half;
    }

    const groups = classifyExternals(nodes, sessions);
    const startY = Math.max(
      boxes.leaf1.y + boxes.leaf1.h / 2,
      boxes.leaf2.y + boxes.leaf2.h / 2
    ) + gap + 4;
    const innerW = width - pad * 2;
    const colW = innerW / 3;
    const allSized = sized(groups.all, fontSize, padding);
    const maxItem = allSized.reduce((m, i) => Math.max(m, i.w), 0);
    let extPlaced = [];

    if (!allSized.length) {
      // no externals
    } else if (width < 700 || maxItem > colW - gap) {
      const rows = wrapItems(allSized, innerW, gap);
      extPlaced = placeRows(rows, width / 2, startY, gap, pad, width - pad).placed;
    } else {
      const cols = [
        { list: sized(groups.only1, fontSize, padding), cx: pad + colW / 2, lo: pad, hi: pad + colW - gap / 2 },
        { list: sized(groups.both, fontSize, padding), cx: width / 2, lo: pad + colW + gap / 2, hi: pad + colW * 2 - gap / 2 },
        { list: sized(groups.only2, fontSize, padding), cx: width - pad - colW / 2, lo: pad + colW * 2 + gap / 2, hi: width - pad },
      ];
      for (const col of cols) {
        if (!col.list.length) continue;
        const rows = wrapItems(col.list, col.hi - col.lo, gap);
        extPlaced = extPlaced.concat(placeRows(rows, col.cx, startY, gap, col.lo, col.hi).placed);
      }
    }
    for (const p of extPlaced) boxes[p.id] = p;

    for (const n of nodes) {
      if (!boxes[n.id]) {
        const b = nodeBox(n, fontSize, padding);
        boxes[n.id] = { x: width / 2, y: height * 0.7, w: b.w, h: b.h };
      }
    }

    let maxBottom = 0;
    for (const id of Object.keys(boxes)) {
      maxBottom = Math.max(maxBottom, boxes[id].y + boxes[id].h / 2);
    }
    if (maxBottom + pad > height) {
      const k = (height - pad) / maxBottom;
      for (const id of Object.keys(boxes)) boxes[id].y *= k;
    }

    const overlaps = [];
    const ids = Object.keys(boxes);
    for (let i = 0; i < ids.length; i++) {
      for (let j = i + 1; j < ids.length; j++) {
        const o = overlapPx(boxes[ids[i]], boxes[ids[j]]);
        if (o.area > 0.5) overlaps.push({ a: ids[i], b: ids[j], w: o.w, h: o.h, area: o.area });
      }
    }
    const pos = {};
    for (const id of Object.keys(boxes)) pos[id] = { x: boxes[id].x, y: boxes[id].y };
    return { pos: pos, boxes: boxes, overlaps: overlaps, fontSize: fontSize, padding: padding };
  }

  function contrastRatio(fgHex, bgHex) {
    function lum(hex) {
      const h = hex.replace("#", "");
      const n = h.length === 3
        ? [h[0] + h[0], h[1] + h[1], h[2] + h[2]]
        : [h.slice(0, 2), h.slice(2, 4), h.slice(4, 6)];
      const rgb = n.map((p) => {
        const c = parseInt(p, 16) / 255;
        return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
      });
      return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
    }
    const a = lum(fgHex), b = lum(bgHex);
    const hi = Math.max(a, b), lo = Math.min(a, b);
    return (hi + 0.05) / (lo + 0.05);
  }

  function edgeCardText(e) {
    if (!e) return "";
    function side(router, peer, state, up, rcd, snt) {
      if (!router && !peer) return "";
      const bits = [router, peer, state, up].filter(Boolean);
      if (rcd != null && rcd !== "") bits.push("rcd " + rcd);
      if (snt != null && snt !== "") bits.push("snt " + snt);
      return bits.join(" ");
    }
    const a = side(e.aRouter, e.aPeer, e.aState, e.aUptime, e.aPfxRcd, e.aPfxSnt);
    const b = side(e.bRouter, e.bPeer, e.bState, e.bUptime, e.bPfxRcd, e.bPfxSnt);
    return [a, b].filter(Boolean).join(" · ");
  }

  const api = {
    esc: esc,
    relativeTime: relativeTime,
    eventMatches: eventMatches,
    groupECMP: groupECMP,
    nodeBox: nodeBox,
    overlapPx: overlapPx,
    classifyExternals: classifyExternals,
    layoutGraph: layoutGraph,
    contrastRatio: contrastRatio,
    edgeCardText: edgeCardText,
  };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  root.bgpUI = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
