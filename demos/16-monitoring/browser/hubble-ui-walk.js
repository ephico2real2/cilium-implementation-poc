const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch(); const ctx = await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1500, height: 950 } });
  const p = await ctx.newPage();
  await p.goto('https://hubble.poc.local/', { waitUntil: 'load', timeout: 60000 }); await p.waitForTimeout(2000);
  await p.getByText('Choose namespace').first().click(); await p.waitForTimeout(1500);
  const opts = await p.evaluate(() => Array.from(document.querySelectorAll('[role=option], [role=menuitem], li, a')).map(e => e.innerText.trim()).filter(t => t && t.length < 40));
  console.log('namespace options:', [...new Set(opts)].join(' | '));
  const target = (await p.getByText(/^springboot$/).count()) ? 'springboot' : opts.find(o => /^[a-z0-9-]+$/.test(o));
  await p.getByText(new RegExp('^' + target + '$')).first().click(); console.log('selected:', target);
  await p.waitForTimeout(12000);
  await p.screenshot({ path: S + '/hubble-3-servicemap.png', fullPage: false });
  const text = await p.evaluate(() => document.body.innerText);
  console.log('--- visible text after selecting the namespace (first 90 lines) ---'); console.log(text.split('\n').filter(l => l.trim()).slice(0, 90).join('\n'));
  console.log('--- headers / column names / buttons ---');
  const labels = await p.evaluate(() => Array.from(document.querySelectorAll('th, [role=columnheader], button, [role=tab], [class*=tab], [class*=Tab], [class*=header] *')).map(e => (e.innerText || '').trim()).filter(t => t && t.length < 40));
  console.log([...new Set(labels)].join(' | '));
  console.log('--- metric/histogram/latency/chart words in the DOM now ---');
  const html = await p.content(); const m = html.match(/[a-z-]*(metric|histogram|latenc|chart|graph|p95|percentile|duration)[a-z-]*/gi) || []; console.log([...new Set(m.map(x => x.toLowerCase()))].join(', ') || '(none)');
  // click the first service node in the map, if any, and see the side panel
  const node = p.locator('svg g[class*=node], [class*=ServiceCard], [class*=service-card]').first();
  if (await node.count()) { await node.click({ force: true }).catch(()=>{}); await p.waitForTimeout(2500); await p.screenshot({ path: S + '/hubble-4-node.png' });
    const t2 = await p.evaluate(() => document.body.innerText); console.log('--- after clicking a node: new text lines ---'); console.log(t2.split('\n').filter(l => l.trim() && !text.includes(l)).slice(0, 40).join('\n')); }
  await b.close();
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
const S = process.env.S;
