// capture-highlight.js — Cilium's "Hubble L7 HTTP Metrics by Workload" for shop / team-a, with the selector and the
// three General panels boxed in red and a banner saying why: this selection was "No data" for a remote backend before
// the fix (cilium/cilium#25676). The marks are drawn over the live page by this script; the dashboard is untouched.
//   PW=<grafana admin password> NODE_PATH=$PWD/.tmp/pw/node_modules node demos/39-remote-workload-fix/capture-highlight.js
// Send traffic from a pod on the OTHER node than the shop pods first (README §6), or the panels are empty for real.
const { chromium } = require('playwright');
const URL = 'https://grafana.poc.local/d/3g264CZVz/hubble-l7-http-metrics-by-workload?orgId=1&from=now-5m&to=now'
  + '&var-cluster=poc1&var-destination_namespace=team-a&var-destination_workload=shop&var-reporter=client&var-source_namespace=All&var-source_workload=All&kiosk';
const OUT = process.argv[2] || 'demos/39-remote-workload-fix/output/l7-by-workload-shop-team-a-highlighted.png';
(async () => {
  const b = await chromium.launch(); const ctx = await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 2 });
  const p = await ctx.newPage();
  await p.goto('https://grafana.poc.local/login', { waitUntil: 'networkidle' });
  await p.fill('input[name="user"]', 'admin'); await p.fill('input[name="password"]', process.env.PW); await p.click('button[type="submit"]');
  await p.waitForURL(u => !u.toString().includes('/login'), { timeout: 30000 });
  await p.goto(URL, { waitUntil: 'networkidle', timeout: 90000 });
  await p.waitForTimeout(12000);            // the panels' first queries
  await p.evaluate(() => {
    const css = document.createElement('style');
    css.textContent = `
      .lab-banner{background:#7a1b1b;color:#fff;font:600 19px/1.35 -apple-system,Helvetica,Arial,sans-serif;padding:12px 20px;margin:6px 8px 10px;border-radius:0;box-shadow:0 2px 8px rgba(0,0,0,.45)}
      .lab-banner small{display:block;font-weight:400;font-size:14px;color:#ffd9d9;margin-top:4px}
      .lab-box{outline:4px solid #ff3b3b !important;outline-offset:3px;border-radius:0 !important;box-shadow:0 0 0 6px rgba(255,59,59,.28) !important}
      .lab-box *{border-radius:0 !important}
      .lab-arrow{color:#ff3b3b;font:800 15px/1 -apple-system,Helvetica,Arial,sans-serif;margin:0 0 4px 12px}
    `;
    document.head.appendChild(css);
    const label = Array.from(document.querySelectorAll('label')).find(l => (l.innerText || '').trim() === 'Destination Workload');
    if (label) label.parentElement.classList.add('lab-box');   // the variable control: label + value
    const varsRow = label ? (label.closest('[class*="submenu"], section, div[data-testid*="submenu"]') || label.parentElement.parentElement) : document.body.firstElementChild;
    const banner = document.createElement('div'); banner.className = 'lab-banner';
    banner.innerHTML = '<span class="lab-arrow">▲ Destination Workload = shop</span><br>Cilium\'s <b>Hubble L7 HTTP Metrics by Workload</b> for <b>shop / team-a</b> — the backend runs on the <b>other node</b> (control plane); the flows are reported by the <b>worker\'s</b> Envoy'
      + '<small>Yesterday this exact selection said "No data" on every panel (cilium/cilium#25676: the workload of a remote pod was unknown to the reporting agent). Now: the lab\'s fix — cilium-agent 1.20.2 1d3a02ab, the workload carried on the CiliumEndpoint — running on both clusters.</small>';
    varsRow.insertAdjacentElement('afterend', banner);         // under the variable bar, so nothing is covered
    const pre = 'data-testid Panel header ';
    for (const name of ['Incoming Request Volume', 'Incoming Request Success Rate (non-5xx responses)', 'Request Duration']) {
      const sec = document.querySelector(`section[data-testid="${pre}${name}"]`); if (sec) sec.classList.add('lab-box');
    }
    window.scrollTo(0, 0);
  });
  await p.waitForTimeout(800);
  await p.screenshot({ path: OUT, clip: { x: 0, y: 0, width: 1600, height: 720 } });
  console.log(OUT);
  await b.close();
})();
