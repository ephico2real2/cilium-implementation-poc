// capture.js — one Playwright runner for every demo. Usage:
//   GW=<gateway address> node scripts/evidence/capture.js demos/16-monitoring
// Reads demos/<demo>/evidence.json: {"captures":[{"name":"...","url":"...","wait":"text|ms","fullPage":false,"look":"..."}]}
// and writes demos/<demo>/output/screenshots/<name>.png. Chromium resolves *.poc.local (and exact.example.test) to the
// Gateway itself, so no /etc/hosts entry is needed; Grafana gets a form login once; waits are either a fixed number of
// milliseconds or "text:<string>" = wait (up to 6 min) until the page's text contains it (a rendered value), then 4 s.
const { chromium } = require('playwright'); const fs = require('fs'); const path = require('path');
(async () => {
  const demo = process.argv[2]; const GW = process.env.GW; if (!demo || !GW) { console.error('usage: GW=<addr> node capture.js <demo dir>'); process.exit(2); }
  const spec = JSON.parse(fs.readFileSync(path.join(demo, 'evidence.json'))); const out = path.join(demo, 'output', 'screenshots'); fs.mkdirSync(out, { recursive: true });
  const b = await chromium.launch({ args: [`--host-resolver-rules=MAP *.poc.local ${GW}, MAP exact.example.test ${GW}`] });
  const ctx = await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 1000 } }); const p = await ctx.newPage(); let loggedIn = false;
  for (const c of spec.captures) {
    if (c.url.includes('grafana.poc.local') && !loggedIn) { await p.goto('https://grafana.poc.local/login', { waitUntil: 'load' }); await p.fill('input[name=user]', 'admin'); await p.fill('input[name=password]', 'poc-grafana'); await p.click('button[type=submit]'); await p.waitForTimeout(3000); loggedIn = true; }
    try {
      await p.setViewportSize({ width: 1600, height: c.height || 1000 });   // Grafana scrolls inside a fixed-height app shell: fullPage does not help, a taller viewport does
      await p.goto(c.url, { waitUntil: 'load', timeout: 90000 });
      if (typeof c.wait === 'string' && c.wait.startsWith('text:')) { const t = c.wait.slice(5); let ok = false; for (let i = 0; i < 72; i++) { await p.waitForTimeout(5000); if ((await p.evaluate(() => document.body.innerText)).includes(t)) { ok = true; break; } } await p.waitForTimeout(4000); console.log(`${c.name}: waited for "${t}" → ${ok ? 'seen' : 'NOT seen (captured anyway)'}`); }
      else { await p.waitForTimeout(Number(c.wait || 15000)); }
      const nodata = await p.evaluate(() => Array.from(document.querySelectorAll('body *')).filter(e => e.children.length === 0 && /^No data$/.test((e.innerText || '').trim())).length);
      await p.screenshot({ path: path.join(out, `${c.name}.png`), fullPage: !!c.fullPage });
      console.log(`${c.name}: ok${c.url.includes('grafana') ? ` (noData panels=${nodata})` : ''}`);
    } catch (e) { console.log(`${c.name}: FAILED ${e.message.split('\n')[0]}`); }
  }
  await b.close();
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
