"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const ui = require("./ui.js");

test("esc encodes ampersand, angles, quotes and apostrophe", () => {
  assert.equal(ui.esc("O'Brien & <x> \"y\""), "O&#39;Brien &amp; &lt;x&gt; &quot;y&quot;");
});

test("relativeTime is 4s ago at a 4 second gap", () => {
  const now = Date.parse("2026-09-20T12:00:10.000Z");
  assert.equal(ui.relativeTime("2026-09-20T12:00:06.000Z", now), "4s ago");
});

test("relativeTime says never when the stamp is missing", () => {
  assert.equal(ui.relativeTime("", 0), "never");
  assert.equal(ui.relativeTime(undefined, 0), "never");
});

test("eventMatches filters by kind and by router", () => {
  const ev = { kind: "session", router: "spine" };
  assert.equal(ui.eventMatches(ev, { kind: "", router: "" }), true);
  assert.equal(ui.eventMatches(ev, { kind: "session", router: "" }), true);
  assert.equal(ui.eventMatches(ev, { kind: "route", router: "" }), false);
  assert.equal(ui.eventMatches(ev, { kind: "", router: "spine" }), true);
  assert.equal(ui.eventMatches(ev, { kind: "", router: "leaf1" }), false);
  assert.equal(ui.eventMatches(ev, { kind: "session", router: "leaf1" }), false);
});

test("groupECMP lists each prefix once and puts the best path first", () => {
  const g = ui.groupECMP([
    { prefix: "10.0.0.0/24", bestpath: false, nexthop: "1.1.1.1" },
    { prefix: "10.0.0.0/24", bestpath: true, nexthop: "2.2.2.2" },
    { prefix: "10.1.0.0/24", bestpath: true, nexthop: "3.3.3.3" },
  ]);
  assert.equal(g.length, 2);
  assert.equal(g[0].prefix, "10.0.0.0/24");
  assert.equal(g[0].paths.length, 2);
  assert.equal(g[0].paths[0].bestpath, true);
  assert.equal(g[0].paths[0].nexthop, "2.2.2.2");
  assert.equal(g[1].prefix, "10.1.0.0/24");
  assert.equal(g[1].paths.length, 1);
});

test("layoutGraph at 375 px does not overlap six externals", () => {
  const six = sixExternals();
  const layout = ui.layoutGraph({
    nodes: routers().concat(six.nodes),
    sessions: six.sessions,
    width: 375,
    height: 280,
    fontSize: 11,
    padding: 6,
  });
  assert.equal(layout.overlaps.length, 0, JSON.stringify(layout.overlaps));
  for (const id of six.nodes.map((n) => n.id)) {
    assert.ok(layout.pos[id], "missing " + id);
    assert.ok(layout.pos[id].x >= 0 && layout.pos[id].x <= 375, id + " x=" + layout.pos[id].x);
  }
});

test("layoutGraph at 1200 px keeps only1 and both from sharing a colliding row", () => {
  const six = sixExternals();
  const layout = ui.layoutGraph({
    nodes: routers().concat(six.nodes),
    sessions: six.sessions,
    width: 1200,
    height: 520,
    fontSize: 12,
    padding: 8,
  });
  assert.equal(layout.overlaps.length, 0, JSON.stringify(layout.overlaps));
  const a = layout.boxes["172.19.0.20"];
  const b = layout.boxes["172.18.0.5"];
  assert.ok(a && b, "expected both nodes");
  const o = ui.overlapPx(a, b);
  assert.equal(o.w, 0);
});

test("edgeCardText shows both sides of a session", () => {
  const text = ui.edgeCardText({
    aRouter: "leaf1", aPeer: "172.19.0.2", aState: "Established",
    aUptime: "00:04:11", aPfxRcd: 2, aPfxSnt: 7,
    bRouter: "eg-poc1", bPeer: "172.19.0.2", bState: "Established",
    bUptime: "00:04:10", bPfxRcd: 4, bPfxSnt: 2,
  });
  assert.match(text, /leaf1 172\.19\.0\.2 Established 00:04:11 rcd 2 snt 7/);
  assert.match(text, /eg-poc1 172\.19\.0\.2 Established/);
});

test("contrastRatio of the state tokens meets 3:1 on both backgrounds", () => {
  const light = { bg: "#f4f1ea", panel: "#fffdf8" };
  const dark = { bg: "#161410", panel: "#1f1b16" };
  const tokens = {
    est: { light: "#2f7d32", dark: "#4ade80" },
    trans: { light: "#a35f00", dark: "#fbbf24" },
    down: { light: "#b42318", dark: "#f87171" },
    stale: { light: "#6b6570", dark: "#a8a29e" },
  };
  for (const name of Object.keys(tokens)) {
    const t = tokens[name];
    for (const surface of [light.bg, light.panel]) {
      assert.ok(ui.contrastRatio(t.light, surface) >= 3, name + " light on " + surface);
    }
    for (const surface of [dark.bg, dark.panel]) {
      assert.ok(ui.contrastRatio(t.dark, surface) >= 3, name + " dark on " + surface);
    }
  }
});

function routers() {
  return [
    { id: "edge", kind: "router", label: "edge\nAS 65000" },
    { id: "spine", kind: "router", label: "spine\nAS 65100" },
    { id: "leaf1", kind: "router", label: "leaf1\nAS 65101" },
    { id: "leaf2", kind: "router", label: "leaf2\nAS 65102" },
  ];
}

function sixExternals() {
  const nodes = [
    { id: "172.19.0.2", kind: "external", label: "eg-poc1 (kube-vip)\n172.19.0.2" },
    { id: "172.19.0.3", kind: "external", label: "eg-poc1 (kube-vip)\n172.19.0.3" },
    { id: "172.19.0.20", kind: "external", label: "eg-poc1 (kube-vip)\n172.19.0.20" },
    { id: "172.18.0.4", kind: "external", label: "eg-poc2 (MetalLB)\n172.18.0.4" },
    { id: "172.18.0.5", kind: "external", label: "eg-poc2 (MetalLB)\n172.18.0.5" },
    { id: "172.18.0.6", kind: "external", label: "eg-poc2 (MetalLB)\n172.18.0.6" },
  ];
  const sessions = [
    { router: "leaf1", peer: "172.19.0.2" },
    { router: "leaf1", peer: "172.19.0.3" },
    { router: "leaf1", peer: "172.19.0.20" },
    { router: "leaf2", peer: "172.18.0.4" },
    { router: "leaf2", peer: "172.18.0.5" },
    { router: "leaf1", peer: "172.18.0.6" },
    { router: "leaf2", peer: "172.18.0.6" },
  ];
  return { nodes: nodes, sessions: sessions };
}
