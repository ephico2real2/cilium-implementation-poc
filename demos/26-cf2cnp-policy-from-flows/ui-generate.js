// ui-generate.js — method 2 of 3: the cf2cnp WEB UI, driven by Playwright so the tutorial's screenshots are reproducible.
//   GW=<gateway address> NODE_PATH=<dir with playwright> node demos/26-cf2cnp-policy-from-flows/ui-generate.js <flow.json>
// Pastes the flow into the page's textarea, clicks "Generate Policy", captures the page, prints the YAML the page shows and
// the download link it offers. Chromium resolves cf2cnp.poc.local to the Gateway itself (no /etc/hosts entry needed).
const { chromium } = require('playwright'); const fs = require('fs'); const path = require('path');
(async () => {
  const GW = process.env.GW, file = process.argv[2]; if (!GW || !file) { console.error('usage: GW=<addr> node ui-generate.js <flow.json>'); process.exit(2); }
  const out = path.join(__dirname, 'output', 'screenshots'); fs.mkdirSync(out, { recursive: true }); const flow = fs.readFileSync(file, 'utf8');
  const b = await chromium.launch({ args: [`--host-resolver-rules=MAP cf2cnp.poc.local ${GW}`] });
  const ctx = await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 1300 } }); const p = await ctx.newPage();
  await p.goto('https://cf2cnp.poc.local/', { waitUntil: 'load' }); await p.waitForTimeout(1500);
  await p.screenshot({ path: path.join(out, 'ui-1-empty.png') });
  await p.locator('textarea').first().fill(flow); await p.waitForTimeout(500);
  await p.screenshot({ path: path.join(out, 'ui-2-pasted.png') });
  await p.locator('button', { hasText: /generate/i }).first().click(); await p.waitForTimeout(3000);
  await p.screenshot({ path: path.join(out, 'ui-3-generated.png') });
  const text = await p.evaluate(() => document.body.innerText); const i = text.indexOf('apiVersion');
  console.log(i >= 0 ? text.slice(i, text.indexOf('protocol: TCP', i) + 13) : '(no YAML text found on the page)');
  const links = await p.locator('a').evaluateAll(as => as.map(a => `${a.innerText.trim()} → ${a.href}`).filter(x => /download/i.test(x)));
  console.log('download link:', links.join(' ; ') || '(none)');
  await b.close();
})().catch(e => { console.error('ERR', e.message.split('\n')[0]); process.exit(1); });
