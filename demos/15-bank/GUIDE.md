# Demo 15 — the junior guide: every manifest, every command, and why

The README explains the results; this file is the walk. Each step is **the command**, **why**
(one line), and **what to expect**. Manifests are shown in full, straight from the files, so
this page cannot drift from what is applied. Run from the repo root. Prerequisites: poc1 and
poc2 built per `docs/SETUP.md` Steps 0–9 (ClusterMesh connected), the demo 09 Gateway (Step 8 /
demo 09), Go 1.25+, Docker.

---

## 1. Build the one image and load it into BOTH clusters

```bash
docker build -t bankdemo:local -f demos/15-bank/app/Containerfile demos/15-bank/app
```
*Why:* one static Go binary plays all four roles (`-mode web|api|payments|accounts`); one image means
"which role runs where" is the only variable in the demo. `golang:1.25` because `pgx` v5.11 needs
Go ≥ 1.25 (a 1.24 builder fails at `go mod download` — gotcha kept in the transcript).

```bash
kind load docker-image bankdemo:local --name poc1
kind load docker-image bankdemo:local --name poc2
```
*Why:* no registry in this lab; `kind load` copies the image into every node's containerd. Pods use
`imagePullPolicy: IfNotPresent`, so a rebuilt image needs a `kind load` **and** a rollout restart.
*Expect:* `Image: "bankdemo:local" … loading…` once per node (5 lines for poc1, 2 for poc2).

## 2. poc2 first — the system of record (Postgres on a PVC, accounts, one payments replica)

