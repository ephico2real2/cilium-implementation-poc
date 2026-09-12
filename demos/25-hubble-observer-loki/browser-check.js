// Demo 25 — capture "Cilium Flows - Hubble Observer" (Loki) in Grafana and the cf2cnp UI behind the Gateway.
// Usage: S=<dir> node demos/25-hubble-observer-loki/browser-check.js   (Playwright from the demo 16 setup)
const { chromium } = require('playwright');
(async () => {
  const S = process.env.S, GW = process.env.GW || '172.18.255.240';
  // cf2cnp.poc.local may not be in /etc/hosts yet (hosts-entries.sh needs sudo): let Chromium resolve it to the Gateway itself
  const b = await chromium.launch({ args: [`--host-resolver-rules=MAP cf2cnp.poc.local ${GW}`] });
  const ctx = await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 1100 } }); const p = await ctx.newPage();
  await p.goto('https://grafana.poc.local/login', { waitUntil: 'load' }); await p.fill('input[name=user]', 'admin'); await p.fill('input[name=password]', 'poc-grafana'); await p.click('button[type=submit]'); await p.waitForTimeout(3000);
  await p.goto('https://grafana.poc.local/d/hubble-observer-23862?orgId=1&from=now-1h&to=now', { waitUntil: 'load' });
  // the LogQL panels parse every line (| json) over the range and this VM runs at load > 100 (gotcha #66): wait, up to
  // 6 minutes, until the Total Flows stat shows a number, then a little longer for the pie charts and the table
  let shown = null;
  for (let i = 0; i < 72; i++) { await p.waitForTimeout(5000); shown = await p.evaluate(() => { const h = Array.from(document.querySelectorAll('[data-testid^="data-testid Panel header"]')).find(e => /Total Flows/.test(e.getAttribute('data-testid'))); const m = h && h.innerText.match(/\b\d+\b/); return m ? m[0] : null; }); if (shown) break; }
  await p.waitForTimeout(15000); console.log(`Total Flows panel shows: ${shown}`);
  await p.screenshot({ path: `${S}/ho-dashboard.png` });
  const nodata = await p.evaluate(() => Array.from(document.querySelectorAll('body *')).filter(e => e.children.length === 0 && /^No data$/.test((e.innerText || '').trim())).length);
  const stats = await p.evaluate(() => Array.from(document.querySelectorAll('[data-testid*="panel"] [class*="stat"], [data-testid="data-testid Panel header Total Flows"]')).map(e => e.innerText.trim()).filter(Boolean).slice(0, 4));
  console.log(`dashboard: noData panels=${nodata}; sample=${JSON.stringify(stats)}`);
  await p.goto('https://cf2cnp.poc.local/', { waitUntil: 'load' }); await p.waitForTimeout(3000); await p.screenshot({ path: `${S}/ho-cf2cnp.png` });
  console.log('cf2cnp title:', await p.title());
  await b.close();
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
