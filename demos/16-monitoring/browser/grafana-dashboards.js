const { chromium } = require('playwright');
(async () => {
  const S = process.env.S; const b = await chromium.launch();
  const ctx = await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1500, height: 1000 }, httpCredentials: { username: 'admin', password: 'poc-grafana' } });
  const p = await ctx.newPage();
  await p.goto('https://grafana.poc.local/login', { waitUntil: 'load', timeout: 60000 }); await p.fill('input[name=user]', 'admin'); await p.fill('input[name=password]', 'poc-grafana'); await p.click('button[type=submit]'); await p.waitForTimeout(4000);
  const urls = {
    'hubble-l7': 'https://grafana.poc.local/d/3g264CZVz/hubble-l7-http-metrics-by-workload?orgId=1&from=now-12h&to=now&var-cluster=poc1&var-destination_namespace=bank&var-destination_workload=api&var-reporter=server&var-source_namespace=All&var-source_workload=All',
    'hubble-network': 'https://grafana.poc.local/d/nlsO8tYVz/hubble-network-overview-namespace?orgId=1&from=now-12h&to=now&var-cluster=poc1&var-source_namespace=bank&var-destination_namespace=All',
    'springboot': 'https://grafana.poc.local/d/springboot-19004/spring-boot-3-x-statistics-petclinic?orgId=1&from=now-1h&to=now&var-application=customers-service&var-Namespace=springboot'
  };
  for (const [k, u] of Object.entries(urls)) {
    await p.goto(u, { waitUntil: 'load', timeout: 60000 }); await p.waitForTimeout(20000);
    await p.screenshot({ path: `${S}/grafana-${k}.png`, fullPage: false });
    const titles = await p.evaluate(() => Array.from(document.querySelectorAll('[data-testid^="data-testid Panel header"], h2, h6')).map(e => e.innerText.trim()).filter(Boolean));
    const nodata = await p.evaluate(() => Array.from(document.querySelectorAll('body *')).filter(e => e.children.length === 0 && /^No data$/.test((e.innerText||'').trim())).length);
    console.log(`${k}: panels=${[...new Set(titles)].slice(0, 14).join(' | ')} ; "No data" panels=${nodata}`);
  }
  await b.close();
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
