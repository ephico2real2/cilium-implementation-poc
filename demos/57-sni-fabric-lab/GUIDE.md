# Demo 57 — exercises: touch the shared-SNI fabric

Five exercises on the running lab, from `demos/57-sni-fabric-lab/`; the fourth changes it and
says so.

## Prerequisites

- The lab is up: `scripts/run.sh` has finished (see [RECAP.md](RECAP.md)).
- The commands use the lab CA, `certs/ca/ca.crt`, and the lab credentials in `docs/usage.md`.
- Prometheus scrapes every 10 s, so a counter read through it moves up to 10 s after the event.

## Exercises

### 1. See which backend answers each hostname

Every hostname reaches its own backend on the same port, and the certificate is the backend's:
Envoy decrypts nothing.

```bash
for h in web api tcp qm1 mqconsole; do
  printf '%-10s ' "$h"
  openssl s_client -connect 127.0.0.1:8443 -servername "${h}.fabric.localtest.me" \
    -verify_hostname "${h}.fabric.localtest.me" -CAfile certs/ca/ca.crt </dev/null 2>/dev/null \
    | grep -E '^subject=|Verify return code' | tr '\n' ' '; echo
done
```

**Expect:**

```text
web        subject=O=SNI Fabric Lab, CN=web.fabric.localtest.me Verify return code: 0 (ok) 
api        subject=O=SNI Fabric Lab, CN=api.fabric.localtest.me Verify return code: 0 (ok) 
tcp        subject=O=SNI Fabric Lab, CN=tcp.fabric.localtest.me Verify return code: 0 (ok) 
qm1        subject=O=SNI Fabric Lab, CN=qm1.fabric.localtest.me Verify return code: 0 (ok) 
mqconsole  subject=O=SNI Fabric Lab, CN=qm1.fabric.localtest.me     Verify return code: 0 (ok) 
```

### 2. Watch Envoy reset an unknown hostname

A hostname with no tenant is reset, and Envoy counts it.

```bash
q='envoy_listener_no_filter_chain_match_total{envoy_listener_address="0.0.0.0_10443"}'
count() { curl -s -G http://prometheus.fabric.localtest.me:8080/api/v1/query --data-urlencode "query=${q}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["result"][0]["value"][1])'; }
echo "before: $(count)"
openssl s_client -connect 127.0.0.1:8443 -servername nobody.fabric.localtest.me </dev/null 2>&1 | grep 'no peer'
sleep 15; echo "after:  $(count)"
```

**Expect:**

```text
before: 3
no peer certificate available
after:  4
```

### 3. Follow one order through Envoy

One order's four hops, read from Envoy's access log: the TLS connection passed through, the
event's put on MQ, the worker's get, and the status update.

```bash
python3 scripts/trace_order.py
```

**Expect:**

```text
order 40 created: created, events sent 1
order 40 now: processed
2026-10-22T01:57:53.846Z  DELETE mqrest.mesh:18080/ibmmq/rest/v3/messaging/qmgr/QM1/queue/DEV.QUEUE.1/message -> 200 attempts=1 cluster=mq_web
2026-10-22T01:57:54.988Z  TLS    api.fabric.localtest.me -> orders_api_tls (passed through, 1940 bytes in)
2026-10-22T01:57:54.993Z  POST   mqrest.mesh:18080/ibmmq/rest/v3/messaging/qmgr/QM1/queue/DEV.QUEUE.1/message -> 201 attempts=1 cluster=mq_web
2026-10-22T01:57:55.047Z  PUT    api.mesh:18080/orders/40/status -> 200 attempts=1 cluster=orders_api_internal
```

### 4. Make Envoy's retries visible (changes the lab: chaos on for 20 s, then off)

Half of the worker's status updates fail, and Envoy's retry counter for orders-api rises.
Every order still reaches `processed`: check it on the admin portal.

```bash
q='envoy_cluster_upstream_rq_retry_total{envoy_cluster_name="orders_api_internal"}'
count() { curl -s -G http://prometheus.fabric.localtest.me:8080/api/v1/query --data-urlencode "query=${q}" \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else 0)'; }
chaos() { curl -s --cacert certs/ca/ca.crt -X PUT -H 'Authorization: Bearer fabric-admin' \
  -H 'Content-Type: application/json' -d "{\"fail_rate\":$1,\"delay_ms\":0}" \
  https://api.fabric.localtest.me:8443/admin/chaos; echo; }
echo "retries before: $(count)"
chaos 0.5
python3 scripts/load.py --seconds 20
chaos 0
sleep 15; echo "retries after:  $(count)"
```

**Expect:**

```text
retries before: 8
{"fail_rate":0.5,"delay_ms":0}
    40  GET /tcp/ping -> 200
    40  POST /orders new -> 201
    40  POST /orders replay -> 200
     4  unknown SNI -> reset
{"fail_rate":0.0,"delay_ms":0}
retries after:  43
```

### 5. Run the dashboard's queries against Prometheus

Every query the Grafana dashboard draws, run against the real data source.

```bash
python3 tests/dashboard_queries.py --minutes 5 | tail -1
```

**Expect:**

```text
31 queries, 0 with errors or warnings, 0 empty, 0.07 s in all
```

## Clean up

See [Clean up in README.md](README.md#clean-up).
