# Demo 31 — the guide: exercises

Run from the repo root with poc1 up, demo 26's lab in place (`cf2cnp-lab`: `pos` calls `shop` and
`https://example.com` every 5 s) and demo 25's cf2cnp behind the Gateway. Exercise 0 reads; 1 and 2 write one
policy into `cf2cnp-lab`.

## Exercise 0 — a world flow without a name, and the two policies it can make

```bash
demos/31-dns-visibility/egress-flows.sh cf2cnp-lab/pos /tmp/pos.ndjson 300
demos/26-cf2cnp-policy-from-flows/generate.sh /tmp/pos.ndjson /tmp/pos-cidr.yaml
QUERY=dnsVisibility=true demos/26-cf2cnp-policy-from-flows/generate.sh /tmp/pos.ndjson /tmp/pos-dns.yaml
diff /tmp/pos-cidr.yaml /tmp/pos-dns.yaml
```

*Expect:* the world flow line reads `names=-` (unless the demo's policy is still applied — then run
`cleanup.sh` first and wait 10 s). The first policy allows `toCIDR: 104.20.23.154/32`; the diff adds one rule:
kube-dns on `53/UDP` with `rules.dns: [{matchPattern: "*"}]`, and the tool's comment above the CIDR says
why.

## Exercise 1 — turn the proxy on, watch the names arrive (writes: the `pos` policy)

```bash
kubectl --context kind-poc1 apply -f /tmp/pos-dns.yaml
sleep 12; hubble observe -P --kube-context kind-poc1 --from-pod cf2cnp-lab/pos --protocol dns --last 4
demos/31-dns-visibility/egress-flows.sh cf2cnp-lab/pos /tmp/pos-named.ndjson 120
demos/26-cf2cnp-policy-from-flows/generate.sh /tmp/pos-named.ndjson /tmp/pos-fqdn.yaml
grep -n -A1 "toFQDNs\|toCIDR" /tmp/pos-fqdn.yaml
```

*Expect:* `dns-request proxy FORWARDED (DNS Query example.com. A)` lines — and the search-list expansions
(`example.com.svc.cluster.local.` …) that resolvers try first; then `names=['example.com']` on the world flow;
then `toFQDNs: [{matchName: example.com}]` in the regenerated policy, no CIDR. Same flows, same tool, no
option: the name was simply there this time.

## Exercise 2 — enforce, and try a name that was never observed (writes: the same policy)

```bash
kubectl --context kind-poc1 apply -f /tmp/pos-fqdn.yaml
kubectl --context kind-poc1 -n cf2cnp-lab exec pos -- sh -c 'wget -S -qO- --timeout=5 https://example.com/ 2>&1 | grep -m1 HTTP/'
kubectl --context kind-poc1 -n cf2cnp-lab exec pos -- sh -c 'wget -S -qO- --timeout=5 https://cilium.io/ 2>&1 | grep -m1 HTTP/; echo rc=$?'
hubble observe -P --kube-context kind-poc1 --from-pod cf2cnp-lab/pos --verdict DROPPED --last 2
```

*Expect:* `200 OK` for example.com; nothing but `rc=1` for cilium.io, whose SYN to its IP is
`Policy denied DROPPED` — and the JSON of that drop carries `destination_names: ["cilium.io"]`: the lookup was
allowed (`matchPattern: "*"`), the connection was not (`toFQDNs` lists one name). Narrow the DNS rule to
`matchName: example.com` if the lookup itself must be refused.

## Exercise 3 — the dashboard

`https://grafana.poc.local/d/_f0DUpY4k/hubble-dns-overview-namespace?var-cluster=poc1&var-source_namespace=cf2cnp-lab`

*Expect:* empty before Exercise 1 (no proxy, no `hubble_dns_*` for this namespace), then queries per name and
type — the search-list expansions included, which is what the review decided to keep as observed.

## Cleanup

`demos/31-dns-visibility/cleanup.sh` — deletes the `pos` policy; demo 26's lab stays.
