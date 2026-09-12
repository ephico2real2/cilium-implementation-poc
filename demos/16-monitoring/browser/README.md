# Browser checks (Playwright) — how Part 11 was measured

```bash
cd /tmp && mkdir -p pw && cd pw && npm init -y >/dev/null && npm i playwright@1.63.0 && npx playwright install chromium
S=/tmp/pw node /Users/olasumbo/gitRepos/cilium-kind-poc/demos/16-monitoring/browser/hubble-ui-walk.js      # Hubble UI: namespace, service map, flow table, DOM search, screenshots
S=/tmp/pw node /Users/olasumbo/gitRepos/cilium-kind-poc/demos/16-monitoring/browser/grafana-dashboards.js  # Grafana: form login, three dashboards, panel titles, screenshots
```

Both use `ignoreHTTPSErrors` (the lab CA is not in Chromium's store) and need the hosts entries for
`hubble.poc.local` / `grafana.poc.local` and the demo 09 route to the kind network. Hubble UI never
reaches `networkidle` (its streams stay open) — wait for `load`. Grafana's basic auth works for its
API only; the page needs the login form. Dashboard variables without *All* (`destination_workload`)
must be given a real value in the URL, or every panel is empty.