```yaml
# demos/15-bank/10-poc2.yaml
# poc2 — the SYSTEM OF RECORD side: Postgres on a PVC, the accounts service, and one replica of the
# shared payments service.
#
#   kubectl --context kind-poc2 apply -f demos/15-bank/10-poc2.yaml
#
# Global Services (service.cilium.io/global: "true") merge ENDPOINTS across the mesh; they do not
# copy Service objects. So every global Service here is defined again, name-for-name, in 20-poc1.yaml
# (demo 07 learned that the hard way). `redis` is global too: payments in THIS cluster needs the
# redis that runs only in poc1.
apiVersion: v1
kind: Namespace
metadata: {name: bank}
---
apiVersion: v1
kind: Secret
metadata: {name: postgres, namespace: bank}
stringData: {POSTGRES_USER: bank, POSTGRES_PASSWORD: bank, POSTGRES_DB: bank}
---
apiVersion: v1
kind: Service
metadata: {name: postgres, namespace: bank}
spec:
  clusterIP: None                     # headless: one pod, stable DNS, no load balancing wanted
  selector: {app: postgres}
  ports: [{port: 5432}]
---
# Cross-cluster replication (demo 15 Part 8). The STANDBY in poc1 streams WAL from this primary
# through the mesh, so both Services are global and defined in both clusters: `postgres-primary`
# has backends only here, `postgres-standby` only in poc1.
apiVersion: v1
kind: Service
metadata:
  name: postgres-primary
  namespace: bank
  annotations: {service.cilium.io/global: "true"}
spec:
  selector: {app: postgres}
  ports: [{port: 5432}]
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-standby
  namespace: bank
  annotations: {service.cilium.io/global: "true"}     # backends in poc1 only
spec:
  selector: {app: postgres-standby}
  ports: [{port: 5432}]
---
# Runs ONCE, at first initdb, on a fresh volume: the replication role, a physical slot (so WAL is
# kept while the standby is away — wal_keep_size is 0 by default), and the pg_hba line the image
# does not write. On the already-running primary the same three steps were applied by hand and are
# in the transcript.
apiVersion: v1
kind: ConfigMap
metadata: {name: postgres-init, namespace: bank}
data:
  10-replication.sh: |
    #!/bin/sh
    set -e
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator'" -c "SELECT pg_create_physical_replication_slot('standby_poc1')"
    echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: postgres, namespace: bank}
spec:
  serviceName: postgres
  replicas: 1
  selector: {matchLabels: {app: postgres}}
  template:
    metadata: {labels: {app: postgres}}
    spec:
      # Symmetric bootstrap (Part 8 failback). Empty volume + BOOTSTRAP_FROM unset -> the image runs
      # initdb and this is a PRIMARY (fresh install). Empty volume + BOOTSTRAP_FROM=<host> -> base
      # backup from that host and this comes up as a STANDBY of it. After a promotion in poc1 the old
      # primary is rebuilt this way; roles are decided by data, never by which cluster a pod is in.
      initContainers:
        - name: bootstrap
          image: postgres:16-alpine
          env:
            - {name: PGPASSWORD, value: replicator}
            - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}
            - {name: BOOTSTRAP_FROM, value: ""}
          command: ["sh", "-c"]
          args:
            - |
              set -e
              if [ -s "$PGDATA/PG_VERSION" ]; then echo "data present: role decided by standby.signal ($(test -f $PGDATA/standby.signal && echo standby || echo primary))"; exit 0; fi
              if [ -z "$BOOTSTRAP_FROM" ]; then echo "empty volume, no BOOTSTRAP_FROM: the image will initdb a new PRIMARY"; exit 0; fi
              echo "empty volume: base backup from $BOOTSTRAP_FROM -> this pod becomes a STANDBY of it"
              until pg_isready -h "$BOOTSTRAP_FROM" -U replicator; do sleep 2; done
              pg_basebackup -h "$BOOTSTRAP_FROM" -U replicator -D "$PGDATA" -Fp -Xs -P -R --slot=standby_poc2 --create-slot
              chmod 700 "$PGDATA"
          volumeMounts: [{name: data, mountPath: /var/lib/postgresql/data}]
      containers:
        - name: postgres
          image: postgres:16-alpine
          envFrom: [{secretRef: {name: postgres}}]
          env: [{name: PGDATA, value: /var/lib/postgresql/data/pgdata}]
          ports: [{containerPort: 5432}]
          volumeMounts:
            - {name: data, mountPath: /var/lib/postgresql/data}
            - {name: init, mountPath: /docker-entrypoint-initdb.d}
          readinessProbe: {exec: {command: [pg_isready, -U, bank]}, periodSeconds: 5}
      volumes: [{name: init, configMap: {name: postgres-init, defaultMode: 0755}}]
  volumeClaimTemplates:
    - metadata: {name: data}
      spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}   # StorageClass "standard" (kind's local-path), WaitForFirstConsumer
---
apiVersion: v1
kind: Service
metadata:
  name: accounts
  namespace: bank
  annotations: {service.cilium.io/global: "true"}     # backends exist ONLY here; poc1 has the Service object alone
spec:
  selector: {app: accounts}
  ports: [{port: 80, targetPort: 8080}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: accounts, namespace: bank}
spec:
  replicas: 2
  selector: {matchLabels: {app: accounts}}
  template:
    metadata: {labels: {app: accounts}}
    spec:
      terminationGracePeriodSeconds: 20   # > the app's 4 s endpoint-withdrawal wait + 10 s drain
      containers:
        - name: accounts
          image: bankdemo:local
          imagePullPolicy: IfNotPresent
          args: ["-mode", "accounts"]
          env:
            - {name: CLUSTER, value: poc2}
            - {name: POD_NAME, valueFrom: {fieldRef: {fieldPath: metadata.name}}}
            - {name: NODE_NAME, valueFrom: {fieldRef: {fieldPath: spec.nodeName}}}
            # writes and first-choice reads go to the PRIMARY through its global Service; reads fall back
            # to the STANDBY (poc1, through the mesh) when the primary does not answer (Part 8)
            - {name: PG_DSN, value: "postgres://bank:bank@postgres-primary.bank.svc.cluster.local:5432/bank?sslmode=disable"}
            - {name: PG_STANDBY_DSN, value: "postgres://bank:bank@postgres-standby.bank.svc.cluster.local:5432/bank?sslmode=disable"}
          ports: [{containerPort: 8080}]
          readinessProbe: {httpGet: {path: /healthz, port: 8080}, periodSeconds: 2, failureThreshold: 1}   # a draining pod answers 503 and must leave the Service within the 4 s drain
---
apiVersion: v1
kind: Service
metadata:
  name: payments
  namespace: bank
  annotations: {service.cilium.io/global: "true"}     # shared: backends in BOTH clusters, one pool
spec:
  selector: {app: payments}
  ports: [{port: 80, targetPort: 8080}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: payments, namespace: bank}
spec:
  replicas: 1
  selector: {matchLabels: {app: payments}}
  template:
    metadata: {labels: {app: payments}}
    spec:
      terminationGracePeriodSeconds: 20   # > the app's 4 s endpoint-withdrawal wait + 10 s drain
      containers:
        - name: payments
          image: bankdemo:local
          imagePullPolicy: IfNotPresent
          args: ["-mode", "payments"]
          env:
            - {name: CLUSTER, value: poc2}
            - {name: POD_NAME, valueFrom: {fieldRef: {fieldPath: metadata.name}}}
            - {name: NODE_NAME, valueFrom: {fieldRef: {fieldPath: spec.nodeName}}}
          ports: [{containerPort: 8080}]
          readinessProbe: {httpGet: {path: /healthz, port: 8080}, periodSeconds: 2, failureThreshold: 1}   # a draining pod answers 503 and must leave the Service within the 4 s drain
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: bank
  annotations: {service.cilium.io/global: "true"}     # runs ONLY in poc1; this object lets poc2's payments resolve it
spec:
  selector: {app: redis}
  ports: [{port: 6379}]
```

