/* bgp-fabric dashboard — plain JS, Cytoscape vendored. */
(function () {
  const params = new URLSearchParams(location.search);
  let selected = params.get("router") || "spine";
  let snap = null;
  let cy = null;
  let backoff = 500;
  const seenEvent = {};
  const EVENT_CAP = 500;

  const $ = (id) => document.getElementById(id);
  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

  function colours() {
    return {
      fg: css("--fg"),
      muted: css("--muted"),
      panel: css("--panel"),
      est: css("--est"),
      trans: css("--trans"),
      down: css("--down"),
      stale: css("--stale"),
    };
  }

  function applyReady() {
    document.title = "bgp-fabric — live";
    document.body.dataset.ready = "1";
  }

  function renderHeader() {
    if (!snap) return;
    $("poll").textContent = "poll " + (snap.poll || "—");
    $("reach").textContent = "routers " + snap.reachable + "/" + snap.routerCount;
    // the fabric's own sessions and the servers' (dynamic neighbours) apart:
    // a paused kind node is a server session down, never a fabric session
    $("sess").textContent = "fabric sessions " + snap.established + "/" + snap.sessionCount
      + " · server sessions " + (snap.serverEstablished || 0) + "/" + (snap.serverSessions || 0);
  }

  function rankState(s) {
    if (s === "established") return 1;
    if (s === "transitional") return 2;
    if (s === "stale") return 3;
    return 4;
  }

  function selectedState() {
    if (!snap) return "down";
    let worst = "";
    for (const e of snap.edges || []) {
      if (e.source !== selected && e.target !== selected) continue;
      if (!worst || rankState(e.state) > rankState(worst)) worst = e.state;
    }
    if (worst) return worst;
    const r = (snap.routers || []).find((x) => x.name === selected);
    if (r) return r.reachable ? "established" : "down";
    return "down";
  }

  function ribRows() {
    const tb = $("rib");
    tb.replaceChildren();
    $("rib-name").textContent = selected;
    $("rib-dot").className = "dot " + selectedState();
    if (!snap) return;
    const node = (snap.nodes || []).find((n) => n.id === selected);
    let rows = snap.routes || [];
    if (node && node.kind === "external") {
      rows = rows.filter((r) => r.peerId === selected);
    } else {
      rows = rows.filter((r) => r.router === selected);
    }
    rows = rows.slice().sort((a, b) => a.prefix.localeCompare(b.prefix));
    for (const r of rows) {
      const tr = document.createElement("tr");
      tr.innerHTML =
        "<td class=\"best\">" + (r.bestpath ? "*" : "") + "</td>" +
        "<td>" + esc(r.prefix) + "</td>" +
        "<td>" + esc(r.nexthop || "") + "</td>" +
        "<td>" + esc(r.path || "") + "</td>" +
        "<td>" + esc(r.peerId || "") + "</td>";
      tb.appendChild(tr);
    }
  }

  function esc(s) {
    return String(s).replace(/[&<>"]/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;" }[ch]));
  }

  function renderGraph() {
    if (!snap || typeof cytoscape === "undefined") return;
    const c = colours();
    const pos = preset(snap);
    const elements = [];
    for (const n of snap.nodes || []) {
      const p = pos[n.id] || { x: 600, y: 300 };
      elements.push({
        data: { id: n.id, label: n.label, kind: n.kind },
        position: p,
      });
    }
    for (const e of snap.edges || []) {
      elements.push({
        data: {
          id: e.id,
          source: e.source,
          target: e.target,
          state: e.state,
          label: e.state,
        },
      });
    }
    const style = [
      {
        selector: "node",
        style: {
          label: "data(label)",
          "text-wrap": "wrap",
          "text-valign": "center",
          "text-halign": "center",
          "font-size": 12,
          "font-family": "ui-sans-serif, system-ui, sans-serif",
          color: c.fg,
          "background-color": c.panel,
          "border-width": 2,
          "border-color": c.fg,
          width: "label",
          height: "label",
          padding: 8,
          shape: "round-rectangle",
        },
      },
      {
        selector: "node[kind = \"external\"]",
        style: { shape: "ellipse", "font-size": 11, "border-style": "dashed" },
      },
      {
        selector: "edge",
        style: {
          width: 3,
          "curve-style": "bezier",
          "line-color": c.down,
          "target-arrow-color": c.down,
          "source-arrow-color": c.down,
          label: "",
          "font-size": 10,
          color: c.muted,
        },
      },
      { selector: "edge[state = \"established\"]", style: { "line-color": c.est } },
      { selector: "edge[state = \"transitional\"]", style: { "line-color": c.trans } },
      { selector: "edge[state = \"stale\"]", style: { "line-color": c.stale, "line-style": "dashed" } },
      { selector: "edge[state = \"down\"]", style: { "line-color": c.down } },
      { selector: "edge:selected, edge:active", style: { label: "data(label)" } },
    ];
    if (!cy) {
      cy = cytoscape({
        container: $("graph"),
        elements: elements,
        style: style,
        layout: { name: "preset" },
        userZoomingEnabled: false,
        userPanningEnabled: false,
        boxSelectionEnabled: false,
      });
      cy.on("tap", "node", (ev) => {
        selected = ev.target.id();
        ribRows();
      });
      cy.on("mouseover", "edge", (ev) => ev.target.style("label", "data(label)"));
      cy.on("mouseout", "edge", (ev) => ev.target.style("label", ""));
      // Label-sized nodes have no resolved width on the instance's first
      // draw (measured 2026-09-20: pstyle("width").pfValue empty, visible()
      // false, one node painted) until a style update; the cy.json() path
      // below applies one, the constructor does not. Without this the pane
      // shows a single node until the first WebSocket state arrives.
      cy.style().update();
    } else {
      cy.json({ elements: elements, style: style });
      cy.layout({ name: "preset" }).run();
    }
    // The preset is drawn on a 1200×620 canvas. Fitting it into a narrower pane
    // would zoom out and shrink the labels with it (measured 2026-09-20: ~7 px at
    // 780 px wide), so the positions are scaled to the pane and the zoom stays 1.
    cy.zoom(1);
    cy.center();
  }

  function paneScale() {
    const g = $("graph");
    const w = g.clientWidth || 1200;
    const h = g.clientHeight || 620;
    return Math.min(w / 1200, h / 620, 1);
  }

  function preset(s) {
    // routers: edge/spine stay centred; leaves at 240/960 so a 4-wide
    // external row (dx 260: an ellipse sized to its label is ~200 px wide at zoom 1;
    // 4 × 260 = 1040 centred at 600 → 80…1120) fits the 1200-wide canvas.
    const pos = {
      edge: { x: 600, y: 70 },
      spine: { x: 600, y: 220 },
      leaf1: { x: 240, y: 400 },
      leaf2: { x: 960, y: 400 },
    };
    const seenBy = {};
    const externals = [];
    for (const n of s.nodes || []) {
      if (n.kind === "external") {
        externals.push(n);
        seenBy[n.id] = {};
      }
    }
    for (const sess of s.sessions || []) {
      if (seenBy[sess.peer]) seenBy[sess.peer][sess.router] = true;
    }
    externals.sort((a, b) => a.id.localeCompare(b.id, undefined, { numeric: true }));
    const both = [], only1 = [], only2 = [];
    for (const n of externals) {
      const v = seenBy[n.id] || {};
      if (v.leaf1 && v.leaf2) both.push(n);
      else if (v.leaf1) only1.push(n);
      else if (v.leaf2) only2.push(n);
      else both.push(n);
    }
    const place = (list, x0, y, dx) => {
      list.forEach((n, i) => {
        let x = x0;
        if (list.length > 1) x = x0 + i * dx - (dx * (list.length - 1)) / 2;
        pos[n.id] = { x: x, y: y };
      });
    };
    place(only1, 240, 560, 260);
    place(only2, 960, 560, 260);
    place(both, 600, 560, 260);
    const k = paneScale();
    for (const id of Object.keys(pos)) pos[id] = { x: pos[id].x * k, y: pos[id].y * k };
    return pos;
  }

  function prependEvent(ev) {
    if (!ev) return;
    if (ev.id && seenEvent[ev.id]) return;
    if (ev.id) seenEvent[ev.id] = true;
    const li = document.createElement("li");
    const dot = document.createElement("i");
    dot.className = "dot " + (ev.kind || "session");
    const ts = document.createElement("span");
    ts.className = "ts";
    // time only in the pane (the date wraps the row); the full stamp on hover
    ts.textContent = (ev.ts || "").replace(/^.*T/, "").replace(/Z$/, "");
    ts.title = ev.ts || "";
    const kind = document.createElement("span");
    kind.className = "kind";
    kind.textContent = ev.kind || "";
    const router = document.createElement("span");
    router.className = "router";
    router.textContent = ev.router || "";
    const who = document.createElement("span");
    who.className = "who";
    who.textContent = ev.prefix || ev.peer || "";
    const change = document.createElement("span");
    change.className = "change";
    if (ev.from || ev.to) change.textContent = (ev.from || "") + "→" + (ev.to || "");
    li.append(dot, ts, kind, router, who, change);
    $("events").prepend(li);
    const list = $("events");
    while (list.children.length > EVENT_CAP) list.removeChild(list.lastChild);
  }

  function applyState(msg) {
    snap = msg;
    renderHeader();
    renderGraph();
    ribRows();
  }

  function connect() {
    const proto = location.protocol === "https:" ? "wss" : "ws";
    const ws = new WebSocket(proto + "://" + location.host + "/ws");
    $("wsdot").className = "dot transitional";
    $("wslabel").textContent = "connecting";
    ws.onopen = function () {
      backoff = 500;
      $("wsdot").className = "dot up";
      $("wslabel").textContent = "live";
    };
    ws.onclose = function () {
      $("wsdot").className = "dot down";
      $("wslabel").textContent = "retrying";
      setTimeout(connect, backoff);
      backoff = Math.min(backoff * 2, 8000);
    };
    ws.onerror = function () { ws.close(); };
    ws.onmessage = function (e) {
      let msg;
      try { msg = JSON.parse(e.data); } catch (err) { return; }
      if (msg.type === "state") {
        applyState(msg);
      } else if (msg.type === "event") {
        prependEvent(msg);
      }
    };
  }

  function boot() {
    Promise.all([
      fetch("/api/state").then((r) => { if (!r.ok) throw new Error("state"); return r.json(); }),
      fetch("/api/events?since=0").then((r) => { if (!r.ok) throw new Error("events"); return r.json(); }),
    ]).then(([state, events]) => {
      applyState(state);
      for (const ev of events || []) prependEvent(ev);
      applyReady();
      connect();
    }).catch(() => {
      connect();
    });
  }

  boot();
  window.addEventListener("resize", () => { if (cy) { cy.resize(); renderGraph(); } });
})();