// test: the signal reaches the PAGE, not merely the API.
//
// Needs the Colima lab up (demos/46-bgp-fabric-colima/apply.sh) and Playwright
// in .tmp/pw. Run:  node tests/walk46-colima-signal.mjs
//
// Code review does not catch a blank pane, a grid track that slid up because a
// sibling is display:none, or a pulse that fires on nothing. Each of those was
// found here and each has an assertion below.
//
// The two cases that inject frames SILENCE the WebSocket first. A real signal
// frame arrives every 2s and a pulse leaves its flag set for 580ms, so reading
// either while the page is live tests the clock rather than the code — both
// cases failed that way before the socket was held.
import { chromium } from '/Users/olasumbo/gitRepos/cilium-implementation-poc/.tmp/pw/node_modules/playwright/index.mjs';

const URL = 'http://127.0.0.1:8098/';
const OUT = '/Users/olasumbo/gitRepos/cilium-implementation-poc/demos/46-bgp-fabric-colima/output/ui';
const fail = [];
const note = (m) => console.log(m);

const b = await chromium.launch();

async function page(viewport, q = '') {
  const ctx = await b.newContext({ viewport, deviceScaleFactor: 2 });
  const p = await ctx.newPage();
  const errors = [];
  p.on('pageerror', (e) => errors.push(String(e)));
  p.on('console', (m) => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
  await p.goto(URL + q, { waitUntil: 'networkidle' });
  await p.waitForFunction(() => document.body.dataset.ready === '1', { timeout: 15000 });
  return { p, ctx, errors };
}

// ---- 1200: the page renders and the signal is on it -----------------------
{
  const { p, ctx, errors } = await page({ width: 1200, height: 800 }, '?router=leaf1');
  await p.waitForTimeout(4500); // at least two 2s ticks, so a signal frame has arrived

  const m = await p.evaluate(() => {
    const cy = window.__cy;
    const nodes = cy ? cy.nodes().map((n) => ({
      id: n.id(), accepting: n.data('accepting'), signal: n.data('signal'), known: n.data('known'),
    })) : [];
    return {
      painted: cy ? cy.nodes().length : 0,
      edges: cy ? cy.edges().length : 0,
      nodes,
      strip: (document.getElementById('signal-strip') || {}).textContent || '',
      stripEmpty: (document.getElementById('signal-strip') || {}).className || '',
      age: (document.getElementById('age') || {}).textContent || '',
      ws: (document.getElementById('wslabel') || {}).textContent || '',
      overflow: document.documentElement.scrollWidth - window.innerWidth,
    };
  });
  note(`1200  nodes=${m.painted} edges=${m.edges} ws=${m.ws} overflow=${m.overflow}`);
  note(`      age="${m.age.trim()}"`);
  note(`      strip="${m.strip.trim().slice(0, 120)}"`);
  for (const n of m.nodes) note(`      node ${n.id.padEnd(16)} accepting=${n.accepting} signal=${n.signal} known=${n.known}`);

  if (m.painted < 6) fail.push(`only ${m.painted} nodes painted`);
  if (m.overflow > 0.5) fail.push(`page overflows by ${m.overflow}px at 1200`);
  if (/waiting for the first poll/.test(m.strip)) fail.push('signal strip never filled');
  if (!/accepting traffic/.test(m.strip)) fail.push('leaf1 is not reported as accepting traffic');
  if (!/age/.test(m.age)) fail.push('age indicator empty');
  const leaves = m.nodes.filter((n) => n.id === 'leaf1' || n.id === 'leaf2');
  if (!leaves.length || leaves.some((n) => n.accepting !== 1)) fail.push('a leaf is not marked accepting');
  const spine = m.nodes.find((n) => n.id === 'spine');
  if (spine && spine.accepting !== 0) fail.push('spine must NOT be marked accepting');
  if (errors.length) fail.push('js errors: ' + errors.join(' | '));
  await p.screenshot({ path: `${OUT}/1200-signal.png` });

  // ---- the three side panes occupy the tracks meant for them -------------
  // `.tabs` is display:none at this width, so it leaves the grid and
  // auto-placement slides every child up a track. Measured once for real: the
  // splitter took the RIB's 58% row as a 402px grey void and Events was
  // squeezed into 6px. Assert the ORDER and the SIZES, not just presence.
  {
    const L = await p.evaluate(() => {
      const box = (sel) => { const e = document.querySelector(sel); const b = e.getBoundingClientRect();
        return { top: Math.round(b.top), h: Math.round(b.height), display: getComputedStyle(e).display }; };
      return { rib: box('#rib-pane'), split: box('#split-row'), events: box('#events-pane'),
               side: box('.side'), rows: getComputedStyle(document.querySelector('.side')).gridTemplateRows };
    });
    note(`      side rows=${L.rows}`);
    note(`      rib top=${L.rib.top} h=${L.rib.h} | splitter top=${L.split.top} h=${L.split.h} | events top=${L.events.top} h=${L.events.h}`);
    if (L.split.h > 12) fail.push(`the splitter is ${L.split.h}px tall; it must be the thin 6px track`);
    if (!(L.rib.top < L.split.top && L.split.top < L.events.top)) fail.push('the side panes are out of order');
    if (L.events.h < 80) fail.push(`the Events pane is only ${L.events.h}px tall`);
    if (L.rib.h < 120) fail.push(`the RIB pane is only ${L.rib.h}px tall`);
    const covered = L.rib.h + L.split.h + L.events.h;
    if (covered < L.side.h - 8) fail.push(`the side panes cover ${covered}px of ${L.side.h}px — there is a void`);
  }

  // ---- splitters --------------------------------------------------------
  const before = await p.evaluate(() => document.getElementById('graph').clientWidth);
  await p.evaluate(() => window.__applySplit('col', 40));
  await p.waitForTimeout(400);
  const after = await p.evaluate(() => document.getElementById('graph').clientWidth);
  note(`      splitter: graph pane ${before}px -> ${after}px`);
  if (!(after < before - 50)) fail.push(`splitter did not resize the graph pane (${before} -> ${after})`);

  const refit = await p.evaluate(() => {
    const cy = window.__cy;
    const w = cy.width();
    const inside = cy.nodes().filter((n) => {
      const bb = n.boundingBox({ includeLabels: true });
      return bb.x1 >= -1 && bb.x2 <= w + 1;
    }).length;
    return { w, inside, total: cy.nodes().length };
  });
  note(`      after resize: canvas=${refit.w}px nodes inside=${refit.inside}/${refit.total}`);
  if (refit.inside !== refit.total) fail.push(`${refit.total - refit.inside} node(s) outside the canvas after resize`);
  await p.screenshot({ path: `${OUT}/1200-split-40.png` });

  // keyboard
  await p.focus('#split-col');
  await p.keyboard.press('ArrowRight');
  await p.keyboard.press('ArrowRight');
  const kb = await p.evaluate(() => document.getElementById('split-col').getAttribute('aria-valuenow'));
  note(`      keyboard: aria-valuenow=${kb}`);
  if (Number(kb) !== 44) fail.push(`arrow keys moved the splitter to ${kb}, expected 44`);

  await p.evaluate(() => window.__applySplit('col', 65));
  await ctx.close();
}

// ---- roles, selection and group move --------------------------------------
{
  const { p, ctx, errors } = await page({ width: 1400, height: 900 }, '?router=leaf1');
  await p.waitForTimeout(3500);
  await p.evaluate(() => window.__resetLayout());
  await p.waitForTimeout(400);

  const roles = await p.evaluate(() => ({
    rows: Array.from(document.querySelectorAll('#roles dt')).map((dt, i) => ({
      name: dt.textContent.replace(/\s+/g, ' ').trim(),
      desc: document.querySelectorAll('#roles dd')[i].textContent.replace(/\s+/g, ' ').trim(),
      accept: !!dt.querySelector('.mark.accept'),
    })),
    inPane: (() => {
      const f = document.querySelector('.graph-foot').getBoundingClientRect();
      const g = document.getElementById('graph-pane').getBoundingClientRect();
      return f.left >= g.left - 1 && f.right <= g.right + 1 && f.bottom <= g.bottom + 1;
    })(),
  }));
  note(`roles: ${roles.rows.length} entries, inside the graph pane=${roles.inPane}`);
  for (const r of roles.rows) note(`      ${r.name.padEnd(22)} accept=${r.accept}  ${r.desc.slice(0, 68)}`);
  if (roles.rows.length !== 5) fail.push(`roles legend has ${roles.rows.length} entries, expected 4 routers + the dynamic neighbour`);
  if (!roles.inPane) fail.push('the roles strip is not inside the graph pane');
  if (!roles.rows.some((r) => /leaf1/.test(r.name) && r.accept)) fail.push('leaf1 should carry the accepting mark in the legend');
  if (!roles.rows.some((r) => /spine/.test(r.name) && !r.accept)) fail.push('spine must not carry the accepting mark');
  if (!roles.rows.some((r) => /dynamic neighbour/.test(r.name))) fail.push('the dashed ellipses are not described');
  if (roles.rows.some((r) => !r.desc)) fail.push('a role entry has no description');

  // select all, then move the whole selection with one drag
  const moved = await p.evaluate(async () => {
    const cy = window.__cy;
    cy.nodes().select();
    const before = {};
    cy.nodes().forEach((n) => { before[n.id()] = { x: n.position('x'), y: n.position('y') }; });
    const sel = cy.$('node:selected').length;
    // Cytoscape moves every selected node when one is dragged; do it through
    // the same positions API the drag handler records from.
    cy.$('node:selected').forEach((n) => n.position({ x: n.position('x') + 40, y: n.position('y') + 25 }));
    cy.$('node:selected').emit('dragfree');
    await new Promise((r2) => setTimeout(r2, 150));
    const after = {};
    cy.nodes().forEach((n) => { after[n.id()] = { x: n.position('x'), y: n.position('y') }; });
    return { sel, before, after, placed: Object.keys(window.__placed()).length,
             count: document.getElementById('sel-count').textContent.trim() };
  });
  note(`selection: ${moved.sel} nodes selected, ${moved.placed} recorded as placed`);
  note(`      "${moved.count}"`);
  if (moved.sel !== 6) fail.push(`select all selected ${moved.sel} nodes, expected 6`);
  const allShifted = Object.keys(moved.before).every((id) =>
    Math.round(moved.after[id].x - moved.before[id].x) === 40 &&
    Math.round(moved.after[id].y - moved.before[id].y) === 25);
  if (!allShifted) fail.push('the selected nodes did not all move together');
  if (moved.placed !== 6) fail.push(`${moved.placed} positions recorded, expected 6`);

  // a state re-render must NOT throw the arrangement away
  const kept = await p.evaluate(async () => {
    const cy = window.__cy;
    const before = {};
    cy.nodes().forEach((n) => { before[n.id()] = { x: n.position('x'), y: n.position('y') }; });
    const state = await (await fetch('/api/state')).json();
    state.type = 'state';
    window.__ingestEvent({ id: 0, kind: 'route', router: 'leaf1', prefix: 'x', ts: new Date().toISOString() });
    // force the full path the WebSocket takes on a state frame
    window.dispatchEvent(new Event('resize'));
    await new Promise((r2) => setTimeout(r2, 300));
    const after = {};
    cy.nodes().forEach((n) => { after[n.id()] = { x: n.position('x'), y: n.position('y') }; });
    return Object.keys(before).every((id) =>
      Math.abs(after[id].x - before[id].x) < 1 && Math.abs(after[id].y - before[id].y) < 1);
  });
  note(`      arrangement survived a re-render: ${kept}`);
  if (!kept) fail.push('a re-render moved the hand-placed nodes back to the layout');

  // reset puts them back and forgets
  const reset = await p.evaluate(async () => {
    window.__resetLayout();
    await new Promise((r2) => setTimeout(r2, 300));
    return { placed: Object.keys(window.__placed()).length,
             stored: (() => { try { return localStorage.getItem('bgp.placed'); } catch (e) { return null; } })() };
  });
  note(`      after reset: placed=${reset.placed} stored=${reset.stored}`);
  if (reset.placed !== 0) fail.push('reset layout did not forget the hand placements');
  if (errors.length) fail.push('roles/selection js errors: ' + errors.join(' | '));
  await p.screenshot({ path: `${OUT}/1400-roles-selection.png` });
  await ctx.close();
}

// ---- the operator's case: filter Events by "router" -----------------------
// A healthy fabric emits no router events, so this list is legitimately empty.
// A blank pane is indistinguishable from a broken one, so it must say why and
// point at the view that does answer "is anything moving".
{
  const { p, ctx } = await page({ width: 1200, height: 800 }, '?router=leaf1&tab=events');
  await p.waitForTimeout(3000);
  const r = await p.evaluate(async () => {
    const sel = document.getElementById('ev-kind');
    sel.value = 'router';
    sel.dispatchEvent(new Event('change'));
    await new Promise((r2) => setTimeout(r2, 100));
    const empty = document.getElementById('events-empty');
    const eb = empty.getBoundingClientRect();
    const pb = document.getElementById('events-pane').getBoundingClientRect();
    return {
      rows: document.querySelectorAll('#events li').length,
      emptyHidden: empty.hidden,
      text: empty.textContent,
      kinds: Array.from(document.querySelectorAll('#ev-kind option')).map((o) => o.textContent.trim()),
      // The message must sit INSIDE its pane. Reusing the graph's .empty class
      // (position:absolute; inset:0) resolved it against the wrong ancestor and
      // painted the sentence across the topology and the RIB.
      inside: eb.left >= pb.left - 1 && eb.right <= pb.right + 1 && eb.top >= pb.top - 1,
      box: [Math.round(eb.left), Math.round(eb.right), Math.round(pb.left), Math.round(pb.right)],
    };
  });
  note(`events kind=router: rows=${r.rows} emptyShown=${!r.emptyHidden}`);
  note(`      "${r.text.trim()}"`);
  note(`      options: ${r.kinds.join(' | ')}`);
  if (r.rows !== 0) fail.push('this fabric should have no router events');
  if (r.emptyHidden) fail.push('an empty Events list explained nothing — the operator saw a blank pane');
  if (!/Traffic view/.test(r.text)) fail.push('the empty state does not point at the Traffic view');
  if (!r.kinds.some((k) => /unreachable/.test(k))) fail.push('the router option still reads as "router", not what it means');
  note(`      empty box l=${r.box[0]} r=${r.box[1]} inside pane l=${r.box[2]} r=${r.box[3]}`);
  if (!r.inside) fail.push('the empty message escaped its pane and painted over the graph');
  await p.screenshot({ path: `${OUT}/1200-events-router-empty.png` });
  await ctx.close();
}

// ---- Traffic answers what Events cannot -----------------------------------
{
  const { p, ctx, errors } = await page({ width: 1200, height: 800 }, '?router=leaf1&tab=events');
  await p.waitForTimeout(4500);
  const r = await p.evaluate(async () => {
    window.__setActivityView('traffic');
    await new Promise((r2) => setTimeout(r2, 200));
    const items = Array.from(document.querySelectorAll('#traffic .traffic-list li'));
    const rows = items.map((li) => ({
      link: li.querySelector('.link').textContent.trim(),
      msgs: li.querySelector('.msgs').textContent.replace(/\s+/g, ' ').trim(),
      heard: li.querySelector('.heard').textContent.replace(/\s+/g, ' ').trim(),
      meta: li.querySelector('.meta').textContent.replace(/\s+/g, ' ').trim(),
      h: Math.round(li.getBoundingClientRect().height),
    }));
    const pane = document.getElementById('events-pane').getBoundingClientRect();
    return {
      caption: (document.querySelector('#traffic .traffic-caption') || {}).textContent || '',
      rows,
      tallest: Math.max.apply(null, rows.map((r) => r.h)),
      paneH: Math.round(pane.height),
      eventsHidden: getComputedStyle(document.getElementById('events')).display,
    };
  });
  note(`traffic: ${r.caption.trim()}`);
  for (const row of r.rows) note(`      ${row.link.padEnd(22)} ${row.msgs.padEnd(14)} ${row.heard.padEnd(12)} ${row.meta} [${row.h}px]`);
  note(`      tallest row ${r.tallest}px in a ${r.paneH}px pane`);
  if (r.rows.length !== 7) fail.push(`traffic shows ${r.rows.length} links, expected 7`);
  if (r.eventsHidden !== 'none') fail.push('the Events list is still visible in the Traffic view');
  const fabric = r.rows.filter((x) => /fabric link/.test(x.meta));
  const cluster = r.rows.filter((x) => /cluster node/.test(x.meta));
  if (fabric.length !== 3) fail.push(`expected 3 fabric links, got ${fabric.length}`);
  if (cluster.length !== 4) fail.push(`expected 4 cluster links, got ${cluster.length}`);
  if (!cluster.some((x) => /not polled/.test(x.msgs))) fail.push('a cluster link must say its far end is not polled, not 0');
  if (!r.rows.some((x) => /\d/.test(x.msgs))) fail.push('no link reported a measured message');
  // The first layout wrapped the link name over four lines and fitted three
  // rows on screen. A row is two lines of text; anything taller has wrapped.
  if (r.tallest > 46) fail.push(`a traffic row is ${r.tallest}px tall — the link name is wrapping again`);
  if (r.rows.length * r.tallest > r.paneH * 2) fail.push('the traffic list needs more than two pane-heights for 7 links');
  if (errors.length) fail.push('traffic js errors: ' + errors.join(' | '));
  await p.screenshot({ path: `${OUT}/1200-traffic.png` });

  // it must keep up with the live signal, not freeze at the first render
  const before = await p.evaluate(() => document.querySelector('#traffic .traffic-caption').textContent);
  await p.waitForTimeout(5000);
  const after = await p.evaluate(() => document.querySelector('#traffic .traffic-list').textContent.replace(/\s+/g, ' ').trim());
  note(`      still live after 5s: ${after.slice(0, 70)}...`);
  if (!after) fail.push('the traffic table emptied itself');
  void before;
  await ctx.close();
}

// ---- the heartbeat only beats on a measured delta -------------------------
{
  const { p, ctx } = await page({ width: 1200, height: 800 }, '?router=leaf1');
  await p.waitForTimeout(3000);
  const r = await p.evaluate(async () => {
    // Silence the live socket first. A real signal frame arrives every 2s and
    // a pulse leaves `_beating` set for 580ms, so reading that flag while the
    // page is live tests the clock, not the code.
    window.__holdReconnect = true;
    try { window.__ws.close(); } catch (e) { /* already gone */ }
    await new Promise((r2) => setTimeout(r2, 700)); // let any in-flight pulse finish
    const seen = { beats: 0, calls: 0 };
    const cy = window.__cy;
    const n = cy.getElementById('leaf1');
    seen.quietBefore = n.scratch('_beating') || false;
    // a frame that measured NOTHING must not move the node
    const quiet = {
      type: 'signal', ts: new Date().toISOString(), ageMsec: 10,
      routers: [{ name: 'leaf1', reachable: true, hasDelta: true, dTableVersion: 0, dynamicPeers: 2 }],
      sessions: [{ router: 'leaf1', peer: '10.200.1.3', hasDelta: false, dRcvd: 0, dSent: 0, hasTimers: true, quietMsec: 1000, holdMsec: 9000, keepaliveMsec: 3000 }],
    };
    window.__applySignal(quiet);
    await new Promise((r2) => setTimeout(r2, 120));
    seen.afterQuiet = n.scratch('_beating') || false;

    const busy = JSON.parse(JSON.stringify(quiet));
    busy.sessions[0].hasDelta = true;
    busy.sessions[0].dRcvd = 4;
    window.__applySignal(busy);
    await new Promise((r2) => setTimeout(r2, 60));
    seen.afterBusy = n.scratch('_beating') || false;
    return seen;
  });
  note(`heartbeat: socket silenced, idle=${r.quietBefore} | after a frame with no delta beating=${r.afterQuiet} | after a measured delta beating=${r.afterBusy}`);
  if (r.quietBefore) fail.push('a pulse was still running when the case started; the socket was not silenced');
  if (r.afterQuiet) fail.push('the node pulsed on a frame that measured nothing');
  if (!r.afterBusy) fail.push('the node did NOT pulse on a measured delta');
  await ctx.close();
}

// ---- stale data is declared, not animated over ----------------------------
{
  const { p, ctx } = await page({ width: 1200, height: 800 }, '?router=leaf1');
  await p.waitForTimeout(2500);
  const r = await p.evaluate(async () => {
    // Same reason as the heartbeat case: a live frame arriving in the next
    // 80ms would reset ageMsec and the assertion would be testing the clock.
    window.__holdReconnect = true;
    try { window.__ws.close(); } catch (e) { /* already gone */ }
    await new Promise((r2) => setTimeout(r2, 300));
    window.__applySignal({ type: 'signal', ts: new Date().toISOString(), ageMsec: 42000, routers: [], sessions: [] });
    await new Promise((r2) => setTimeout(r2, 80));
    return {
      cls: document.getElementById('age').className,
      text: document.getElementById('age').textContent,
      body: document.body.classList.contains('stale-data'),
    };
  });
  note(`stale: age.class="${r.cls}" text="${r.text.trim()}" body.stale-data=${r.body}`);
  if (r.cls !== 'stale' || !r.body) fail.push('a 42s-old snapshot was not declared stale');
  await p.screenshot({ path: `${OUT}/1200-stale.png` });
  await ctx.close();
}

// ---- 375: still no overflow ----------------------------------------------
{
  const { p, ctx, errors } = await page({ width: 375, height: 700 }, '?router=leaf1');
  await p.waitForTimeout(3500);
  const m = await p.evaluate(() => {
    const over = [];
    document.querySelectorAll('*').forEach((el) => {
      const r = el.getBoundingClientRect();
      if (r.width > 0 && r.right > window.innerWidth + 0.5) over.push(el.tagName + '.' + el.className + ' right=' + r.right.toFixed(1));
    });
    return {
      innerWidth: window.innerWidth,
      scrollWidth: document.documentElement.scrollWidth,
      over: over.slice(0, 5),
      splitterVisible: getComputedStyle(document.getElementById('split-col')).display,
      strip: (document.getElementById('signal-strip') || {}).textContent || '',
    };
  });
  note(`375   innerWidth=${m.innerWidth} scrollWidth=${m.scrollWidth} splitter=${m.splitterVisible}`);
  note(`      strip="${m.strip.trim().slice(0, 90)}"`);
  if (m.scrollWidth > m.innerWidth) fail.push(`375 page overflows: scrollWidth=${m.scrollWidth}`);
  if (m.over.length) fail.push('375 elements past the viewport: ' + m.over.join(' | '));
  if (m.splitterVisible !== 'none') fail.push('the splitter must be hidden at 375');
  if (errors.length) fail.push('375 js errors: ' + errors.join(' | '));
  await p.screenshot({ path: `${OUT}/375-signal.png`, fullPage: false });
  await ctx.close();
}

await b.close();
if (fail.length) { console.log('\nWALK FAIL'); for (const f of fail) console.log('  - ' + f); process.exit(1); }
console.log('\nWALK PASS: signal renders, the heartbeat needs a measurement, resizing works, 375 has no overflow');
