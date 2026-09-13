// ui-generate.js — method 2 of 3: the cf2cnp WEB UI, driven by Playwright so the tutorial's screenshots are reproducible.
//   GW=<gateway address> NODE_PATH=<dir with playwright> node demos/26-cf2cnp-policy-from-flows/ui-generate.js <flow.json>
// Pastes the flow(s) into the page's textarea, reads the page's own summary of what it parsed, clicks "Generate Policy",
// captures the page, prints the YAML the page shows and its apply hint, then exercises Copy YAML. Written for the fork's
// page (demo 26 Part 14); the upstream 0.3.1 page had only the textarea and the button (ui-*-upstream-0.3.1.png).
// Chromium resolves cf2cnp.poc.local to the Gateway itself (no /etc/hosts entry needed).
const { chromium } = require('playwright'); const fs = require('fs'); const path = require('path');
(async () => {
  const GW = process.env.GW, file = process.argv[2]; if (!GW || !file) { console.error('usage: GW=<addr> node ui-generate.js <flow.json>'); process.exit(2); }
  const out = path.join(__dirname, 'output', 'screenshots'); fs.mkdirSync(out, { recursive: true }); const flow = fs.readFileSync(file, 'utf8');
  const b = await chromium.launch({ args: [`--host-resolver-rules=MAP cf2cnp.poc.local ${GW}`] });
  const ctx = await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 1300 } }); const p = await ctx.newPage();
  await p.goto('https://cf2cnp.poc.local/', { waitUntil: 'load' }); await p.waitForTimeout(1500);
  await p.screenshot({ path: path.join(out, 'ui-1-empty.png') });
  await p.locator('textarea').first().fill(flow); await p.locator('textarea').first().dispatchEvent('input'); await p.waitForTimeout(500);
  console.log('page summary:', (await p.locator('#summary').innerText()).trim() || '(none)');
  if (process.env.NAME) await p.fill('#policyName', process.env.NAME);
  await p.screenshot({ path: path.join(out, 'ui-2-pasted.png') });
  await p.locator('button', { hasText: /generate policy/i }).first().click(); await p.waitForTimeout(3000);
  await p.screenshot({ path: path.join(out, 'ui-3-generated.png') });
  console.log('apply hint:', (await p.locator('#apply').innerText()).trim() || '(none)');
  const yaml = (await p.locator('#result').innerText()).trim(); const i = yaml.indexOf('apiVersion');
  console.log(i >= 0 ? yaml : '(no YAML text found on the page)');
  const copyEnabled = await p.locator('#copyBtn').isEnabled(), dlEnabled = await p.locator('#downloadBtn').isEnabled();
  console.log('Copy YAML enabled:', copyEnabled, '| Download YAML enabled:', dlEnabled);
  await b.close();
})().catch(e => { console.error('ERR', e.message.split('\n')[0]); process.exit(1); });
