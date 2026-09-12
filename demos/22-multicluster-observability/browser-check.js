const { chromium } = require('playwright');
(async () => {
  const S = process.env.S; const b = await chromium.launch(); const ctx = await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 2 }); const p = await ctx.newPage();
  await p.goto('https://grafana.poc.local/login', { waitUntil: 'load' }); await p.fill('input[name=user]', 'admin'); await p.fill('input[name=password]', 'poc-grafana'); await p.click('button[type=submit]'); await p.waitForTimeout(3000);
  for (const [k, u] of Object.entries({
    'net-poc2-bank': 'https://grafana.poc.local/d/nlsO8tYVz/hubble-network-overview-namespace?orgId=1&from=now-30m&to=now&var-cluster=poc2&var-source_namespace=bank&var-destination_namespace=All',
    'l7-poc2-accounts': 'https://grafana.poc.local/d/3g264CZVz/hubble-l7-http-metrics-by-workload?orgId=1&from=now-30m&to=now&var-cluster=poc2&var-destination_namespace=bank&var-destination_workload=accounts&var-reporter=server&var-source_namespace=All&var-source_workload=All',
    'cilium-poc2': 'https://grafana.poc.local/d/vtuWtdumz/cilium-metrics?orgId=1&from=now-30m&to=now&var-cluster=poc2',
  })) {
    await p.goto(u, { waitUntil: 'load' }); await p.waitForTimeout(18000); await p.screenshot({ path: `${S}/mc-${k}.png` });
    const vars = await p.evaluate(() => Array.from(document.querySelectorAll('[data-testid*="template variable"]')).map(e => e.innerText.trim().replace(/\n/g,'=')).filter(Boolean).slice(0, 8).join(' | '));
    const nodata = await p.evaluate(() => Array.from(document.querySelectorAll('body *')).filter(e => e.children.length === 0 && /^No data$/.test((e.innerText||'').trim())).length);
    console.log(`${k}: [${vars}] noData=${nodata}`);
  }
  // the cluster dropdown's options on the Network Overview
  await p.goto('https://grafana.poc.local/d/nlsO8tYVz/hubble-network-overview-namespace?orgId=1&from=now-30m&to=now', { waitUntil: 'load' }); await p.waitForTimeout(12000);
  const dd = p.locator('[data-testid*="template variable"]').filter({ hasText: 'cluster' }).first(); await dd.locator('input, [role=combobox]').first().click().catch(()=>{}); await p.waitForTimeout(1500);
  const opts = await p.evaluate(() => Array.from(document.querySelectorAll('[role=option]')).map(e => e.innerText.trim()).filter(Boolean)); console.log('cluster dropdown options:', opts.join(', '));
  await p.screenshot({ path: S + '/mc-cluster-dropdown.png' }); await b.close();
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
