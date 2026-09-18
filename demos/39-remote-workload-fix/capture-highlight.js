// capture-highlight.js — Cilium's "Hubble L7 HTTP Metrics by Workload" for shop / team-a, with the selector and the
// three General panels each boxed in its own colour (a key in the banner) and a banner saying why: this selection was "No data" for a remote backend before
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
      .lab-banner{background:#2b2f36;color:#fff;font:600 19px/1.35 -apple-system,Helvetica,Arial,sans-serif;padding:12px 20px;margin:6px 8px 10px;border-radius:0;box-shadow:0 2px 8px rgba(0,0,0,.45);border-left:10px solid #ff3b3b}
      .lab-banner small{display:block;font-weight:400;font-size:14px;color:#d7dbe2;margin-top:6px}
      .lab-key{display:inline-block;margin:0 14px 0 0;font-size:13px;font-weight:700;padding:3px 8px;color:#111}
      .lab-box{outline:4px solid var(--lab-c) !important;outline-offset:3px;border-radius:0 !important;box-shadow:0 0 0 6px color-mix(in srgb, var(--lab-c) 28%, transparent) !important}
      .lab-box *{border-radius:0 !important}
    `;
    document.head.appendChild(css);
    // one colour per box, named in the banner's key: red the selector, orange the volume, yellow the success rate, blue the latency
    const C = { selector: '#ff3b3b', volume: '#ff9830', success: '#f2cc0c', duration: '#5794f2' };
    const box = (el, c) => { if (!el) return; el.classList.add('lab-box'); el.style.setProperty('--lab-c', c); };
    const label = Array.from(document.querySelectorAll('label')).find(l => (l.innerText || '').trim() === 'Destination Workload');
    if (label) box(label.parentElement, C.selector);   // the variable control: label + value
    const varsRow = label ? (label.closest('[class*="submenu"], section, div[data-testid*="submenu"]') || label.parentElement.parentElement) : document.body.firstElementChild;
    const key = (c, t) => `<span class="lab-key" style="background:${c}">${t}</span>`;
    const banner = document.createElement('div'); banner.className = 'lab-banner';
    banner.innerHTML = 'Cilium\'s <b>Hubble L7 HTTP Metrics by Workload</b> for <b>shop / team-a</b> — the backend runs on the <b>other node</b> (control plane); the flows are reported by the <b>worker\'s</b> Envoy'
      + '<small>Yesterday this exact selection said "No data" on every panel (cilium/cilium#25676: the workload of a remote pod was unknown to the reporting agent). Now: the lab\'s fix — cilium-agent 1.20.2 1d3a02ab, the workload carried on the CiliumEndpoint — running on both clusters.</small>'
      + '<small style="margin-top:10px">' + key(C.selector, 'Destination Workload = shop — the selector that could never match a remote backend') + key(C.volume, 'requests per second') + key(C.success, 'success rate') + key(C.duration, 'latency P50 / P95 / P99') + '</small>';
    varsRow.insertAdjacentElement('afterend', banner);         // under the variable bar, so nothing is covered
    const pre = 'data-testid Panel header ';
    box(document.querySelector(`section[data-testid="${pre}Incoming Request Volume"]`), C.volume);
    box(document.querySelector(`section[data-testid="${pre}Incoming Request Success Rate (non-5xx responses)"]`), C.success);
    box(document.querySelector(`section[data-testid="${pre}Request Duration"]`), C.duration);
    window.scrollTo(0, 0);
  });
  await p.waitForTimeout(800);
  await p.screenshot({ path: OUT, clip: { x: 0, y: 0, width: 1600, height: 720 } });
  console.log(OUT);
  await b.close();
})();
