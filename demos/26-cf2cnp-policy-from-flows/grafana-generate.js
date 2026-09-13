// grafana-generate.js — method 3 of 3: the Grafana dashboard's Flow UUID actions, driven by Playwright so the tutorial's
// screenshots are reproducible.
//   GW=<gateway address> NODE_PATH=<dir with playwright> node demos/26-cf2cnp-policy-from-flows/grafana-generate.js [namespace]
// Opens "Cilium Flows - Hubble Observer" filtered to the destination namespace (default cf2cnp-lab), scrolls the flow table to
// its Flow UUID column, clicks the first UUID, runs "Generate CiliumNetworkPolicy from Flow" (Grafana asks to Confirm — the
// action POSTs the whole log line to cf2cnp), then re-opens the menu and follows "Download CiliumNetworkPolicy", which opens
// /download/<uuid> in a new tab. Every cf2cnp request/response the browser makes is printed, so the mechanics are visible.
const { chromium } = require('playwright'); const fs = require('fs'); const path = require('path');
(async () => {
  const GW = process.env.GW, ns = process.argv[2] || 'cf2cnp-lab'; if (!GW) { console.error('usage: GW=<addr> node grafana-generate.js [namespace]'); process.exit(2); }
  const out = process.env.SHOTS_DIR || path.join(__dirname, 'output', 'screenshots'); fs.mkdirSync(out, { recursive: true });   // SHOTS_DIR: another demo's folder
  const b = await chromium.launch({ args: [`--host-resolver-rules=MAP *.poc.local ${GW}`] });
  const ctx = await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 2400, height: 1400 } }); const p = await ctx.newPage();
  const net = [];
  p.on('request', r => { if (/cf2cnp/.test(r.url())) net.push(`${r.method()} ${r.url()} headers=${JSON.stringify(Object.fromEntries(Object.entries(r.headers()).filter(([k]) => /x-grafana|^accept$|origin/.test(k))))} body=${(r.postData() || '').slice(0, 80)}${(r.postData() || '').length > 80 ? '…' : ''}`); });
  p.on('response', async r => { if (/cf2cnp/.test(r.url())) { let t = ''; try { t = (await r.text()).slice(0, 160).replace(/\n/g, ' '); } catch (e) {} net.push(`  ← ${r.status()} ${t}`); } });
  await p.goto('https://grafana.poc.local/login', { waitUntil: 'load' }); await p.fill('input[name=user]', 'admin'); await p.fill('input[name=password]', 'poc-grafana'); await p.click('button[type=submit]'); await p.waitForTimeout(3000);
  // DASH_URL (demo 34): another dashboard with the same Flow UUID actions — the Policy Verdicts dashboard's Loki row (E7)
  await p.goto(process.env.DASH_URL || `https://grafana.poc.local/d/hubble-observer-23862?orgId=1&from=now-30m&to=now&var-destinationnamespace=${ns}`, { waitUntil: 'load' });
  for (let i = 0; i < 40; i++) { await p.waitForTimeout(5000); if (/DROPPED/.test(await p.evaluate(() => document.body.innerText))) break; }
  await p.waitForTimeout(3000); await p.screenshot({ path: path.join(out, 'grafana-1-dashboard-filtered.png') });
  await p.evaluate(() => { document.querySelectorAll('*').forEach(e => { if (e.scrollWidth > e.clientWidth + 10) e.scrollLeft = e.scrollWidth; }); }); await p.waitForTimeout(2000);
  const cell = await p.evaluate(() => {
    const re = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
    const e = Array.from(document.querySelectorAll('[role="gridcell"] a, [role="gridcell"]')).find(e => re.test((e.innerText || '').trim()));
    if (e) e.scrollIntoView({ block: 'center' });   // demo 34: the Loki row sits below the fold of the verdicts dashboard
    return e ? { uuid: e.innerText.trim(), rect: e.getBoundingClientRect().toJSON() } : null;
  });
  if (!cell) { console.log('no Flow UUID cell found in the table'); await b.close(); process.exit(1); }
  console.log('first flow in the table, uuid:', cell.uuid);
  const r = cell.rect, cx = r.x + r.width / 2, cy = r.y + r.height / 2;
  await p.mouse.click(cx, cy); await p.waitForTimeout(1500); await p.screenshot({ path: path.join(out, 'grafana-2-uuid-menu.png') });
  const items = await p.evaluate(() => document.body.innerText); console.log('menu offers:', ['Generate CiliumNetworkPolicy from Flow', 'Download CiliumNetworkPolicy', 'Open this Flow UUID'].filter(t => items.includes(t)).join(' | '));
  await p.getByText(/Generate CiliumNetworkPolicy/).first().click(); await p.waitForTimeout(1500); await p.screenshot({ path: path.join(out, 'grafana-3-confirm.png') });
  const confirm = p.getByRole('button', { name: /^Confirm$/ }).first(); if (await confirm.count()) { await confirm.click(); console.log('confirmed the action'); }
  await p.waitForTimeout(5000); await p.screenshot({ path: path.join(out, 'grafana-4-generated.png') });
  await p.mouse.click(cx, cy); await p.waitForTimeout(1500);
  const [popup] = await Promise.all([ctx.waitForEvent('page', { timeout: 10000 }).catch(() => null), p.getByText(/Download CiliumNetworkPolicy/).first().click({ timeout: 10000 }).catch(e => console.log('download click:', e.message.split('\n')[0]))]);
  await p.waitForTimeout(3000);
  if (popup) { console.log('download tab:', popup.url()); try { const body = await popup.evaluate(() => document.body.innerText); console.log(body.slice(0, 700)); fs.writeFileSync(path.join(__dirname, 'policies', 'cnp-from-grafana.yaml'), body); console.log('saved → policies/cnp-from-grafana.yaml'); } catch (e) { console.log('(the tab is an attachment download, no page body)'); } }
  else console.log('download: no new tab observed');
  console.log('cf2cnp requests made by the browser:\n' + (net.map(l => '  ' + l).join('\n') || '  (none)'));
  await b.close();
})().catch(e => { console.error('ERR', e.message.split('\n')[0]); process.exit(1); });
