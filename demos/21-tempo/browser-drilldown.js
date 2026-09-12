const { chromium } = require('playwright');
(async () => {
  const S = process.env.S; const b = await chromium.launch(); const ctx = await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1500, height: 1000 } }); const p = await ctx.newPage();
  await p.goto('https://grafana.poc.local/login', { waitUntil: 'load' }); await p.fill('input[name=user]', 'admin'); await p.fill('input[name=password]', 'poc-grafana'); await p.click('button[type=submit]'); await p.waitForTimeout(3000);
  await p.goto('https://grafana.poc.local/a/grafana-exploretraces-app/explore?from=now-30m&to=now&var-ds=tempo', { waitUntil: 'load' }); await p.waitForTimeout(25000); await p.screenshot({ path: S + '/grafana-traces-drilldown.png' });
  const txt = await p.evaluate(() => document.body.innerText); console.log('drilldown:', txt.split('\n').filter(l => /TraceQL metrics not configured|localblocks|api-gateway|customers|visits|vets|Rate|Errors|Duration|Root/i.test(l)).slice(0, 12).join(' | ') || '(no matching text)');
  await b.close();
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
