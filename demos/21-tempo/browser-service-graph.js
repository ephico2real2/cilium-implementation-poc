const { chromium } = require('playwright');
(async () => {
  const S = process.env.S; const b = await chromium.launch(); const ctx = await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1500, height: 1000 } }); const p = await ctx.newPage();
  await p.goto('https://grafana.poc.local/login', { waitUntil: 'load' }); await p.fill('input[name=user]', 'admin'); await p.fill('input[name=password]', 'poc-grafana'); await p.click('button[type=submit]'); await p.waitForTimeout(3000);
  const u = 'https://grafana.poc.local/explore?schemaVersion=1&orgId=1&panes=' + encodeURIComponent(JSON.stringify({ t: { datasource: 'tempo', queries: [{ refId: 'A', datasource: { type: 'tempo', uid: 'tempo' }, queryType: 'serviceMap' }], range: { from: 'now-30m', to: 'now' } } }));
  await p.goto(u, { waitUntil: 'load' }); await p.waitForTimeout(20000); await p.screenshot({ path: S + '/grafana-service-graph.png' });
  const txt = await p.evaluate(() => document.body.innerText); console.log('page:', txt.split('\n').filter(l => /No service graph|api-gateway|customers|visits|vets|Service Graph|Rate|Error|Duration/i.test(l)).slice(0, 12).join(' | '));
  await b.close();
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
