# Certificates: Compose today, Kubernetes later

The lab runs on Compose, where cert-manager does not run, so `scripts/gen-certs.sh` creates
the CA and every certificate. This page records what the script produces, which cert-manager
objects replace it on Kubernetes, and what still has to be done when the lab moves there.

## Today: what `gen-certs.sh` creates

```bash
demos/57-sni-fabric-lab/scripts/gen-certs.sh
```

It writes `certs/` (ignored by git): a root CA in `certs/ca/`, and one folder per component
holding `tls.crt`, `tls.key` and `ca.crt`.

| Component | Folder | DNS names | Extended key usage |
|---|---|---|---|
| `web` | `certs/web/` | `web.fabric.localtest.me` | server |
| `orders-api` | `certs/orders-api/` | `api.fabric.localtest.me` | server |
| `tcp-svc` | `certs/tcp-svc/` | `tcp.fabric.localtest.me` | server |
| `mq` | `certs/mq/` | `qm1.fabric.localtest.me`, `mqconsole.fabric.localtest.me` | server, client |
| `mq-client` | `certs/mq-client/` (also `tls.p12`) | `mq-client.fabric.localtest.me` | client |

Choices that keep the move to Kubernetes small:

- **File names.** `tls.crt`, `tls.key` and `ca.crt` are the keys of the Secret a cert-manager
  `Certificate` creates, and the files the IBM MQ container reads from
  `/etc/mqm/pki/keys/<label>/`. A folder today becomes a Secret later, unchanged.
- **Key format.** RSA keys in PKCS#1 (`BEGIN RSA PRIVATE KEY`), cert-manager's default
  encoding.
- **`tls.crt` holds only the component's certificate**, not the CA, as cert-manager does.
- **Permissions.** Keys are `600`, certificates `644`.
- **PKCS#12 for the MQ client.** The IBM MQ image has no `openssl`, so the client cannot
  build its keystore from PEM. `mq-client/tls.p12` (password `fabric-lab`, mode `600`) is
  imported with `runmqakm`. OpenSSL 4's default format (PBES2, PBKDF2-HMAC-SHA-256,
  AES-256-CBC) was measured to import into GSKit.

Re-running the script keeps the CA and reissues a component's certificate only when it is
missing, not signed by the current CA, has different names, has a key that does not match,
or expires within 30 days. `--force` regenerates everything.

## Kubernetes: what replaces the script

`k8s/cert-manager/certificates.yaml` holds the equivalent objects:

| Script step | cert-manager object |
|---|---|
| Create the root CA | `ClusterIssuer/fabric-selfsigned-bootstrap` signs `Certificate/fabric-root-ca` (`isCA: true`, Secret `fabric-root-ca` in `cert-manager`) |
| Sign with the CA | `ClusterIssuer/fabric-ca` (`ca.secretName: fabric-root-ca`) |
| One folder per component | One `Certificate` per component in namespace `fabric`; Secret `<component>-tls` with the same names and usages |
| Copy `ca.crt` beside each certificate | trust-manager `Bundle/fabric-ca-bundle` copies the CA certificate into ConfigMap `fabric-ca-bundle` (key `ca.crt`) in every namespace labelled `fabric.localtest.me/trust=ca` |
| Re-run before expiry | cert-manager renews on its own |

A `ClusterIssuer` reads its CA Secret from cert-manager's cluster resource namespace, and
trust-manager reads its sources from its trust namespace. Both default to `cert-manager`,
which is why the root CA's Secret lives there.

## To do when the lab moves to Kubernetes

1. **Install cert-manager**, and trust-manager if clients or Envoy need the CA as a
   ConfigMap. On OpenShift, use the cert-manager Operator for Red Hat OpenShift. The objects
   were checked against cert-manager v1.21.2 and trust-manager v0.25.0.
2. **Choose the CA.** For a lab, apply the manifests as they are. For anything shared, replace
   the bootstrap issuer, the root CA and `fabric-ca` with an issuer for the organisation's own
   CA. The component `Certificate` objects stay the same apart from `issuerRef`.
3. **Replace the domain.** Change `fabric.localtest.me` to the real wildcard domain in every
   `dnsNames` entry, and in Envoy's `server_names`.
4. **Create the namespace and apply the objects.**

   ```bash
   kubectl create namespace fabric
   kubectl label namespace fabric fabric.localtest.me/trust=ca
   kubectl apply -f demos/57-sni-fabric-lab/k8s/cert-manager/certificates.yaml
   kubectl get certificate -n fabric
   ```

   Expect every `Certificate` to show `READY True`.
