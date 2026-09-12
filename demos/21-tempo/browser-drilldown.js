const { chromium } = require('playwright');
(async () => {
  const S = process.env.S; const b = await chromium.launch(); const ctx = await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 2 }); const p = await ctx.newPage();
  await p.goto('https://grafana.poc.local/login', { waitUntil: 'load' }); await p.fill('input[name=user]', 'admin'); await p.fill('input[name=password]', 'poc-grafana'); await p.click('button[type=submit]'); await p.waitForTimeout(3000);
  const u = 'https://grafana.poc.local/a/grafana-exploretraces-app/explore?from=now-30m&to=now&timezone=browser&var-ds=tempo&var-primarySignal=nestedSetParent%3C0&var-filters=&var-metric=rate&var-groupBy=resource.service.name&var-spanListColumns=&var-latencyThreshold=&var-partialLatencyThreshold=&var-durationPercentiles=0.9&actionView=breakdown';
  await p.goto(u, { waitUntil: 'load' }); await p.waitForTimeout(25000);
  await p.screenshot({ path: S + '/traces-drilldown-breakdown.png' });
  await p.screenshot({ path: S + '/traces-drilldown-breakdown-full.png', fullPage: true });
  // the Traces tab (the list of root spans) and one trace opened from it
  const tab = p.getByRole('tab', { name: /^Traces/ }).first(); if (await tab.count()) { await tab.click(); await p.waitForTimeout(8000); await p.screenshot({ path: S + '/traces-drilldown-traces.png' }); }
  const txt = await p.evaluate(() => document.body.innerText); console.log('page:', txt.split('\n').filter(l => /Span rate|api-gateway|customers|visits|vets|Duration|Root spans|Traces/.test(l)).slice(0, 10).join(' | '));
  await b.close();
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
