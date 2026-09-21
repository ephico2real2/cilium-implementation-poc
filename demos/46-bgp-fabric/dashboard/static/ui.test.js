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
  for (const id of Object.keys(layout.boxes)) {
    const b = layout.boxes[id];
    assert.ok(b.x - b.w / 2 >= -0.5, id + " left " + (b.x - b.w / 2));
    assert.ok(b.x + b.w / 2 <= 375.5, id + " right " + (b.x + b.w / 2));
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

// ---- signal -----------------------------------------------------------

test("sessionHealth treats reaching the keepalive interval as normal", () => {
  // Measured on the fabric: quietMsec sawtooths 0 -> 1000 -> 2000 -> 3000 -> 0
  // with keepalive 3000 and hold 9000, so 3000 is the instant before the next
  // keepalive, not a fault.
  const base = { hasTimers: true, holdMsec: 9000, keepaliveMsec: 3000 };
  for (const quiet of [0, 1000, 2000, 3000]) {
    const h = ui.sessionHealth(Object.assign({ quietMsec: quiet }, base));
    assert.equal(h.kind, "ok", "quiet=" + quiet + " must be ok");
  }
  assert.equal(ui.sessionHealth(Object.assign({ quietMsec: 4000 }, base)).kind, "late");
  assert.equal(ui.sessionHealth(Object.assign({ quietMsec: 6000 }, base)).kind, "critical");
  assert.equal(ui.sessionHealth(Object.assign({ quietMsec: 8000 }, base)).kind, "critical");
});

test("sessionHealth reports unknown rather than a heartbeat of zero", () => {
  assert.equal(ui.sessionHealth({ hasTimers: false, quietMsec: 0 }).kind, "unknown");
  assert.equal(ui.sessionHealth({ hasTimers: false }).fraction, null);
  assert.equal(ui.sessionHealth(null).kind, "unknown");
  // hasTimers true but no hold time is still no measurement
  assert.equal(ui.sessionHealth({ hasTimers: true, holdMsec: 0, quietMsec: 5 }).kind, "unknown");
});

test("sessionTraffic reports nothing on a tick with no measured delta", () => {
  const t = ui.sessionTraffic({ hasDelta: false, dRcvd: 9, dSent: 9 });
  assert.equal(t.known, false);
  assert.equal(t.messages, 0);
  assert.equal(t.prefixes, 0);
});

test("a withdrawal is volume, not a negative width", () => {
  // pfxRcd 2 -> 1 with no session reset: the delta is -1. The page needs the
  // magnitude to draw and the sign to say which way.
  const t = ui.sessionTraffic({ hasDelta: true, dRcvd: 2, dSent: 1, dPfxRcd: -1, dPfxSnt: 0 });
  assert.equal(t.prefixes, 1);
  assert.equal(t.withdrew, true);
  assert.equal(t.messages, 3);
  const add = ui.sessionTraffic({ hasDelta: true, dRcvd: 2, dSent: 1, dPfxRcd: 3, dPfxSnt: 0 });
  assert.equal(add.withdrew, false);
  assert.equal(add.prefixes, 3);
});

test("routerSignal reads accepting from FRR, not from a session count", () => {
  const leaf = { name: "leaf1", reachable: true, dynamicPeers: 2, hasDelta: true, dTableVersion: 0 };
  const spine = { name: "spine", reachable: true, dynamicPeers: 0, hasDelta: true, dTableVersion: 0 };
  const sessions = [
    { router: "leaf1", hasDelta: true, dRcvd: 1, dSent: 0, hasTimers: true, holdMsec: 9000, keepaliveMsec: 3000, quietMsec: 1000 },
    { router: "spine", hasDelta: true, dRcvd: 1, dSent: 1, hasTimers: true, holdMsec: 9000, keepaliveMsec: 3000, quietMsec: 0 },
  ];
  assert.equal(ui.routerSignal(leaf, sessions).accepting, true);
  assert.equal(ui.routerSignal(spine, sessions).accepting, false);
  // a spine with three healthy sessions is still not "accepting": no cluster peers it
  assert.equal(ui.routerSignal(spine, sessions).beat, true);
});

test("an unreachable router has no beat and claims nothing", () => {
  const r = { name: "leaf2", reachable: false, dynamicPeers: 2 };
  const sig = ui.routerSignal(r, [{ router: "leaf2", hasDelta: true, dRcvd: 5 }]);
  assert.equal(sig.beat, false);
  assert.equal(sig.known, false);
  assert.equal(sig.worst, "unknown");
});

test("a stale session contributes no beat", () => {
  const r = { name: "leaf1", reachable: true, dynamicPeers: 0 };
  const sig = ui.routerSignal(r, [{ router: "leaf1", stale: true, hasDelta: true, dRcvd: 9 }]);
  assert.equal(sig.beat, false);
});

test("routerSignal takes the worst session's health", () => {
  const r = { name: "leaf1", reachable: true, dynamicPeers: 1 };
  const sessions = [
    { router: "leaf1", hasTimers: true, holdMsec: 9000, keepaliveMsec: 3000, quietMsec: 0 },
    { router: "leaf1", hasTimers: true, holdMsec: 9000, keepaliveMsec: 3000, quietMsec: 7000 },
  ];
  assert.equal(ui.routerSignal(r, sessions).worst, "critical");
});

test("flowDirection points at the router that learned the prefix", () => {
  const edges = [{ id: "e1", source: "leaf1", target: "n-172.20.0.3", aRouter: "leaf1", aPeer: "172.20.0.3", bRouter: "", bPeer: "" }];
  // leaf1 learned 10.198.0.10/32 from 172.20.0.3 — the arrow runs toward leaf1
  const ev = { kind: "route", router: "leaf1", prefix: "10.198.0.10/32", advertisedBy: "172.20.0.3" };
  const f = ui.flowDirection(ev, [{ id: "e1", aRouter: "leaf1", aPeer: "", bRouter: "", bPeer: "172.20.0.3", source: "n", target: "leaf1" }]);
  assert.ok(f, "expected a direction");
  assert.equal(f.to, "leaf1");
  assert.equal(f.prefix, "10.198.0.10/32");
  void edges;
});

test("a locally originated route produces no flow", () => {
  // advertisedBy is empty for the router's own loopback
  const ev = { kind: "route", router: "leaf2", prefix: "10.200.255.12/32", advertisedBy: "" };
  assert.equal(ui.flowDirection(ev, [{ id: "e1", aRouter: "leaf2", bPeer: "10.200.1.11" }]), null);
  // and a session event is not a flow at all
  assert.equal(ui.flowDirection({ kind: "session", router: "leaf2", advertisedBy: "x" }, []), null);
});

test("freshness is driven by the server's own age, not the browser clock", () => {
  assert.equal(ui.freshness(1249, 2000).state, "live");
  assert.equal(ui.freshness(4000, 2000).state, "live");
  assert.equal(ui.freshness(6000, 2000).state, "lagging");
  assert.equal(ui.freshness(30000, 2000).state, "stale");
  assert.equal(ui.freshness(null, 2000).state, "unknown");
  assert.equal(ui.freshness(undefined, 2000).state, "unknown");
});

test("the RIB says 'self' rather than FRR's (unspec) sentinel", () => {
  assert.equal(ui.fromLabel("(unspec)"), "self");
  assert.equal(ui.fromLabel(""), "self");
  assert.equal(ui.fromLabel(null), "self");
  assert.equal(ui.fromLabel("172.20.0.4"), "172.20.0.4");
});
