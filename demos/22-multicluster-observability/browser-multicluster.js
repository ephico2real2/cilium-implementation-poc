// Demo 22 Part 4 — capture "Kubernetes / Compute Resources / Multi-Cluster" and list the cluster names it shows.
// Usage: S=<dir> TAG=before|after node demos/22-multicluster-observability/browser-multicluster.js
const { chromium } = require('playwright');
(async () => {
  const S = process.env.S, TAG = process.env.TAG || 'x'; const b = await chromium.launch();
  const ctx = await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 1000 } }); const p = await ctx.newPage();
  await p.goto('https://grafana.poc.local/login', { waitUntil: 'load' }); await p.fill('input[name=user]', 'admin'); await p.fill('input[name=password]', 'poc-grafana'); await p.click('button[type=submit]'); await p.waitForTimeout(3000);
  await p.goto('https://grafana.poc.local/d/b59e6c9f2fcbe2e16d77fc492374cc4f/kubernetes-compute-resources-multi-cluster?orgId=1&from=now-1h&to=now&var-datasource=prometheus', { waitUntil: 'load' });
  await p.waitForTimeout(20000); await p.screenshot({ path: `${S}/mc-multicluster-${TAG}.png`, fullPage: false });
  // (extracting the table's cell text found no role=cell elements in this Grafana build; the capture is the evidence)
  await b.close();
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
