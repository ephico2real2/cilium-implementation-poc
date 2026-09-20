/* bgp-fabric dashboard — plain JS, Cytoscape vendored. */
(function () {
  const ui = globalThis.bgpUI;
  const params = new URLSearchParams(location.search);
  let selected = params.get("router") || "spine";
  let selectedWhy = params.get("router") ? "url" : "default";
  let snap = null;
  let cy = null;
  let focused = "";
  let backoff = 500;
  let wsAttempts = 0;
  let lastEventId = 0;
  let eventsPaused = false;
  const seenEvent = {};
  const eventStore = [];
  const pausedBuffer = [];
  const EVENT_CAP = 500;
  const shotHover = params.get("hover") || "";
  const shotTab = params.get("tab") || "";

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
      focus: css("--focus"),
      picked: css("--picked"),
      hover: css("--hover-fill"),
    };
  }

  function applyReady() {
    document.title = "bgp-fabric — live";
    document.body.dataset.ready = "1";
  }

  function graphMetrics() {
    const g = $("graph");
    const w = g.clientWidth || 1200;
    const h = g.clientHeight || 400;
    const k = Math.min(w / 1200, h / 620, 1);
    return {
      w: w,
      h: h,
      fontSize: Math.max(11, Math.round(12 * Math.max(k, 0.85))),
      padding: Math.max(6, Math.round(8 * Math.max(k, 0.75))),
    };
  }

  function renderHeader() {
    if (!snap) {
      $("poll").textContent = "waiting for the first poll";
      $("reach").textContent = "waiting for the first poll";
      $("sess").textContent = "waiting for the first poll";
      return;
    }
    $("poll").textContent = "poll " + (snap.poll || "—");
    const missing = (snap.routers || []).filter((r) => !r.reachable);
    if (!snap.routerCount) {
      $("reach").textContent = "waiting for the first poll";
    } else if (missing.length) {
      const bits = missing.map((r) => {
        const when = r.lastSeen ? ui.relativeTime(r.lastSeen) : "never";
        return "cannot reach " + r.name + " — last seen " + when;
      });
      $("reach").textContent = "routers " + snap.reachable + "/" + snap.routerCount + " · " + bits.join("; ");
    } else {
      $("reach").textContent = "routers " + snap.reachable + "/" + snap.routerCount;
    }
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
    const r = (snap.routers || []).find((x) => x.name === selected);
    if (r && !r.reachable) return "stale";
    let worst = "";
    for (const e of snap.edges || []) {
      if (e.source !== selected && e.target !== selected) continue;
      if (!worst || rankState(e.state) > rankState(worst)) worst = e.state;
    }
    if (worst) return worst;
    if (r) return r.reachable ? "established" : "down";
    return "down";
  }

  function whyText() {
    if (selectedWhy === "url") return "opened with ?router=" + selected + " — click another node, or Tab to it and press Enter";
    if (selectedWhy === "click") return selected + " selected by click";
    if (selectedWhy === "keyboard") return selected + " selected from the keyboard";
    return selected + " is selected so there is a RIB to read — click a node, or Tab to it and press Enter";
  }

  function selectedRouter() {
    return (snap && snap.routers || []).find((x) => x.name === selected) || null;
  }

  function ribRows() {
    const tb = $("rib");
    tb.replaceChildren();
    $("rib-name").textContent = selected;
    $("rib-dot").className = "dot " + selectedState();
    $("rib-why").textContent = whyText();
    const pane = $("rib-pane");
    if (!snap) {
      pane.classList.remove("stale");
      $("rib-status").textContent = "waiting for the first poll";
      return;
    }
    const router = selectedRouter();
    const node = (snap.nodes || []).find((n) => n.id === selected);
    const unreachable = !!(router && !router.reachable);
    pane.classList.toggle("stale", unreachable);
    if (unreachable) {
      const when = router.lastSeen ? ui.relativeTime(router.lastSeen) : "never";
      $("rib-status").textContent = "cannot reach " + selected + " — last seen " + when + ". Rows are last-known, not live.";
    } else {
      $("rib-status").textContent = "";
    }
    let rows = snap.routes || [];
    if (node && node.kind === "external") {
      rows = rows.filter((r) => r.peerId === selected);
    } else {
      rows = rows.filter((r) => r.router === selected);
    }
    const groups = ui.groupECMP(rows);
    if (!groups.length) {
      const tr = document.createElement("tr");
      const td = document.createElement("td");
      td.colSpan = 5;
      td.textContent = unreachable
        ? "no last-known routes for " + selected
        : selected + " has no routes in this snapshot";
      tr.appendChild(td);
      tb.appendChild(tr);
      return;
    }
    for (const g of groups) {
      g.paths.forEach((r, i) => {
        const tr = document.createElement("tr");
        if (i > 0) tr.className = "path";
        tr.innerHTML =
          "<td class=\"best\">" + (r.bestpath ? "*" : "") + "</td>" +
          "<td class=\"prefix\">" + (i === 0 ? ui.esc(g.prefix) : "") + "</td>" +
          "<td class=\"nexthop\">" + ui.esc(r.nexthop || "") + "</td>" +
          "<td>" + ui.esc(r.path || "") + "</td>" +
          "<td>" + ui.esc(r.peerId || "") + "</td>";
        tb.appendChild(tr);
      });
    }
    if (cy) markPicked();
    renderEvents();
  }

  function setHover(edge) {
    const card = $("hover-card");
    if (!edge) {
      card.hidden = true;
      card.textContent = "";
      return;
    }
    const text = ui.edgeCardText(edge);
    if (!text) {
      card.hidden = true;
      card.textContent = "";
      return;
    }
    card.textContent = text;
    card.hidden = false;
  }

  function edgeData(e) {
    return {
      aRouter: e.aRouter, bRouter: e.bRouter,
      aPeer: e.aPeer, bPeer: e.bPeer,
      aState: e.aState, bState: e.bState,
      aUptime: e.aUptime, bUptime: e.bUptime,
      aPfxRcd: e.aPfxRcd, bPfxRcd: e.bPfxRcd,
      aPfxSnt: e.aPfxSnt, bPfxSnt: e.bPfxSnt,
    };
  }

  function markPicked() {
    if (!cy) return;
    cy.nodes().removeClass("picked");
    const n = cy.getElementById(selected);
    if (n && n.nonempty && n.nonempty()) n.addClass("picked");
  }

  function markFocused(id) {
    focused = id || "";
    if (!cy) return;
    cy.nodes().removeClass("focused");
    if (!focused) return;
    const n = cy.getElementById(focused);
    if (n && n.nonempty && n.nonempty()) n.addClass("focused");
  }

  function selectRouter(id, why) {
    selected = id;
    selectedWhy = why;
    const url = new URL(location.href);
    url.searchParams.set("router", id);
    history.replaceState({}, "", url);
    ribRows();
    markPicked();
  }

  function rebuildNodeKeys() {
    const list = $("node-keys");
    list.replaceChildren();
    for (const n of (snap && snap.nodes) || []) {
      const li = document.createElement("li");
      const btn = document.createElement("button");
      btn.type = "button";
      btn.textContent = n.id;
      btn.dataset.node = n.id;
      btn.addEventListener("focus", () => markFocused(n.id));
      btn.addEventListener("click", () => selectRouter(n.id, "keyboard"));
      li.appendChild(btn);
      list.appendChild(li);
    }
  }

  function renderGraph() {
    const empty = $("graph-empty");
    if (!snap) {
      empty.hidden = false;
      empty.textContent = "waiting for the first poll";
      return;
    }
    if (typeof cytoscape === "undefined") {
      empty.hidden = false;
      empty.textContent = "graph library failed to load";
      return;
    }
    empty.hidden = true;
    const c = colours();
    const m = graphMetrics();
    const laid = ui.layoutGraph({
      nodes: snap.nodes || [],
      sessions: snap.sessions || [],
      width: m.w,
      height: m.h,
      fontSize: m.fontSize,
      padding: m.padding,
    });
    const elements = [];
    for (const n of snap.nodes || []) {
      const p = laid.pos[n.id] || { x: m.w / 2, y: m.h / 2 };
      elements.push({ data: { id: n.id, label: n.label, kind: n.kind }, position: p });
    }
    for (const e of snap.edges || []) {
      elements.push({
        data: Object.assign({
          id: e.id,
          source: e.source,
          target: e.target,
          state: e.state,
        }, edgeData(e)),
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
          "font-size": m.fontSize,
          "font-family": "ui-sans-serif, system-ui, sans-serif",
          color: c.fg,
          "background-color": c.panel,
          "border-width": 2,
          "border-color": c.fg,
          width: "label",
          height: "label",
          padding: m.padding,
          shape: "round-rectangle",
        },
      },
      {
        selector: "node[kind = \"external\"]",
        style: { shape: "ellipse", "border-style": "dashed" },
      },
      {
        selector: "node.hover",
        style: { "background-color": c.hover, "border-width": 3 },
      },
      {
        selector: "node.picked",
        style: {
          "border-color": c.focus,
          "border-width": 4,
          "background-color": c.hover,
          "overlay-opacity": 0.16,
          "overlay-color": c.focus,
          "overlay-padding": 6,
        },
      },
      {
        selector: "node.focused",
        style: {
          "border-color": c.focus,
          "border-width": 3,
          "overlay-opacity": 0.18,
          "overlay-color": c.focus,
          "overlay-padding": 5,
        },
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
      window.__cy = cy;
      cy.on("tap", "node", (ev) => selectRouter(ev.target.id(), "click"));
      cy.on("mouseover", "node", (ev) => {
        ev.target.addClass("hover");
        $("graph").style.cursor = "pointer";
      });
      cy.on("mouseout", "node", (ev) => {
        ev.target.removeClass("hover");
        $("graph").style.cursor = "";
      });
      cy.on("mouseover", "edge", (ev) => setHover(ev.target.data()));
      cy.on("mouseout", "edge", () => { if (!shotHover) setHover(null); });
      // Label-sized nodes have no resolved width on the instance's first
      // draw (measured 2026-09-20: pstyle("width").pfValue empty, visible()
      // false, one node painted — 12,158 px versus 79,955 after any second
      // render) until a style update; the cy.json() path below applies one,
      // the constructor does not. Without this the pane shows a single node
      // until the first WebSocket state arrives.
      cy.style().update();
    } else {
      cy.json({ elements: elements, style: style });
      cy.layout({ name: "preset" }).run();
    }
    cy.zoom(1);
    cy.pan({ x: 0, y: 0 });
    // Layout used an estimate of label width. After style().update() the
    // painted box is known — pull any node that still sits past the pane
    // (375 px / leaf2 was the measured case) back inside.
    const paneW = $("graph").clientWidth || m.w;
    const paneH = $("graph").clientHeight || m.h;
    const inset = 16;
    cy.nodes().forEach((n) => {
      const bb = n.boundingBox({ includeLabels: true, includeOverlays: false });
      let x = n.position("x");
      let y = n.position("y");
      const hw = bb.w / 2, hh = bb.h / 2;
      if (x - hw < inset) x = inset + hw;
      if (x + hw > paneW - inset) x = paneW - inset - hw;
      if (y - hh < inset) y = inset + hh;
      if (y + hh > paneH - inset) y = paneH - inset - hh;
      n.position({ x: x, y: y });
    });
    markPicked();
    if (focused) markFocused(focused);
    rebuildNodeKeys();
    if (shotHover) {
      const e = (snap.edges || []).find((x) => x.id === shotHover) || (snap.edges || [])[0];
      if (e) setHover(Object.assign({ id: e.id }, edgeData(e)));
    }
    writeMeasure(laid);
  }

  function writeMeasure(laid) {
    if (!cy) return;
    let painted = 0;
    const boxes = {};
    cy.nodes().forEach((n) => {
      const bb = n.renderedBoundingBox();
      boxes[n.id()] = { x1: bb.x1, y1: bb.y1, x2: bb.x2, y2: bb.y2, w: bb.w, h: bb.h };
      if (n.visible()) painted += bb.w * bb.h;
    });
    const overlaps = [];
    const ids = Object.keys(boxes);
    for (let i = 0; i < ids.length; i++) {
      for (let j = i + 1; j < ids.length; j++) {
        const a = boxes[ids[i]], b = boxes[ids[j]];
        const iw = Math.min(a.x2, b.x2) - Math.max(a.x1, b.x1);
        const ih = Math.min(a.y2, b.y2) - Math.max(a.y1, b.y1);
        if (iw > 0 && ih > 0) overlaps.push({ a: ids[i], b: ids[j], w: +iw.toFixed(1), h: +ih.toFixed(1) });
      }
    }
    document.body.dataset.measure = JSON.stringify({
      painted: Math.round(painted),
      nodeCount: ids.length,
      visible: cy.nodes().filter((n) => n.visible()).length,
      pane: graphMetrics(),
      layoutOverlaps: laid ? laid.overlaps.length : 0,
      paintedOverlaps: overlaps,
    });
  }

  function eventItem(ev) {
    const li = document.createElement("li");
    const dot = document.createElement("i");
    dot.className = "dot " + (ev.kind || "session");
    const ts = document.createElement("span");
    ts.className = "ts";
    ts.dataset.ts = ev.ts || "";
    ts.textContent = ui.relativeTime(ev.ts);
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
    return li;
  }

  function currentFilter() {
    return {
      kind: $("ev-kind").value,
      router: $("ev-selected").checked ? selected : "",
    };
  }

  function renderEvents() {
    const list = $("events");
    list.replaceChildren();
    const filter = currentFilter();
    for (const ev of eventStore) {
      if (!ui.eventMatches(ev, filter)) continue;
      list.appendChild(eventItem(ev));
    }
  }

  function pruneSeen() {
    const keep = {};
    for (const ev of eventStore) {
      if (ev.id) keep[ev.id] = true;
    }
    for (const ev of pausedBuffer) {
      if (ev.id) keep[ev.id] = true;
    }
    for (const id of Object.keys(seenEvent)) {
      if (!keep[id]) delete seenEvent[id];
    }
  }

  function trimEvents() {
    while (eventStore.length > EVENT_CAP) eventStore.pop();
    pruneSeen();
  }

  function updatePausedLabel() {
    const el = $("ev-paused");
    if (!eventsPaused) {
      el.hidden = true;
      el.textContent = "paused, 0 new";
      $("ev-pause").textContent = "Pause";
      return;
    }
    el.hidden = false;
    el.textContent = "paused, " + pausedBuffer.length + " new";
    $("ev-pause").textContent = "Resume";
  }

  function ingestEvent(ev) {
    if (!ev) return;
    if (ev.id && seenEvent[ev.id]) return;
    if (ev.id) {
      seenEvent[ev.id] = true;
      lastEventId = Math.max(lastEventId, ev.id);
    }
    if (eventsPaused) {
      pausedBuffer.push(ev);
      updatePausedLabel();
      return;
    }
    eventStore.unshift(ev);
    trimEvents();
    renderEvents();
  }

  function fetchEventsSince(id) {
    return fetch("/api/events?since=" + encodeURIComponent(id)).then((r) => {
      if (!r.ok) throw new Error("events");
      return r.json();
    }).then((events) => {
      window.__gapFill = { since: id, count: (events || []).length };
      for (const ev of events || []) ingestEvent(ev);
    }).catch(() => {});
  }

  function applyState(msg) {
    snap = msg;
    renderHeader();
    renderGraph();
    ribRows();
    applyReady();
  }

  function connect() {
    const proto = location.protocol === "https:" ? "wss" : "ws";
    const ws = new WebSocket(proto + "://" + location.host + "/ws");
    window.__ws = ws;
    $("wsdot").className = "dot transitional";
    $("wslabel").textContent = wsAttempts
      ? "WebSocket retrying (" + wsAttempts + ")"
      : "connecting";
    ws.onopen = function () {
      const wasRetry = wsAttempts > 0;
      backoff = 500;
      wsAttempts = 0;
      $("wsdot").className = "dot up";
      $("wslabel").textContent = "live";
      if (wasRetry || lastEventId > 0) fetchEventsSince(lastEventId);
    };
    ws.onclose = function () {
      wsAttempts += 1;
      $("wsdot").className = "dot down";
      $("wslabel").textContent = "WebSocket retrying (" + wsAttempts + ")";
      if (window.__holdReconnect) return;
      setTimeout(connect, backoff);
      backoff = Math.min(backoff * 2, 8000);
    };
    ws.onerror = function () { ws.close(); };
    ws.onmessage = function (e) {
      let msg;
      try { msg = JSON.parse(e.data); } catch (err) { return; }
      if (msg.type === "state") applyState(msg);
      else if (msg.type === "event") ingestEvent(msg);
    };
  }

  function setTab(name) {
    const tab = name === "events" ? "events" : "rib";
    document.body.dataset.tab = tab;
    $("tab-rib").setAttribute("aria-selected", tab === "rib" ? "true" : "false");
    $("tab-events").setAttribute("aria-selected", tab === "events" ? "true" : "false");
  }

  function boot() {
    $("legend-toggle").addEventListener("click", () => {
      const bar = document.querySelector(".legend-bar");
      const open = !bar.classList.contains("open");
      bar.classList.toggle("open", open);
      $("legend").hidden = !open && matchMedia("(max-width: 700px)").matches;
      $("legend-toggle").setAttribute("aria-expanded", open ? "true" : "false");
    });
    const wide = matchMedia("(min-width: 701px)");
    function syncLegend() {
      $("legend").hidden = !wide.matches && !document.querySelector(".legend-bar").classList.contains("open");
    }
    wide.addEventListener("change", syncLegend);
    syncLegend();

    $("ev-kind").addEventListener("change", renderEvents);
    $("ev-selected").addEventListener("change", renderEvents);
    $("ev-pause").addEventListener("click", () => {
      eventsPaused = !eventsPaused;
      if (!eventsPaused) {
        for (const ev of pausedBuffer) eventStore.unshift(ev);
        pausedBuffer.length = 0;
        trimEvents();
        renderEvents();
      }
      updatePausedLabel();
    });
    $("tab-rib").addEventListener("click", () => setTab("rib"));
    $("tab-events").addEventListener("click", () => setTab("events"));
    if (shotTab) setTab(shotTab);
    window.__ingestEvent = ingestEvent;
    window.__connect = connect;

    setInterval(() => {
      document.querySelectorAll("[data-ts]").forEach((el) => {
        el.textContent = ui.relativeTime(el.dataset.ts);
      });
      if (snap) renderHeader();
      const router = selectedRouter();
      if (router && !router.reachable) ribRows();
    }, 1000);

    Promise.all([
      fetch("/api/state").then((r) => { if (!r.ok) throw new Error("state"); return r.json(); }),
      fetch("/api/events?since=0").then((r) => { if (!r.ok) throw new Error("events"); return r.json(); }),
    ]).then(([state, events]) => {
      applyState(state);
      for (const ev of events || []) ingestEvent(ev);
      connect();
    }).catch(() => {
      renderHeader();
      connect();
    });
  }

  boot();
  window.addEventListener("resize", () => { if (cy) { cy.resize(); renderGraph(); } });
})();
