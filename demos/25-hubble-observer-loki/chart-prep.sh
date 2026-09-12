#!/usr/bin/env bash
# chart-prep.sh — the critical first step for every chart in this demo, done the same way each time:
#   1. add the chart source to the machine (a Helm repo, or an OCI registry — OCI has no `helm repo add`);
#   2. list the versions available and pick one ON PURPOSE;
#   3. pull THAT version's default values into default-values/<chart>-<version>.yaml (committed: the baseline we diff against);
#   4. write our own values-<chart>.yaml FROM the default, with an inline comment on every key we change or disable.
# Steps 1–3 are this script (idempotent; output recorded in output/transcript.txt). Step 4 is the values-*.yaml files.
set -uo pipefail; cd "$(dirname "$0")"; mkdir -p default-values
echo "== 1. sources =="
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 && helm repo update grafana >/dev/null 2>&1 && echo "  grafana  https://grafana.github.io/helm-charts (Helm repo: Loki)"
echo "  ghcr.io/onzack/helm-charts (OCI registry: hubble-observer, cf2cnp — pulled by reference, no repo add)"

echo "== 2. versions available =="
echo "  grafana/loki (newest 5):"; helm search repo grafana/loki --versions 2>/dev/null | awk 'NR>1 && $1=="grafana/loki" {printf "    chart %-8s app %s\n", $2, $3}' | head -5
for c in hubble-observer cf2cnp; do
  # ghcr.io is an OCI registry: anonymous pull token → the tags list is the chart versions
  TOK=$(curl -s "https://ghcr.io/token?scope=repository:onzack/helm-charts/$c:pull" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
  echo "  oci://ghcr.io/onzack/helm-charts/$c tags: $(curl -s -H "Authorization: Bearer $TOK" "https://ghcr.io/v2/onzack/helm-charts/$c/tags/list" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin).get("tags",[])))')"
done
echo "  chart/hubble-observer (vendored from git main, see chart/UPSTREAM-COMMIT.txt): version $(grep '^version:' chart/hubble-observer/Chart.yaml | awk '{print $2}'), appVersion $(grep '^appVersion:' chart/hubble-observer/Chart.yaml | awk '{print $2}')"

echo "== 3. default values of the versions we use =="
helm show values grafana/loki --version 7.3.0 > default-values/loki-7.3.0.yaml && echo "  default-values/loki-7.3.0.yaml ($(wc -l < default-values/loki-7.3.0.yaml | tr -d ' ') lines)"
helm show values oci://ghcr.io/onzack/helm-charts/hubble-observer --version 2.5.0 > default-values/hubble-observer-2.5.0.yaml 2>/dev/null && echo "  default-values/hubble-observer-2.5.0.yaml ($(wc -l < default-values/hubble-observer-2.5.0.yaml | tr -d ' ') lines) — the published chart, NOT used (probe bug, README Part 2)"
helm show values chart/hubble-observer > default-values/hubble-observer-2.6.0-alpha.yaml && echo "  default-values/hubble-observer-2.6.0-alpha.yaml ($(wc -l < default-values/hubble-observer-2.6.0-alpha.yaml | tr -d ' ') lines) — the vendored chart we install"
helm show values oci://ghcr.io/onzack/helm-charts/cf2cnp --version 0.4.0 > default-values/cf2cnp-0.4.0.yaml 2>/dev/null && echo "  default-values/cf2cnp-0.4.0.yaml ($(wc -l < default-values/cf2cnp-0.4.0.yaml | tr -d ' ') lines) — the subchart (values under cf2cnp: in ours)"
echo "  what 2.5.0 and main differ in (values keys): $(diff <(grep -oE '^[a-zA-Z]+:' default-values/hubble-observer-2.5.0.yaml | sort -u) <(grep -oE '^[a-zA-Z]+:' default-values/hubble-observer-2.6.0-alpha.yaml | sort -u) | grep '^[<>]' | tr '\n' ' ' || echo none)"

echo "== 4. our values vs the defaults — every top-level key we set, and its default =="
python3 - <<'PY'
import yaml
def flat(d,p=''):
    out={}
    for k,v in (d or {}).items():
        kk=f"{p}.{k}" if p else k
        if isinstance(v,dict) and v: out.update(flat(v,kk))
        else: out[kk]=v
    return out
for ours,defaults in [('values-loki.yaml','default-values/loki-7.3.0.yaml'),('values-hubble-observer.yaml','default-values/hubble-observer-2.6.0-alpha.yaml')]:
    o=flat(yaml.safe_load(open(ours))); d=flat(yaml.safe_load(open(defaults)))
    print(f"  {ours} vs {defaults}: {len(o)} keys set")
    for k,v in o.items():
        dv=d.get(k,'<not in defaults>')
        mark='=' if dv==v else '≠'
        print(f"    {mark} {k}: {v!r}   (default: {dv!r})")
PY