5. **Mount each Secret where its component reads it.**

   | Component | Secret | Mount |
   |---|---|---|
   | `mq` | `mq-tls` | `/etc/mqm/pki/keys/<label>/` (the MQ container's documented location) |
   | `web`, `orders-api`, `tcp-svc` | `<component>-tls` | The path each server's TLS settings name; fixed when the lab is built |
   | `mq-client` | `mq-client-tls` | Its `keystore.p12` (from `keystores.pkcs12`, profile `Modern2023`) is what the client imports; the script reads `tls.p12` today, so point it at `keystore.p12` |
   | Envoy `edge_sni` | none | TLS passes through Envoy, so it holds no certificate |
   | Envoy `mesh_http` | ConfigMap `fabric-ca-bundle` | The CA it checks the MQ web server against when it opens TLS to it |

6. **Pick up renewals.** By default cert-manager issues for 90 days, renews when a third of the
   lifetime remains, and creates a new key on each renewal (`rotationPolicy: Always`, the
   default since v1.18). The Secret changes, but each process must load the new files. How
   each component does that (MQ, nginx, the Python services) is an open item, to be
   measured when the lab is built.
7. **Protect the CA key.** On Kubernetes the root CA's private key is the Secret
   `cert-manager/fabric-root-ca`. Limit who can read Secrets in that namespace, or use the
   organisation's CA (step 2) so no CA key lives in the cluster.

## Differences between the script and cert-manager

| | `gen-certs.sh` | cert-manager, as configured |
|---|---|---|
| Certificate lifetime | 397 days | 90 days (default; set `duration` to change it) |
| Renewal | When the script is re-run and 30 days or less remain | Automatic, when a third of the lifetime remains |
| New key on renewal | Yes | Yes (`rotationPolicy: Always`) |
| Key | RSA 2048, PKCS#1 | RSA 2048, PKCS#1 |
| CA key | `certs/ca/ca.key` on this Mac | Secret `cert-manager/fabric-root-ca` |

## How this was checked

**The script**, run on macOS with OpenSSL 4.0.3 and with macOS's own bash 3.2:

| Test | Result |
|---|---|
| First run | CA and five certificates created; every chain `ok` |
| Second run | Everything kept; the `web` fingerprint unchanged |
| `certs/tcp-svc/tls.crt` deleted | Only `tcp-svc` reissued (`missing`) |
| Another component's key copied over `web`'s | `web` reissued (`key does not match`) |
| `OPENSSL=/usr/bin/openssl` (LibreSSL 3.3.6) | Refused with exit 1 and the reason |
| TLS handshake to a server using `web`'s certificate, checked against `ca.crt` | `Verify return code: 0 (ok)`; with the wrong hostname, `62 (hostname mismatch)` |

**The manifests** were not applied to a cluster. Each object was validated against the
`openAPIV3Schema` of its CRD from cert-manager v1.21.2 and trust-manager v0.25.0:

```text
valid     ClusterIssuer/fabric-selfsigned-bootstrap
valid     Certificate/fabric-root-ca
valid     ClusterIssuer/fabric-ca
valid     Certificate/web
valid     Certificate/orders-api
valid     Certificate/tcp-svc
valid     Certificate/mq
valid     Certificate/mq-client
valid     Bundle/fabric-ca-bundle
```

As a control, a copy with `usages: [server-auth]` and `encoding: PEM` failed, for example:
`spec/privateKey/encoding: 'PEM' is not one of ['PKCS1', 'PKCS8']`. A schema check does not
prove the objects work together; applying them to a cluster does.

## Sources

- IBM MQ container, [usage.md](https://github.com/ibm-messaging/mq-container/blob/master/docs/usage.md):
  `/etc/mqm/pki/keys/<Label>` with `tls.key`, `tls.crt` and `ca.crt`.
- cert-manager, [`types_certificate.go`](https://github.com/cert-manager/cert-manager/blob/master/pkg/apis/certmanager/v1/types_certificate.go):
  `duration` defaults to 90 days, `renewBefore` to a third of the lifetime, `encoding` to
  `PKCS1`, and `rotationPolicy` to `Always` from v1.18.0; `keystores.pkcs12` writes
  `keystore.p12`, and its `Modern2023` profile uses PBES2 with PBKDF2-HMAC-SHA-256 and
  AES-256-CBC.
- cert-manager, [Certificate resource](https://cert-manager.io/docs/usage/certificate/):
  the Secret's `tls.crt`, `tls.key` and `ca.crt`.
- cert-manager, [SelfSigned issuer](https://cert-manager.io/docs/configuration/selfsigned/):
  bootstrapping a CA issuer.
- cert-manager, [Configuration](https://cert-manager.io/docs/configuration/): the cluster
  resource namespace, `cert-manager` by default.
- trust-manager, [README](https://cert-manager.io/docs/trust/trust-manager/) and its chart's
  [`values.yaml`](https://github.com/cert-manager/trust-manager/blob/v0.25.0/deploy/charts/trust-manager/values.yaml):
  `Bundle` sources and targets; the trust namespace, `cert-manager` by default.
