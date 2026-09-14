// dashboards.js — capture the lab's pages the way the demos' browser scripts do (demos 16 and 25), from any host that can
// reach the Gateway: Chromium resolves the *.poc.local names itself (--host-resolver-rules), so /etc/hosts is not needed.
// Every capture waits until Grafana has no panel still loading (the loading bar, gotcha #66's lesson) plus a settle, and
// prints what it saw: the panel titles and how many say "No data" — the evidence line, beside the PNG.
//   S=<out dir> GW=<routes-gw address> HUBBLE=<hubble-ui address> node scripts/capture/dashboards.js
const { chromium } = require('playwright');
const S = process.env.S || '.', GW = process.env.GW || '172.18.255.240', HUBBLE = process.env.HUBBLE || '172.18.255.201';
const range = 'orgId=1&from=now-30m&to=now&refresh=';
// uid → the dashboard's own variable values; a variable without "All" must be given a value that exists, or every panel is empty
const dashboards = {
  'hubble-network-overview': `/d/nlsO8tYVz/hubble-network-overview-namespace?${range}&var-cluster=poc1&var-source_namespace=cf2cnp-lab30&var-destination_namespace=cf2cnp-lab30`,
  'hubble-l7-http':          `/d/3g264CZVz/hubble-l7-http-metrics-by-workload?${range}&var-cluster=poc1&var-destination_namespace=cf2cnp-lab30&var-destination_workload=shop-frontend&var-source_namespace=cf2cnp-lab30&var-source_workload=All`,
  'hubble-dns':              `/d/_f0DUpY4k/hubble-dns-overview-namespace?${range}&var-cluster=poc1&var-source_namespace=cf2cnp-lab&var-destination_namespace=All`,
  'hubble-metrics':          `/d/5HftnJAWz/hubble-metrics-and-monitoring?${range}`,
  'cilium-metrics':          `/d/vtuWtdumz/cilium-metrics?${range}`,
  'policy-verdicts':         `/d/hubble-policy-verdicts/hubble-policy-verdicts-namespace?${range}&var-cluster=poc1&var-namespace=cf2cnp-lab30`,
  'hubble-observer-flows':   `/d/hubble-observer-23862?${range}`,
};
async function settled(p, seconds) { // no panel loading, then a settle
  for (let i = 0; i < seconds; i++) {
    const loading = await p.evaluate(() => document.querySelectorAll('[aria-label="Panel loading bar"], [data-testid="Panel loading bar"], .panel-loading').length);
    if (loading === 0 && i > 2) return i; await p.waitForTimeout(1000);
  }
  return seconds;
}
(async () => {
  const b = await chromium.launch({ args: [`--host-resolver-rules=MAP grafana.poc.local ${GW}, MAP cf2cnp.poc.local ${GW}, MAP hubble.poc.local ${GW}`] });
  const ctx = await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 1100 } }); const p = await ctx.newPage();
  await p.goto('https://grafana.poc.local/login', { waitUntil: 'load', timeout: 60000 });
  await p.fill('input[name=user]', 'admin'); await p.fill('input[name=password]', process.env.GRAFANA_PASSWORD || 'poc-grafana');
  await p.click('button[type=submit]'); await p.waitForTimeout(3000);
  console.log('grafana: logged in as admin, title:', await p.title());
  for (const [name, path] of Object.entries(dashboards)) {
    await p.goto('https://grafana.poc.local' + path, { waitUntil: 'load', timeout: 60000 });
    const waited = await settled(p, 90); await p.waitForTimeout(6000);
    await p.screenshot({ path: `${S}/grafana-${name}.png` });
    const titles = await p.evaluate(() => [...new Set(Array.from(document.querySelectorAll('[data-testid^="data-testid Panel header"]')).map(e => e.innerText.trim()).filter(Boolean))]);
    const nodata = await p.evaluate(() => Array.from(document.querySelectorAll('body *')).filter(e => e.children.length === 0 && /^No data$/.test((e.innerText || '').trim())).length);
    console.log(`grafana-${name}: settled after ${waited}s; panels=${titles.length}; "No data"=${nodata}; first: ${titles.slice(0, 6).join(' | ')}`);
  }
  // Hubble UI at its own LoadBalancer address (SETUP Step 8) — the namespace list, then a service map
  await p.goto(`http://${HUBBLE}/`, { waitUntil: 'load', timeout: 60000 }); await p.waitForTimeout(4000);
  await p.screenshot({ path: `${S}/hubble-ui-namespaces.png` });
  const ns = process.env.HUBBLE_NS || 'cf2cnp-lab30';
  try { await p.getByText('Choose namespace').first().click({ timeout: 5000 }); await p.waitForTimeout(1500); await p.getByText(new RegExp('^' + ns + '$')).first().click({ timeout: 5000 }); await p.waitForTimeout(12000); }
  catch (e) { console.log('hubble-ui: namespace pick did not complete:', e.message.split('\n')[0]); }
  await p.screenshot({ path: `${S}/hubble-ui-${ns}.png` });
  console.log('hubble-ui:', (await p.evaluate(() => document.body.innerText)).split('\n').filter(l => l.trim()).slice(0, 12).join(' | '));
  // cf2cnp behind the Gateway (demo 25 Part 11)
  await p.goto('https://cf2cnp.poc.local/', { waitUntil: 'load', timeout: 60000 }); await p.waitForTimeout(3000);
  await p.screenshot({ path: `${S}/cf2cnp.png` }); console.log('cf2cnp title:', await p.title());
  await b.close();
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
