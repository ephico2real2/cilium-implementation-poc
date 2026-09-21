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