```bash
kubectl --context kind-poc2 apply -f demos/15-bank/10-poc2.yaml
kubectl --context kind-poc2 apply -f demos/15-bank/10-poc2.yaml     # a second time, on purpose
```
*Why twice:* a brand-new namespace's `default` ServiceAccount is created asynchronously; bare Pods
created in the same apply can be refused with `serviceaccount "default" not found` (gotcha #39).
The second apply creates only what the first could not. *Why poc2 before poc1:* `accounts` in poc2
is what poc1's `api` will call; bring the truth up first.

```bash
kubectl --context kind-poc2 -n bank rollout status sts/postgres --timeout=300s
kubectl --context kind-poc2 -n bank rollout status deploy/accounts deploy/payments --timeout=300s
kubectl --context kind-poc2 -n bank get pvc
```
*Why:* Postgres binds its PVC (`standard`, `WaitForFirstConsumer` — bound when the pod schedules)
and runs `initdb` + the `postgres-init` script (replicator role, replication slot, `pg_hba` line);
`accounts` retries its connection until then rather than crash-looping.
*Expect:* `data-postgres-0   Bound   1Gi   standard`.

## 3. poc1 — the customer-facing side (web, api, redis on a PVC, one payments replica) and the Service OBJECTS for poc2's services

```yaml
# demos/15-bank/20-poc1.yaml
# poc1 — the CUSTOMER-FACING side: web and api (local only), redis on a PVC, one replica of the
# shared payments service, and the Service OBJECTS for accounts and postgres-free dependencies
# that live in poc2.
#
#   kubectl --context kind-poc1 apply -f demos/15-bank/20-poc1.yaml
apiVersion: v1
kind: Namespace
metadata: {name: bank}
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: bank
  annotations: {service.cilium.io/global: "true"}     # backends here; poc2's payments reaches it through the mesh
spec:
  selector: {app: redis}
  ports: [{port: 6379}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: redis, namespace: bank}
spec:
  serviceName: redis
  replicas: 1
  selector: {matchLabels: {app: redis}}
  template:
    metadata: {labels: {app: redis}}
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          args: ["--appendonly", "yes", "--dir", "/data"]
          ports: [{containerPort: 6379}]
          volumeMounts: [{name: data, mountPath: /data}]
          readinessProbe: {exec: {command: [redis-cli, ping]}, periodSeconds: 5}
  volumeClaimTemplates:
    - metadata: {name: data}
      spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-primary
  namespace: bank
  annotations: {service.cilium.io/global: "true"}     # backends in poc2 only — the standby below streams from it through the mesh
spec:
  selector: {app: postgres}
  ports: [{port: 5432}]
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-standby
  namespace: bank
  annotations: {service.cilium.io/global: "true"}     # backends HERE; poc2's accounts falls back to it through the mesh
spec:
  selector: {app: postgres-standby}
  ports: [{port: 5432}]
---
apiVersion: v1
kind: Service
metadata:
  name: accounts
  namespace: bank
  annotations: {service.cilium.io/global: "true"}     # NO backends here — every call crosses to poc2
spec:
  selector: {app: accounts}
  ports: [{port: 80, targetPort: 8080}]
---
apiVersion: v1
kind: Service
metadata:
  name: payments
  namespace: bank
  annotations: {service.cilium.io/global: "true"}
spec:
  selector: {app: payments}
  ports: [{port: 80, targetPort: 8080}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: payments, namespace: bank}
spec:
  replicas: 1
  selector: {matchLabels: {app: payments}}
  template:
    metadata: {labels: {app: payments}}
    spec:
      terminationGracePeriodSeconds: 20   # > the app's 4 s endpoint-withdrawal wait + 10 s drain
      containers:
        - name: payments
          image: bankdemo:local
          imagePullPolicy: IfNotPresent
          args: ["-mode", "payments"]
          env:
            - {name: CLUSTER, value: poc1}
            - {name: POD_NAME, valueFrom: {fieldRef: {fieldPath: metadata.name}}}
            - {name: NODE_NAME, valueFrom: {fieldRef: {fieldPath: spec.nodeName}}}
          ports: [{containerPort: 8080}]
          readinessProbe: {httpGet: {path: /healthz, port: 8080}, periodSeconds: 2, failureThreshold: 1}   # a draining pod answers 503 and must leave the Service within the 4 s drain
---
apiVersion: v1
kind: Service
metadata: {name: api, namespace: bank}                 # local only: not global on purpose
spec:
  selector: {app: api}
  ports: [{port: 80, targetPort: 8080}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: api, namespace: bank}
spec:
  replicas: 2
  selector: {matchLabels: {app: api}}
  template:
    metadata: {labels: {app: api}}
    spec:
      terminationGracePeriodSeconds: 20   # > the app's 4 s endpoint-withdrawal wait + 10 s drain
      containers:
        - name: api
          image: bankdemo:local
          imagePullPolicy: IfNotPresent
          args: ["-mode", "api"]
          env:
            - {name: CLUSTER, value: poc1}
            - {name: POD_NAME, valueFrom: {fieldRef: {fieldPath: metadata.name}}}
            - {name: NODE_NAME, valueFrom: {fieldRef: {fieldPath: spec.nodeName}}}
          ports: [{containerPort: 8080}]
          readinessProbe: {httpGet: {path: /healthz, port: 8080}, periodSeconds: 2, failureThreshold: 1}   # a draining pod answers 503 and must leave the Service within the 4 s drain
---
apiVersion: v1
kind: Service
metadata: {name: web, namespace: bank}
spec:
  selector: {app: web}
  ports: [{port: 80, targetPort: 8080}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: web, namespace: bank}
spec:
  replicas: 2
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      terminationGracePeriodSeconds: 20   # > the app's 4 s endpoint-withdrawal wait + 10 s drain
      containers:
        - name: web
          image: bankdemo:local
          imagePullPolicy: IfNotPresent
          args: ["-mode", "web"]
          env:
            - {name: CLUSTER, value: poc1}
            - {name: POD_NAME, valueFrom: {fieldRef: {fieldPath: metadata.name}}}
            - {name: NODE_NAME, valueFrom: {fieldRef: {fieldPath: spec.nodeName}}}
          ports: [{containerPort: 8080}]
          readinessProbe: {httpGet: {path: /healthz, port: 8080}, periodSeconds: 2, failureThreshold: 1}   # a draining pod answers 503 and must leave the Service within the 4 s drain
```

```bash
kubectl --context kind-poc1 apply -f demos/15-bank/20-poc1.yaml
kubectl --context kind-poc1 apply -f demos/15-bank/20-poc1.yaml     # same SA race
kubectl --context kind-poc1 -n bank rollout status sts/redis deploy/payments deploy/api deploy/web --timeout=300s
```
*Why the `accounts`, `postgres-primary`, `postgres-standby` Services exist here with no backends:*
a global Service merges **endpoints**, not objects — a client resolves the name through its own
cluster's DNS, so the object must exist locally for the remote endpoints to attach to (demo 07).

```bash
kubectl --context kind-poc1 -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | grep -A2 "$(kubectl --context kind-poc1 -n bank get svc accounts -o jsonpath='{.spec.clusterIP}'):80"
```
*Why:* the proof that the mesh did its job — poc1's eBPF service map lists a backend poc1 never
scheduled. *Expect:* `1 => 10.20.x.x:8080/TCP (active)` — a poc2 pod IP under a poc1 ClusterIP.

## 4. The Gateway: the page and the API from outside

```yaml
# demos/15-bank/30-gateway.yaml
# The bank on the demo 09 Gateway, two names on the wildcard cert:
#   https://bank.poc.local       the online-banking page (web)
#   https://bankapi.poc.local   the API itself, reachable from OUTSIDE the cluster
# HTTPRoutes live in `routes` (where the Gateway is) and point at Services in `bank`, which must
# consent with a ReferenceGrant naming each Service (gotcha #32) — web AND api.
#   kubectl --context kind-poc1 apply -f demos/15-bank/30-gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: bank, namespace: routes}
spec:
  parentRefs: [{name: routes-gw}]
  hostnames: ["bank.poc.local"]
  rules:
    - backendRefs: [{name: web, namespace: bank, port: 80}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: bank-api, namespace: routes}
spec:
  parentRefs: [{name: routes-gw}]
  hostnames: ["bankapi.poc.local"]
  rules:
    - backendRefs: [{name: api, namespace: bank, port: 80}]
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata: {name: allow-routes-to-bank, namespace: bank}
spec:
  from: [{group: gateway.networking.k8s.io, kind: HTTPRoute, namespace: routes}]
  to:
    - {group: "", kind: Service, name: web}
    - {group: "", kind: Service, name: api}
```

```bash
kubectl --context kind-poc1 apply -f demos/15-bank/30-gateway.yaml
kubectl --context kind-poc1 -n routes get httproute bank bank-api
```
*Why the routes live in `routes` and the grant in `bank`:* the Gateway is in `routes`; a route may
point at another namespace's Service only with that namespace's consent — the `ReferenceGrant`
(gotcha #32). *Why `bankapi.poc.local` and not `api.bank.poc.local`:* the wildcard certificate and
listener match exactly one label (gotcha #52). *Expect:* both routes `Accepted=True`, `ResolvedRefs=True`.

```bash
demos/15-bank/hosts-entries.sh
sudo sh -c 'demos/15-bank/hosts-entries.sh >> /etc/hosts'      # your terminal; the script never writes
dscacheutil -flushcache; sudo killall -HUP mDNSResponder
open https://bank.poc.local
```
*Why a separate hosts script:* its own delimited block, added and removed without touching the
demo 09 block; it reads the two routes live so the address is never typed by hand.

## 5. Prove it — the cross-mesh path, active-active, failover

```bash
scripts/record.sh demos/15-bank/output/transcript.txt demos/15-bank/check.sh
```
*Why `record.sh`:* every command and its real output lands in the transcript, so the README quotes
captures, not memory. *What `check.sh` does, in order:* waits until both clusters' maps list both
`payments` backends → one statement call whose body shows `api: poc1, accounts: poc2` → a payment
and its idempotent replay → 40 payments counted per cluster → a 60-second loop while poc1's
`payments` is scaled to 0 and back → the same with `affinity: local` → a probe from poc2 → the page.
*Expect:* `TOTAL ok=… fail=0`, `23/17`-style split, `replay=true` with the balance unchanged.

```bash
demos/15-bank/exercise.sh 20 chk-1001
demos/15-bank/exercise.sh 60 chk-1002 --failover
```
*Why:* the same thing as a watchable table — one line per payment with the cluster/pod of every
hop, a ledger check (`before − after == sum`), declines separated from failures. `--failover`
scales poc1's `payments` to 0 at call 20 and restores it at 40. *Expect:* `FAILED (infrastructure): 0`.

```bash
scripts/record.sh demos/15-bank/output/transcript.txt demos/15-bank/resilience.sh
```
*Why:* three drills judged by responses — `payments` poc1 → 0 statically, an `accounts` pod killed
under a read loop, `postgres-0` and `redis-0` deleted. *Expect:* `DATA SURVIVED the pod`,
`HISTORY SURVIVED`, `replay=True` after the Redis restart.

## 6. The database survives its cluster — a hot standby in poc1 (Part 8)

### 6a. Prepare the primary (already-running primary: by hand; fresh install: the initdb script in `10-poc2.yaml` does it)

```bash
kubectl --context kind-poc2 -n bank exec postgres-0 -- psql -U bank -d bank \
  -c "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator'" \
  -c "SELECT pg_create_physical_replication_slot('standby_poc1')"
```
*Why a role:* replication should not run as the superuser the app uses. *Why a slot:* `wal_keep_size`
is 0 by default, so without a slot the primary may discard WAL the standby has not received yet and
the standby would need a rebuild after any pause.

```bash
kubectl --context kind-poc2 -n bank exec postgres-0 -- sh -c 'echo "host replication replicator all scram-sha-256" >> $PGDATA/pg_hba.conf && psql -U bank -d bank -Atc "SELECT pg_reload_conf()"'
```
*Why:* the image writes `host all all all scram-sha-256` but **not** a `replication` line, so a
remote standby is refused; `pg_reload_conf()` applies it without a restart. Nothing else needed:
`wal_level=replica`, `max_wal_senders=10`, `hot_standby=on` are PostgreSQL 16 defaults — read back
from the live server before assuming.

### 6b. The standby

```yaml
# demos/15-bank/40-postgres-standby-poc1.yaml
# The "replication pod": a Postgres HOT STANDBY in poc1 whose only job is to stream and replay the
# poc2 primary's WAL, continuously, across the mesh — and to be promotable if poc2's database is lost.
#
#   kubectl --context kind-poc1 apply -f demos/15-bank/40-postgres-standby-poc1.yaml
#
# HOW IT BOOTSTRAPS. On an empty volume the init container runs `pg_basebackup` against
# postgres-primary (a global Service; the pod is in poc2) with -R, which writes standby.signal and
# primary_conninfo into PGDATA, and --slot so the primary keeps WAL for us while we are down. The
# main container is the stock image: it finds standby.signal and starts as a streaming standby
# (hot_standby=on is the default, so it answers read-only queries). A later restart skips the
# basebackup because PG_VERSION exists and resumes streaming from the slot.
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: postgres-standby, namespace: bank}
spec:
  serviceName: postgres-standby
  replicas: 1
  selector: {matchLabels: {app: postgres-standby}}
  template:
    metadata: {labels: {app: postgres-standby}}
    spec:
      terminationGracePeriodSeconds: 30
      initContainers:
        - name: basebackup
          image: postgres:16-alpine
          env:
            - {name: PGPASSWORD, value: replicator}
            - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}
          command: ["sh", "-c"]
          args:
            - |
              set -e
              if [ -s "$PGDATA/PG_VERSION" ]; then echo "data present, resuming as standby"; exit 0; fi
              echo "empty volume: base backup from postgres-primary (poc2) through the mesh"
              until pg_isready -h postgres-primary.bank.svc.cluster.local -U replicator; do sleep 2; done
              pg_basebackup -h postgres-primary.bank.svc.cluster.local -U replicator -D "$PGDATA" -Fp -Xs -P -R --slot=standby_poc1
              chmod 700 "$PGDATA"
          volumeMounts: [{name: data, mountPath: /var/lib/postgresql/data}]
      containers:
        - name: postgres
          image: postgres:16-alpine
          env:
            - {name: POSTGRES_PASSWORD, value: bank}      # unused on a standby (no initdb) but the image insists
            - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}
          ports: [{containerPort: 5432}]
          volumeMounts: [{name: data, mountPath: /var/lib/postgresql/data}]
          # Role-agnostic on purpose. The first version required pg_is_in_recovery()=true, so the moment the
          # standby was PROMOTED it went NotReady, left its own Service, and nothing could reach the new
          # primary — the promotion "worked" and every write still failed (Part 8, case 3, first run).
          readinessProbe: {exec: {command: [pg_isready, -U, bank]}, periodSeconds: 5}
  volumeClaimTemplates:
    - metadata: {name: data}
      spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}
```

```bash
kubectl --context kind-poc1 apply -f demos/15-bank/40-postgres-standby-poc1.yaml
kubectl --context kind-poc1 -n bank logs postgres-standby-0 -c basebackup
kubectl --context kind-poc1 -n bank logs postgres-standby-0 -c postgres | grep -E 'standby|streaming|recovery'
```
*Why an init container:* on an empty volume it runs `pg_basebackup … -R --slot` against
`postgres-primary` — a global Service whose pod is in poc2, so the copy crosses the mesh — and `-R`
writes `standby.signal` + `primary_conninfo`; the stock image then simply starts as a standby.
*Expect:* `started streaming WAL from primary at 0/3000000 on timeline 1`.

```bash
kubectl --context kind-poc2 -n bank exec postgres-0 -- psql -U bank -d bank -c "SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication"
kubectl --context kind-poc1 -n bank exec postgres-standby-0 -c postgres -- psql -U bank -d bank -c "SELECT pg_is_in_recovery(), status, sender_host FROM pg_stat_wal_receiver"
```
*Why both sides:* the primary names who is streaming from it (`client_addr` is a **poc1** pod IP);
the standby names whom it follows and that it is in recovery. *Expect:* `streaming | async |
00:00:00.0003` and `t | streaming | postgres-primary.bank.svc.cluster.local`.

### 6c. Point the app at both (already in `10-poc2.yaml`)

```bash
kubectl --context kind-poc2 -n bank get deploy accounts -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | grep PG_
```
*Why two DSNs:* `PG_DSN` (writes and first-choice reads) → `postgres-primary`; `PG_STANDBY_DSN`
(reads only, only when the primary does not answer) → `postgres-standby`. Writes never go to a
standby; promotion is an operator's decision. *Expect:* a balance response carrying `"db": "primary"`.

### 6d. The four test cases

```bash
scripts/record.sh demos/15-bank/output/transcript.txt demos/15-bank/dbfailover.sh
FROM=3 demos/15-bank/dbfailover.sh          # only promotion + failback
```
The commands the script runs, and why:

| Step | Command | Why |
|---|---|---|
| case 2: kill the primary pod | `kubectl --context kind-poc2 -n bank delete pod postgres-0` while a read+write loop runs | reads must continue from the standby (`"db":"standby"`), writes pause only for the pod restart; the slot lets replication reattach |
| case 3: lose the primary | `kubectl --context kind-poc2 -n bank scale sts/postgres --replicas=0` | simulate the poc2 database being gone, not just restarting |
| promote | `psql … -c "SELECT pg_promote(true, 30)"` on `postgres-standby-0` | ends recovery, starts a new timeline; the standby is now a primary that accepts writes |
| repoint | `kubectl --context kind-poc2 -n bank set env deploy/accounts PG_DSN=postgres://…@postgres-standby.bank.svc.cluster.local:5432/bank?sslmode=disable` | one env change, one rollout — `accounts` stays in poc2 and writes to poc1's database through the mesh |
| case 4 safety net | `pg_dump -U bank bank > .tmp/bank-<ts>.sql` on the current primary | never destroy a volume before a copy exists (gotcha #55) |
| rebuild poc2 as standby | `set env sts/postgres -c bootstrap BOOTSTRAP_FROM=postgres-standby.bank.svc.cluster.local`, delete its PVC, `scale --replicas=1` | the old primary's timeline is obsolete; a failback is a rebuild, never a rewind |
| verify before promoting | `pg_is_in_recovery()` = `t` on poc2 **and** `pg_stat_replication` on poc1 shows 1 streaming | the gate the first run lacked |
| promote poc2, repoint, verify a write | `pg_promote()` on poc2, `set env … PG_DSN=…postgres-primary…`, one payment → `201` | writes must land on the new primary before anything else is deleted |
| rebuild poc1 as standby | scale to 0, delete its PVC, recreate the slot on poc2, scale to 1 | its init container base-backs-up from `postgres-primary` again — original topology |

*Expect (third run):* case 3 `20 payments: 20 ok, 0 failed`; case 4 `balances primary=… standby=…`
equal, `a payment -> http 201`.

## 7. Clean up

```bash
kubectl --context kind-poc1 delete -f demos/15-bank/30-gateway.yaml -f demos/15-bank/40-postgres-standby-poc1.yaml -f demos/15-bank/20-poc1.yaml
kubectl --context kind-poc2 delete -f demos/15-bank/10-poc2.yaml
```
*Why this order:* routes and the standby first (they reference the others), then the namespaces —
the PVCs are deleted with them. The image and the `.tmp/` dumps stay.
