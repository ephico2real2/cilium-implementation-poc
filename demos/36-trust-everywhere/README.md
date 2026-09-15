# Demo 36 — one root, everywhere: the enterprise root in the trust stores and in the pods

Demo 08 made one root in cert-manager and copied it into every cluster of the mesh; demo 09 hung a wildcard
certificate signed by that root on the Gateway. Then every client in this repository carried the root as a
flag: `curl --cacert docs/root-ca.crt …` in ten scripts, `ROOT_CA=` in the lab's, and a pod that wanted to call
`https://bank.poc.local` had nothing to verify against at all. This demo is the design exercise the operator asked
for on 2026-09-15: **the root goes where the clients live** — the MacBook's keychain, the Ubuntu host the CI job
runs on, and every namespace of every cluster so a pod can mount it — in the same exercise that copies it between
the clusters, and the `--cacert` flags become what they should have been, the OS bundle.

## Part 1 — the fact first: which CA signs the Gateway

The question that started this ("is it the CA that signed the Gateway we need, not the one that joined the
cluster?") has one answer in the files, and it is the same CA:

| Object | File | What it is |
|---|---|---|
| Certificate `clustermesh-root-ca`, `isCA: true`, self-signed → Secret `clustermesh-root-ca` in `cert-manager` | `demos/08-certmanager-ca/01-root-ca-poc1.yaml` | the root. Its name says what it was made for in demo 08; it has been the one enterprise root since |
| ClusterIssuer `ca-issuer`, `ca.secretName: clustermesh-root-ca` | same file | the signer every Certificate in this repository names |
| Gateway `routes-gw`, annotation `cert-manager.io/cluster-issuer: ca-issuer` → Certificate `wildcard-poc-local-tls` | `demos/09-routes/01-gateway.yaml` | the wildcard `*.poc.local`, created by cert-manager's gateway shim, signed by the root |
| the mesh apiserver certificates (route A, demo 24), the relay's and the CLI's mTLS certificates (demo 25) | `cilium/values-ci-certmanager.yaml`, demo 25's Certificates | leaf certificates from the same issuer |

So the Gateway's certificates were cert-manager's all along, and nothing "moves" to cert-manager. What a client
must trust is the **root** — never one of the leaves, and in particular not the mesh's own certificates, which
are what "joined the cluster". The Secret holds the root's private key too, which is why a pod never mounts the
Secret: only `tls.crt` leaves it, and only as a ConfigMap.

The lab prints the chain on every run so this stays a measurement, not a belief (`scripts/lab-stack.sh routes`):

```text
routes-gw 172.18.255.240, certificate wildcard-poc-local-tls Ready
  the wildcard's chain: issuer=CN=clustermesh-root-ca subject=CN=*.poc.local
```

## Part 2 — the design: three trust points, one mechanism each

| Where the client runs | What trusts the root | How it gets there | The proof |
|---|---|---|---|
| the MacBook | the System keychain | `scripts/lab-trust.sh install` — `security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain` (demo 09's command; a password prompt) | `security verify-cert -c .tmp/root-ca.crt`; `open https://grafana.poc.local` shows a padlock |
| the Ubuntu runner (CI) | `/etc/ssl/certs/ca-certificates.crt` | `scripts/lab-up.sh` with `LAB_TRUST_ROOT=1`: `install -m 0644 … /usr/local/share/ca-certificates/cilium-lab-enterprise-root.crt` then `update-ca-certificates` | `openssl verify -CApath /etc/ssl/certs .tmp/root-ca.crt`; then a curl **by name with no `--cacert`** to the wildcard listener, `ssl_verify_result` 0 |
| a pod, in any namespace, in any cluster | ConfigMap `enterprise-root`, key `ca.crt`, mounted at `/etc/enterprise-root/` | trust-manager's `Bundle` (`20-bundle.yaml`): source = the Secret's `tls.crt` in the trust namespace, target = a ConfigMap in every namespace | `curl --cacert /etc/enterprise-root/ca.crt https://bank.poc.local/` answers; the same curl without it exits 60 |

Why trust-manager and not a copy of the ConfigMap per namespace: a namespace created after the copy (every lab
namespace is) would have nothing, and a rotated root would have to be re-copied everywhere; the Bundle is
reconciled — new namespaces get the ConfigMap, a new certificate in the Secret reaches every copy. Why a ConfigMap
and not the Secret: the Secret carries the key. trust-manager reads sources only from its trust namespace
(`cert-manager`, where demo 08 put the Secret) and needs cert-manager for its own webhook certificate, which is
why it lands in `scripts/lab-up.sh`'s root step, right after the issuer is Ready and — in the mesh exercise — right
after the root was copied to the other cluster.

For a process that must not know about any of this, the mount plus one environment variable is enough:
`SSL_CERT_FILE=/etc/enterprise-root/ca.crt` makes every OpenSSL- and curl-based client verify against the root.
Demo 11's client pod (the rig's `client`, what demo 15's in-cluster check runs from) mounts the ConfigMap with
`optional: true`, so the same file still schedules on a cluster without the Bundle (poc3, kindnet).

## Part 3 — what the lab does with it

- `scripts/lab-trust.sh`: `export` (the certificate to `.tmp/root-ca.crt`), `install` / `verify` (this host),
  `prove <gateway-ip>` (the curl by name), `bundle <ctx>…` (trust-manager + the Bundle), `pod-check` (from inside a
  pod, with and without the mounted root).
- `scripts/lab-up.sh`, route A, the root step: `bundle` on every cluster; on the first cluster `export`, and `install`
  when `LAB_TRUST_ROOT=1` (the CI job sets it; on a Mac it is your call, because it prompts for your password).
- `scripts/lab-stack.sh routes`: prints the wildcard's chain and, when the host trusts the root, proves it by name.
- the CI job exports `ROOT_CA=/etc/ssl/certs/ca-certificates.crt` after the bring-up: every demo check that reads
  `ROOT_CA` verifies against the OS bundle from then on.
- `check.sh` is the report's section for this demo: the chain, the host, both clusters' Bundles, the pod.

## Gotchas met here

- `--cacert` wins over the OS store: a script that passes it verifies against that file only, whatever the host
  trusts. That is why the lab points `ROOT_CA` at the OS bundle instead of removing the flags one by one.
- Chromium on Linux does not read `/etc/ssl/certs`; it keeps its own NSS store. The captures keep
  `ignoreHTTPSErrors` — the browser's trust is a separate exercise (`certutil -d sql:$HOME/.pki/nssdb`).
- The trust namespace must exist before trust-manager is installed (it does: cert-manager's), and the Bundle's
  secret source must live there.

## Evidence

Measured on the CI job (enhancement 004): the chain line, `1 added` from `update-ca-certificates`, `openssl verify:
OK`, the curl by name with `ssl_verify_result 0`, the Bundle `Synced` on both clusters with the ConfigMap in every
namespace and one fingerprint, and the pod's two curls — see the run recorded in `enhancements/004-lab-in-ci.md`
§2.1 and the report on that run's page.
