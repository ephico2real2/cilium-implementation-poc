// walk.js — drive a browser through pages named in a JSON spec and leave a PNG and an evidence line per page.
// The spec is data, so a new endpoint is a new entry, not new code (the operator, 2026-09-14). Playwright resolves the
// lab's *.poc.local names itself from the spec's "resolve" map (Chromium --host-resolver-rules), so /etc/hosts is not
// needed on the runner or the Mac; ${VAR} in the spec expands from the environment (GW, HUBBLE, GRAFANA_PASSWORD, …).
//
//   S=<out dir> GW=… HUBBLE=… node scripts/capture/walk.js scripts/capture/lab.json
//
// spec: { "viewport": {"width", "height"}, "resolve": {"host": "${GW}"}, "login": {"url", "user": [sel, value],
//         "password": [sel, value], "submit": sel}, "pages": [ {"name", "url", "settle": true|false, "before": ms,
//         "actions": [ {"click": "visible text, exact"}, {"clickSelector": css}, {"fill": [sel, value]}, {"wait": ms} ], "screenshot": true,
//         "evidence": "panels" | "text" | "title" } ] }
const { chromium } = require('playwright'); const fs = require('fs');
const S = process.env.S || '.'; const expand = s => String(s).replace(/\$\{(\w+)\}/g, (_, k) => process.env[k] ?? '');
const spec = JSON.parse(expand(fs.readFileSync(process.argv[2] || 'scripts/capture/lab.json', 'utf8')));
async function settled(p, seconds) { // Grafana: no panel still loading (gotcha #66's lesson), then the caller's settle
  for (let i = 0; i < seconds; i++) {
    const loading = await p.evaluate(() => document.querySelectorAll('[aria-label="Panel loading bar"], [data-testid="Panel loading bar"], .panel-loading').length);
    if (loading === 0 && i > 2) return i; await p.waitForTimeout(1000);
  }
  return seconds;
}
const evidence = {
  panels: async p => { const t = await p.evaluate(() => [...new Set(Array.from(document.querySelectorAll('[data-testid^="data-testid Panel header"]')).map(e => e.innerText.trim()).filter(Boolean))]);
    const n = await p.evaluate(() => Array.from(document.querySelectorAll('body *')).filter(e => e.children.length === 0 && /^No data$/.test((e.innerText || '').trim())).length);
    return `panels=${t.length}; "No data"=${n}; first: ${t.slice(0, 6).join(' | ')}`; },
  text: async p => (await p.evaluate(() => document.body.innerText)).split('\n').filter(l => l.trim()).slice(0, 10).join(' | '),
  title: async p => `title: ${await p.title()}`,
};
(async () => {
  const rules = Object.entries(spec.resolve || {}).map(([h, a]) => `MAP ${h} ${a}`).join(', ');
  const b = await chromium.launch({ args: rules ? [`--host-resolver-rules=${rules}`] : [] });
  const ctx = await b.newContext({ ignoreHTTPSErrors: true, viewport: spec.viewport || { width: 1600, height: 1100 } }); const p = await ctx.newPage();
  if (spec.login) { const l = spec.login; await p.goto(l.url, { waitUntil: 'load', timeout: 60000 }); await p.fill(l.user[0], l.user[1]); await p.fill(l.password[0], l.password[1]); await p.click(l.submit); await p.waitForTimeout(3000); console.log(`login: ${l.url} → ${await p.title()}`); }
  let failures = 0;
  for (const page of spec.pages) {
    try {
      await p.goto(page.url, { waitUntil: 'load', timeout: 60000 });
      const waited = page.settle === false ? 0 : await settled(p, page.settleSeconds || 90);
      await p.waitForTimeout(page.before || 5000);
      for (const a of page.actions || []) {
        // "click" is visible text, exact; "clickSelector" is CSS. (A heuristic that guessed "bank" was a CSS tag and
        // "cf2cnp-lab30" was text cost one capture in run 34905753996 — no guessing.)
        if (a.click) await p.getByText(new RegExp('^' + a.click.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$')).filter({ visible: true }).first().click({ timeout: a.timeout || 8000 });
        if (a.clickSelector) await p.locator(a.clickSelector).first().click({ timeout: a.timeout || 8000 });
        if (a.fill) await p.fill(a.fill[0], a.fill[1]);
        if (a.wait) await p.waitForTimeout(a.wait);
      }
      if (page.screenshot !== false) await p.screenshot({ path: `${S}/${page.name}.png`, fullPage: !!page.fullPage });
      const ev = await (evidence[page.evidence || 'title'])(p);
      console.log(`${page.name}: settled ${waited}s; ${ev}`);
    } catch (e) { failures++; console.log(`${page.name}: FAILED — ${e.message.split('\n')[0]}`); try { await p.screenshot({ path: `${S}/${page.name}-failed.png` }); } catch {} }
  }
  await b.close(); if (failures) { console.log(`${failures} page(s) failed`); process.exit(2); }
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
