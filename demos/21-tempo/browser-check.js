const { chromium } = require('playwright'); const fs = require('fs'); const path = require('path');
(async () => {
  const S = process.env.S; const id = fs.readFileSync(path.resolve(__dirname, '../../.tmp/exemplar-ids.txt'),'utf8').split('\n')[0].trim();   // the repo's .tmp, wherever the checkout lives
  const b = await chromium.launch(); const ctx = await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1500, height: 1000 } }); const p = await ctx.newPage();
  await p.goto('https://grafana.poc.local/login', { waitUntil: 'load' }); await p.fill('input[name=user]', 'admin'); await p.fill('input[name=password]', 'poc-grafana'); await p.click('button[type=submit]'); await p.waitForTimeout(3000);
  await p.goto('https://grafana.poc.local/d/3g264CZVz/hubble-l7-http-metrics-by-workload?orgId=1&from=now-30m&to=now&var-cluster=poc1&var-destination_namespace=springboot&var-destination_workload=api-gateway&var-reporter=server&var-source_namespace=All&var-source_workload=All', { waitUntil: 'load' }); await p.waitForTimeout(20000);
  await p.screenshot({ path: S + '/grafana-l7-springboot-exemplars.png' });
  const dots = await p.locator('[data-testid*="exemplar"], .exemplar-marker, svg [class*="exemplar"]').count(); console.log('exemplar markers found on the L7 dashboard:', dots);
  const exp = 'https://grafana.poc.local/explore?schemaVersion=1&panes=' + encodeURIComponent(JSON.stringify({ t: { datasource: 'tempo', queries: [{ refId: 'A', datasource: { type: 'tempo', uid: 'tempo' }, queryType: 'traceql', query: id }] } })) + '&orgId=1';
  await p.goto(exp, { waitUntil: 'load' }); await p.waitForTimeout(15000); await p.screenshot({ path: S + '/grafana-tempo-trace.png' });
  const txt = await p.evaluate(() => document.body.innerText); const lines = txt.split('\n').filter(l => /api-gateway|customers-service|visits-service|vets-service|Trace|span/i.test(l)).slice(0, 12); console.log('Explore/Tempo page mentions:', lines.join(' | '));
  await b.close();
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
