# Demo 24 — the guide: exercises

Run from the repo root. Each exercise: the command, why, what to expect.

## Exercise 1 — prove one trust anchor

```bash
for c in kind-poc1 kind-poc2; do kubectl --context $c -n cert-manager get secret clustermesh-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -fingerprint -sha256; done
demos/24-clustermesh-enterprise/check.sh
```

*Expect:* identical fingerprints; every Certificate `Ready` with a `RENEWS` date; every leaf
`issuer=CN=clustermesh-root-ca`; `Connected Nodes: 7/7`.

## Exercise 2 — watch renewal happen (what the Helm method never does)

```bash
kubectl --context kind-poc2 -n kube-system delete secret hubble-server-certs
sleep 10; kubectl --context kind-poc2 -n kube-system get certificate hubble-server-certs
kubectl --context kind-poc2 -n kube-system get secret hubble-server-certs -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates
```

*Why:* cert-manager reconciles the Secret from the Certificate; deleting the Secret is the fastest
stand-in for expiry. *Expect:* a new Secret within seconds, `notBefore` now, `Ready: True`; Hubble on
poc2 keeps running (certificates hot-reload) and poc1's relay stays at 7/7. With the Helm method the
Secret would simply be gone until the next `helm upgrade` (gotcha #21).

## Exercise 3 — break trust on purpose

Create a second self-signed root in poc2, point a `ClusterIssuer/ca-issuer-2` at it, patch
`hubble-server-certs`'s Certificate to that issuer, wait for reissue.
*Expect:* poc1's relay drops to 5/7 with the exact `x509: certificate signed by unknown authority`
of gotcha #71, within its retry interval. Patch back; 7/7 returns. This is the whole demo in reverse.

## Exercise 4 — the outage of Part 3, reproduced on purpose (a window!)

```bash
kubectl --context kind-poc1 -n kube-system rollout restart deploy/clustermesh-apiserver
while true; do printf "%s %s\n" "$(date -u +%H:%M:%S)" "$(curl -sk --max-time 3 -o /dev/null -w '%{http_code}' https://bank.poc.local/api/balance/chk-1001)"; sleep 1; done
```

*Expect:* `000` for a minute or more while the agents re-list poc2 through the new etcd; watch
`cilium_clustermesh_remote_cluster_readiness_status` in Grafana (Cilium folder) dip from 5.
*Why it matters:* KVStoreMesh's cache is ephemeral by design (demo 08); its restart is a mesh event.

## Exercise 5 — the declarative form is idempotent

Re-run the Step 4 `helm upgrade` for both clusters. *Expect:* `REVISION` +1, nothing rendered
differently (`helm diff` if installed, or compare `helm get manifest` before/after), no pod replaced,
no probe failure — the outage of Part 3 was the *first* application of the local-cluster entry, not
the files themselves.
