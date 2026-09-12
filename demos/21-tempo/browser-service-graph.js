const { chromium } = require('playwright');
(async () => {
  const S = process.env.S; const b = await chromium.launch(); const ctx = await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 2 }); const p = await ctx.newPage();
  await p.goto('https://grafana.poc.local/login', { waitUntil: 'load' }); await p.fill('input[name=user]', 'admin'); await p.fill('input[name=password]', 'poc-grafana'); await p.click('button[type=submit]'); await p.waitForTimeout(3000);
  const u = 'https://grafana.poc.local/explore?schemaVersion=1&panes=%7B%2217w%22:%7B%22datasource%22:%22tempo%22,%22queries%22:%5B%7B%22refId%22:%22A%22,%22datasource%22:%7B%22type%22:%22tempo%22,%22uid%22:%22tempo%22%7D,%22queryType%22:%22serviceMap%22,%22serviceMapUseNativeHistograms%22:false%7D%5D,%22range%22:%7B%22from%22:%22now-1h%22,%22to%22:%22now%22%7D,%22compact%22:false%7D%7D';
  await p.goto(u, { waitUntil: 'load' }); await p.waitForTimeout(25000);
  await p.screenshot({ path: S + '/service-graph-explore.png' });
  const ng = p.locator('text=Node graph').first(); if (await ng.count()) { await ng.scrollIntoViewIfNeeded(); await p.waitForTimeout(1500); }
  await p.screenshot({ path: S + '/service-graph-explore-full.png', fullPage: true });
  const panel = p.locator('[data-testid*="Node graph"], section:has-text("Node graph"), div:has-text("Node graph") >> nth=-1').first();
  const txt = await p.evaluate(() => document.body.innerText); console.log('nodes seen:', [...new Set((txt.match(/\b(user|api-gateway|customers-service|visits-service|vets-service|discovery-server|config-server)\b/g)||[]))].join(', '));
  await b.close();
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
