# Demo 41 — the guide: exercises

Run from the repo root with poc1 and poc2 up, demo 40 applied, and phase 1 applied
(`demos/41-shop-mesh-phase1/apply-both.sh`). Exercise 0 is `apply-both.sh` itself. None of
these three writes the VIP announcer or scales a Deployment (scenario S2 of phase 5 is
off-limits here).

## Exercise 1 — read `cilium-dbg service list` for catalog on both clusters

```bash
for ctx in kind-poc1 kind-poc2; do
  cip=$(kubectl --context "$ctx" -n shop-core get svc catalog -o jsonpath='{.spec.clusterIP}')
  echo "== $ctx catalog $cip"
  kubectl --context "$ctx" -n kube-system exec ds/cilium -c cilium-agent -- \
    cilium-dbg service list | grep -A8 "$cip"
done
```

*Expect:* each cluster's eBPF table lists the **local** catalog pod. Remote backends in the
other cluster's pod CIDR (`10.10.x` is poc1, `10.20.x` is poc2 — the same reading as demo 07)
are the proof the Service is global — **but** on Cilium 1.20.2 they are omitted from
`cilium-dbg service list` while `affinity: local` is set and a local backend is healthy.
They appeared the moment the affinity annotation was removed (measured 2026-09-18), and
vanished again when it was restored. `cilium-dbg bpf lb list` has no affinity column; the
flags read `[ClusterIP, non-routable]`. Hubble's `destination.cluster_name` is how you would
see a remote pick; that measurement is phase 5.

## Exercise 2 — hit the three doors and read `X-Served-By`

```bash
curl -sk --resolve api.shop.poc.local:443:172.18.255.16 https://api.shop.poc.local/ -D - -o /dev/null
curl -sk --resolve api.poc1.shop.poc.local:443:172.18.255.242 https://api.poc1.shop.poc.local/ -D - -o /dev/null
curl -sk --resolve api.poc2.shop.poc.local:443:172.18.255.177 https://api.poc2.shop.poc.local/ -D - -o /dev/null
```

*Expect:* all three 200. The VIP's `X-Served-By` equals whoever `scripts/vip-takeover.sh
--status` names (poc1 in this phase). `.242` is `poc1`, `.177` is `poc2`. The header is set
by the Gateway in the cluster the request entered — it names the door, not whether
api-gateway's upstream was local or remote.

## Exercise 3 — compare a generated policy's selectors between the two clusters

```bash
python3 - <<'PY'
import yaml
for cluster in ("poc1", "poc2"):
    path = f"demos/41-shop-mesh-phase1/policies/{cluster}/cnp-shop-intent.yaml"
    print(f"== {path}")
    for d in yaml.safe_load_all(open(path)):
        if not d: continue
        print(f"  {d['metadata']['namespace']}/{d['metadata']['name']}: {d['spec'].get('description','')}")
        for rule in (d["spec"].get("ingress") or []):
            for ep in rule.get("fromEndpoints") or []:
                print("   ", ep.get("matchLabels"))
            for ent in rule.get("fromEntities") or []:
                print("    fromEntities:", ent)
PY
```

*Expect:* the same six (or seven, with backend) subjects on both sides. A selector **without**
`io.cilium.k8s.policy.cluster` matches the local cluster only (Cilium 1.19+). A selector that
names the cluster was copied from a flow whose source cluster differed; phase 1 does not
produce those cross-cluster flows (that is S2 of phase 5). If poc2 has no cf2cnp, its file
is poc1's YAML applied after that review — the README's "What was measured" records which
it was.

## Cleanup

`demos/41-shop-mesh-phase1/cleanup.sh` — routes, policies, the platform in both clusters;
demo 40's doors stay.
