// capture.js — kiosk screenshots of the six tutorial dashboards, and fail if a caption rendered raw markdown
// (the <!-- caption --> marker-on-the-same-line bug). Password from PW; Playwright from NODE_PATH.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const UIDS = [
  'tut-1-question', 'tut-2-time', 'tut-3-colour',
  'tut-4-meaning', 'tut-5-grow', 'tut-6-cilium',
];

(async () => {
  const pw = process.env.PW;
  if (!pw) { console.error('PW is required'); process.exit(2); }
  const out = path.join(__dirname, 'output', 'screenshots');
  fs.mkdirSync(out, { recursive: true });

  const browser = await chromium.launch();
  const context = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 1000 } });
  const page = await context.newPage();

  await page.goto('https://grafana.poc.local/login', { waitUntil: 'load', timeout: 60000 });
  await page.fill('input[name="user"]', 'admin');
  await page.fill('input[name="password"]', pw);
  await page.click('button[type="submit"]');
  await page.waitForURL(u => !String(u).includes('/login'), { timeout: 30000 });

  const raw = [];
  let upMissing = false;
  for (const uid of UIDS) {
    const url = `https://grafana.poc.local/d/${uid}?orgId=1&from=now-1h&to=now&kiosk`;
    try {
      await page.goto(url, { waitUntil: 'networkidle', timeout: 90000 });
    } catch (e) {
      // Grafana's 30s refresh can keep the network busy past networkidle
      console.log(`${uid}: networkidle ${e.message.split('\n')[0]}`);
    }
    await page.waitForTimeout(8000);
    const shot = path.join(out, `${uid}.png`);
    await page.screenshot({ path: shot, fullPage: true });
    const texts = await page.evaluate(() =>
      Array.from(document.querySelectorAll('.markdown-html')).map(e => e.innerText || ''));
    const bad = texts.filter(t => t.includes('**') || t.includes('`'));
    console.log(`${uid}: screenshot ${shot} captions=${texts.length}${bad.length ? ' RAW' : ''}`);
    for (const t of bad) raw.push({ uid, t });

    if (uid === 'tut-1-question') {
      const upText = await page.evaluate(() => {
        const title = 'A state over time — node-exporter up';
        const header = Array.from(document.querySelectorAll('[data-testid^="data-testid Panel header"]'))
          .find(e => (e.getAttribute('data-testid') || '').includes(title));
        if (!header) return '';
        const root = header.closest('[data-viz-panel-key]') || header.parentElement;
        const body = (root && (root.querySelector('[data-testid="data-testid panel content"]') || root)) || header;
        const legend = root && (root.querySelector('[class*="legend"]') || root.querySelector('[class*="Legend"]'));
        return [body.innerText || '', (legend && legend.innerText) || ''].join('\n');
      });
      if (!upText.includes('UP')) {
        console.error(`tut-1-question: state timeline has no UP (got ${JSON.stringify(upText.slice(0, 240))})`);
        upMissing = true;
      } else {
        console.log('tut-1-question: state timeline has UP');
      }
    }
  }

  await browser.close();
  if (raw.length) {
    console.error('RAW MARKDOWN in captions (marker bug):');
    for (const r of raw) console.error(`  ${r.uid}: ${JSON.stringify(r.t)}`);
    process.exit(1);
  }
  if (upMissing) process.exit(1);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
