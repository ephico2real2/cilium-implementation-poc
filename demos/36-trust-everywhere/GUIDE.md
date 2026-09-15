# Demo 36 — the guide: exercises

Run from the repo root with poc1 and poc2 up on route A (cert-manager's root: `scripts/lab-up.sh poc1 poc2`, or
SETUP Step 9.3a) and demo 09's Gateway (`scripts/lab-stack.sh routes`). Exercise 0 reads; 1 writes to THIS host's
trust store (a `sudo` prompt); 2 writes to both clusters; 3 needs demo 11's client pod; 4 is the CI job.

## Exercise 0 — read the chain before trusting anything

```bash
kubectl --context kind-poc1 get clusterissuer ca-issuer -o jsonpath='{.spec.ca.secretName}{"\n"}'
kubectl --context kind-poc1 -n cert-manager get secret clustermesh-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -fingerprint -sha256
kubectl --context kind-poc1 -n routes get secret wildcard-poc-local-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -ext subjectAltName
kubectl --context kind-poc2 -n cert-manager get secret clustermesh-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -fingerprint -sha256
```

*Expect:* the issuer signs with `clustermesh-root-ca`; the root is self-signed (`subject` = `issuer` =
`CN=clustermesh-root-ca`); the wildcard's issuer is that CN and its SAN is `*.poc.local`; poc2's copy of the root has
the same fingerprint (the mesh exercise copied it). One CA, three uses.

## Exercise 1 — this host (writes: the trust store)

```bash
scripts/lab-trust.sh export kind-poc1          # the certificate only → .tmp/root-ca.crt
scripts/lab-trust.sh install kind-poc1         # Ubuntu: update-ca-certificates; macOS: the System keychain (password)
scripts/lab-trust.sh prove 172.18.255.240      # a curl by name, NO --cacert
curl -s --resolve grafana.poc.local:443:172.18.255.240 https://grafana.poc.local/login -o /dev/null -w '%{http_code} %{ssl_verify_result}\n'
```

*Expect:* `1 added` (Ubuntu) or the keychain prompt; `openssl verify … OK` / `security verify-cert: OK`; then
`http 404, ssl_verify_result 0` from the wildcard listener for a name with no route, and `200 0` from Grafana — no
flag anywhere. On a Mac, `open https://grafana.poc.local` now shows a padlock (Step 3.5's route and `/etc/hosts`
as in demo 09).

## Exercise 2 — both clusters (writes: trust-manager, the Bundle)

```bash
scripts/lab-trust.sh bundle kind-poc1 kind-poc2
kubectl --context kind-poc1 get bundle enterprise-root -o wide
kubectl --context kind-poc1 get cm -A --field-selector metadata.name=enterprise-root | head
kubectl --context kind-poc2 -n bank get cm enterprise-root -o jsonpath='{.data.ca\.crt}' | openssl x509 -noout -fingerprint -sha256
kubectl --context kind-poc1 create namespace trust-probe; sleep 3; kubectl --context kind-poc1 -n trust-probe get cm enterprise-root; kubectl --context kind-poc1 delete namespace trust-probe --wait=false
```

*Expect:* `Synced True`; one `enterprise-root` ConfigMap per namespace, in both clusters, with Exercise 0's
fingerprint; a namespace created afterwards gets its ConfigMap within seconds — the reason it is a controller and
not a copy.

## Exercise 3 — a pod (needs demo 11's client: `scripts/lab-apps.sh forensic`, or the rig)

```bash
kubectl --context kind-poc1 -n forensic exec client -- ls -l /etc/enterprise-root/
scripts/lab-trust.sh pod-check kind-poc1 forensic client 172.18.255.240 bank.poc.local
kubectl --context kind-poc1 -n forensic exec client -- sh -c 'SSL_CERT_FILE=/etc/enterprise-root/ca.crt curl -s -o /dev/null -w "%{http_code}\n" --resolve grafana.poc.local:443:172.18.255.240 https://grafana.poc.local/login'
```

*Expect:* `ca.crt` mounted; `with the mounted root: 200 rc=0`, `with nothing: 000 rc=60` (curl 60: the peer
certificate cannot be authenticated — the image's bundle does not know this root, which is the point); and `200`
with `SSL_CERT_FILE` set and no flag on the command.

## Exercise 4 — the CI job

`.github/workflows/lab-observability.yaml` runs `scripts/lab-up.sh` with `LAB_TRUST_ROOT=1`, so the runner's OS
store gets the root in the same step that copies it to poc2; it exports `ROOT_CA=/etc/ssl/certs/ca-certificates.crt`
for every later check; `scripts/lab-stack.sh routes` proves the chain by name; the report carries this demo's
`check.sh` (the chain, the host, both Bundles, the pod's two curls).

*Expect:* on the run page, `the OS store trusts the root`, `curl by name with no --cacert → http 404,
ssl_verify_result 0`, `Bundle enterprise-root Synced=True; ConfigMap enterprise-root in N of N namespaces; distinct
fingerprints: 1` for both clusters, and the pod's `200` / `rc=60` pair.

## Cleanup

```bash
demos/36-trust-everywhere/cleanup.sh
```

Removes the Bundle and trust-manager from both clusters and the root from this host's store; demo 08's issuer stays.
