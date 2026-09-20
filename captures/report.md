## The demos' checks, after 1 minutes of traffic

| check | lines | words that mean trouble |
|---|---|---|
| demo 16 — Prometheus, the metric families the dashboards read | 9 | 0 |
| demo 25 — the observer pipeline | 18 | 0 |
| demo 25 Part 5 — the relay's mutual TLS: required, held by the observer, refused to an anonymous client | 19 | 0 |
| demo 18 — OBI, the requests it saw with their trace ids | 80 | 0 |
| demo 23 — the collector per cluster and Tempo's traces per cluster | 17 | 0 |
| demo 36 — one root, everywhere: the chain, the host, both clusters' Bundles, a pod | 24 | 0 |
| demo 15 — the bank across the mesh, from inside, with two failovers | 46 | 0 |
| demo 20 — the petclinic's API through the Gateway | 12 | 0 |
| demo 19 — what Hubble denied in bank, both clusters, with the policy | 2 | 0 |
| the generated policies — every CiliumNetworkPolicy cf2cnp wrote in the chapters, as the agent sees it | 16 | 0 |
| demo 26 — the lab's verdicts with the deciding policy | 14 | 0 |
| demo 30 — method+path pairs from the proxy's flows | 9 | 0 |
| demo 35 — the platform's pairs with the deciding policy | 16 | 0 |

### demo 16 — Prometheus, the metric families the dashboards read

```
$ demo16
targets up: 31 of 31
  hubble_flows_processed_total     674741
  hubble_http_requests_total       3573
  hubble_dns_queries_total         8839
  hubble_policy_verdicts_total     66889
  hubble_drop_total                2727
  cilium_endpoint_state            75
  cilium_policy_change_total       342
  grafana dashboards provisioned   33
```

### demo 25 — the observer pipeline (demos/25-hubble-observer-loki/check.sh 1)

```
$ demos/25-hubble-observer-loki/check.sh 1
== observer ==
hubble-observer-798f7997bc-nnvt5          true   0     poc1-worker
hubble-observer-cf2cnp-6bcf768479-8g8n6   true   0     poc1-worker
  relay as the observer sees it: Connected Nodes: 4/4
== collector → Loki (per pod: spans of the Loki exporter's queue) ==
  otel-collector-l67xh       loki queue=0 sent_logs=1970 failed=0
  otel-collector-n5j4z       loki queue=0 sent_logs=0 failed=0
== Loki ==
  index labels: container k8s_cluster_name k8s_container_name k8s_namespace_name k8s_pod_name namespace service_name
  stored flows, last 1 h, by source cluster and verdict:
    {'flow_source_cluster_name': 'poc1', 'flow_verdict': 'DROPPED'} 1762
    {'flow_verdict': 'DROPPED'} 138
== Grafana ==
  ds: Loki loki http://loki.monitoring.svc.cluster.local:3100
  dashboard: Cilium Flows - Hubble Observer | folder: Hubble | /d/hubble-observer-23862
== cf2cnp ==
cf2cnp   [cf2cnp.poc.local]   True
  health: OK
```

### demo 25 Part 5 — the relay's mutual TLS: required, held by the observer, refused to an anonymous client (demos/25-hubble-observer-loki/mtls-check.sh)

```
$ demos/25-hubble-observer-loki/mtls-check.sh
== 1. the relay: server TLS on, client certificates required (hubble-relay-config, the Service port)
  tls-relay-server-cert-file   1
  tls-relay-client-ca-files    1
  disable-server-tls           0 (0 = TLS on)
  Service hubble-relay port    443
  relay's certificate          subject=CN=*.hubble-relay.cilium.io issuer=CN=clustermesh-root-ca 
== 2. the observer's client certificate: from the enterprise issuer, client auth, Ready (30-relay-mtls-client-cert.yaml)
  Certificate Ready            True
  issued                       subject=CN=hubble-observer.hubble-relay-client.cilium.io issuer=CN=clustermesh-root-ca X509v3 Extended Key Usage: TLS Web Client Authentication 
  the pod's environment        HUBBLE_TLS=true HUBBLE_TLS_SERVER_NAME=hubble.hubble-relay.cilium.io HUBBLE_TLS_CA_CERT_FILES=/var/lib/hubble-observer/tls/ca.crt HUBBLE_TLS_CLIENT_CERT_FILE=/var/lib/hubble-observer/tls/client.crt HUBBLE_TLS_CLIENT_KEY_FILE=/var/lib/hubble-observer/tls/client.key 
== 3. the observer over mTLS: the relay as the observer sees it (hubble status from inside the pod)
  Healthcheck (via hubble-relay.kube-system.svc.cluster.local:443): Ok Connected Nodes: 4/4 
  pod                          hubble-observer-798f7997bc-nnvt5 ready=true restarts=0 
== 4. an anonymous client is refused (GUIDE exercise 7): the agent image's own hubble CLI, no certificate
  TLS, no client certificate   refused — the relay answered: tls: certificate required
  plaintext                    refused — no server preface in plaintext (the relay speaks TLS only)
== 5. what came through the mTLS stream: the observer's stdout and Loki, last 15 minutes
  observer stdout lines        757
  Loki lines                   757
```

### demo 18 — OBI, the requests it saw with their trace ids (demos/18-obi/check.sh 20m)

```
$ demos/18-obi/check.sh 20m
== poc1 ==
2026-09-16 00:15:11.916121511 (12.545292ms[12.5305ms]) HTTP(subType=0) 200 GET /api/statement/chk-1001(/api/statement/{id}) [10.10.1.27 as client.forensic:60826]->[10.10.0.49 as api.bank:8080] contentLen:0B responseLen:0B svc=[bank/api go] traceparent=[00-d1023286de449bde9a65bcd72ce591b8-686e5779b9fcdc9e[0000000000000000]-01]
2026-09-16 00:15:11.916121511 (2.128708ms[2.128708ms]) HTTPClient(subType=0) 200 POST /accounts/chk-1002/debit(/accounts/*/debit) [10.10.0.55 as payments.bank:43854]->[10.11.199.21 as accounts.bank:80] contentLen:39B responseLen:188B svc=[bank/payments go] traceparent=[00-ba876169d915f320187f753f104f8081-f5678a621b4e96ee[1de41b8f815c2031]-01]
2026-09-16 00:15:11.916121511 (2.181167ms[2.181167ms]) HTTPClient(subType=0) 200 POST /accounts/chk-1002/debit(/accounts/*/debit) [10.10.0.55 as payments.bank:43778]->[10.11.199.21 as accounts.bank:80] contentLen:39B responseLen:188B svc=[bank/payments go] traceparent=[00-2de9f13559e4dc2f6b7d018c18263a9c-ac3b1729bb58ae36[36e796aa8655de60]-01]
2026-09-16 00:15:11.916121511 (2.260917ms[2.260917ms]) HTTPClient(subType=0) 200 POST /accounts/chk-1002/debit(/accounts/*/debit) [10.10.0.55 as payments.bank:43794]->[10.11.199.21 as accounts.bank:80] contentLen:39B responseLen:188B svc=[bank/payments go] traceparent=[00-de07120c6b4fe21ad824c9434f791831-0c09a5d3d5ec4f3d[55f4aaf0d77ea085]-01]
2026-09-16 00:15:11.916121511 (2.339333ms[2.339333ms]) HTTPClient(subType=0) 200 POST /accounts/chk-1002/debit(/accounts/*/debit) [10.10.0.55 as payments.bank:43834]->[10.11.199.21 as accounts.bank:80] contentLen:39B responseLen:195B svc=[bank/payments go] traceparent=[00-5a0f9af2d8a8354617a51d4fda8c26f8-6f36b87a80327fac[6f7f892e178ec490]-01]
2026-09-16 00:15:11.916121511 (2.3795ms[2.3795ms]) HTTPClient(subType=0) 200 POST /accounts/chk-1002/debit(/accounts/*/debit) [10.10.0.55 as payments.bank:43842]->[10.11.199.21 as accounts.bank:80] contentLen:39B responseLen:195B svc=[bank/payments go] traceparent=[00-bb61ca0e8d76c0f1d0b865df77af5ae2-3224897cdd2498ad[10c0a59364458739]-01]
2026-09-16 00:15:11.916121511 (2.382583ms[2.382583ms]) HTTPClient(subType=0) 200 POST /accounts/chk-1002/debit(/accounts/*/debit) [10.10.0.55 as payments.bank:43822]->[10.11.199.21 as accounts.bank:80] contentLen:39B responseLen:188B svc=[bank/payments go] traceparent=[00-c8d5d665ea02f02c77294ed86cbeb83e-35dde3c70e21a8bf[af75d9fba145e89a]-01]
2026-09-16 00:15:11.916121511 (2.416917ms[2.416917ms]) HTTPClient(subType=0) 200 POST /accounts/chk-1002/debit(/accounts/*/debit) [10.10.0.55 as payments.bank:43766]->[10.11.199.21 as accounts.bank:80] contentLen:38B responseLen:187B svc=[bank/payments go] traceparent=[00-d26f4bcda9f504056dedab66861ee139-1c12cdbab941f500[4d646e6c54feb610]-01]
2026-09-16 00:15:11.916121511 (2.477833ms[2.477833ms]) HTTPClient(subType=0) 200 POST /accounts/chk-1002/debit(/accounts/*/debit) [10.10.0.55 as payments.bank:43818]->[10.11.199.21 as accounts.bank:80] contentLen:39B responseLen:195B svc=[bank/payments go] traceparent=[00-824cacdef3bec2b87f0a642837968845-4bec7f9e053b30cc[ceb598917788776e]-01]
2026-09-16 00:15:11.916121511 (2.477ms[2.477ms]) HTTPClient(subType=0) 200 POST /accounts/chk-1002/debit(/accounts/*/debit) [10.10.0.55 as payments.bank:43828]->[10.11.199.21 as accounts.bank:80] contentLen:39B responseLen:195B svc=[bank/payments go] traceparent=[00-49ff80aaa05aadf50b58ed0654b9361e-75f90fccfd2c7ca6[4240b4946c9624ae]-01]
2026-09-16 00:15:11.916121511 (2.47825ms[2.47825ms]) HTTPClient(subType=0) 200 POST /accounts/chk-1002/debit(/accounts/*/debit) [10.10.0.55 as payments.bank:43782]->[10.11.199.21 as accounts.bank:80] contentLen:39B responseLen:195B svc=[bank/payments go] traceparent=[00-12da03faf2f0050652cbfd9f5a62de56-e258145d1de44b85[89240453f9487572]-01]
2026-09-16 00:15:11.916121511 (2.601334ms[2.601334ms]) HTTPClient(subType=0) 200 POST /accounts/chk-1002/debit(/accounts/*/debit) [10.10.0.55 as payments.bank:43864]->[10.11.199.21 as accounts.bank:80] contentLen:39B responseLen:188B svc=[bank/payments go] traceparent=[00-1d57106f0320dfc74e2dff3c3d0e8e47-1d9b5808e5b857b2[913d530811687402]-01]
2026-09-16 00:15:11.916121511 (2.668208ms[2.668208ms]) HTTPClient(subType=0) 200 POST /accounts/chk-1002/debit(/accounts/*/debit) [10.10.0.55 as payments.bank:43806]->[10.11.199.21 as accounts.bank:80] contentLen:39B responseLen:188B svc=[bank/payments go] traceparent=[00-d119617390b3a251699772dd92dd360b-4b5c28786a7863df[7c22706a4e501ccd]-01]
2026-09-16 00:15:11.916121511 (2.671541ms[2.671541ms]) HTTPClient(subType=0) 200 POST /accounts/chk-1002/debit(/accounts/*/debit) [10.10.0.55 as payments.bank:43754]->[10.11.199.21 as accounts.bank:80] contentLen:38B responseLen:194B svc=[bank/payments go] traceparent=[00-9a4e1fc1091344db824d0894ff3b34ce-5e8e2f26e7b7a378[fe08a5aac8055597]-01]
2026-09-16 00:15:11.916121511 (2.928625ms[2.914542ms]) HTTP(subType=0) 200 GET /payments/chk-1001(/payments/{account}) [10.10.0.49 as api.bank:35864]->[10.10.0.55 as payments.bank:8080] contentLen:0B responseLen:0B svc=[bank/payments go] traceparent=[00-d1023286de449bde9a65bcd72ce591b8-01b799634d7ff7f4[f8e99eb022f52bbc]-01]
2026-09-16 00:15:11.916121511 (2.975375ms[2.975375ms]) HTTPClient(subType=0) 200 POST /accounts/chk-1002/debit(/accounts/*/debit) [10.10.0.55 as payments.bank:43756]->[10.11.199.21 as accounts.bank:80] contentLen:38B responseLen:194B svc=[bank/payments go] traceparent=[00-588b8046de9778f408001bc0554382d1-76289d4754b5f354[fba8b7fbf39531b3]-01]
2026-09-16 00:15:11.916121511 (2.988541ms[2.976333ms]) HTTP(subType=0) 201 POST /payments(/payments) [10.10.1.119 as api.bank:44708]->[10.10.0.55 as payments.bank:8080] contentLen:80B responseLen:0B svc=[bank/payments go] traceparent=[00-ba876169d915f320187f753f104f8081-1de41b8f815c2031[c2f73146897e1e0d]-01]
2026-09-16 00:15:11.916121511 (3.129667ms[3.129667ms]) HTTPClient(subType=0) 200 POST /accounts/chk-1002/debit(/accounts/*/debit) [10.10.0.55 as payments.bank:43800]->[10.11.199.21 as accounts.bank:80] contentLen:39B responseLen:195B svc=[bank/payments go] traceparent=[00-d3e77fba011a890c64e75c8019654a3a-dc4a737fe4253727[a4dd071ef845ada9]-01]
2026-09-16 00:15:11.916121511 (3.155792ms[3.152584ms]) HTTP(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:36014]->[10.10.0.55 as payments.bank:8080] contentLen:79B responseLen:0B svc=[bank/payments go] traceparent=[00-bb61ca0e8d76c0f1d0b865df77af5ae2-10c0a59364458739[377a935f51d172ef]-01]
2026-09-16 00:15:11.916121511 (3.157292ms[3.151792ms]) HTTP(subType=0) 201 POST /payments(/payments) [10.10.1.119 as api.bank:44604]->[10.10.0.55 as payments.bank:8080] contentLen:80B responseLen:0B svc=[bank/payments go] traceparent=[00-2de9f13559e4dc2f6b7d018c18263a9c-36e796aa8655de60[4e63369375e96209]-01]
2026-09-16 00:15:11.916121511 (3.175375ms[3.175375ms]) HTTPClient(subType=0) 200 POST /accounts/chk-1002/debit(/accounts/*/debit) [10.10.0.55 as payments.bank:43808]->[10.11.199.21 as accounts.bank:80] contentLen:39B responseLen:195B svc=[bank/payments go] traceparent=[00-0049e62032044d25f3e130863dc8ebf8-319d065c3fd1fc78[288f5a12c6a4a1d4]-01]
2026-09-16 00:15:11.916121511 (3.22725ms[3.223625ms]) HTTP(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:36004]->[10.10.0.55 as payments.bank:8080] contentLen:80B responseLen:0B svc=[bank/payments go] traceparent=[00-49ff80aaa05aadf50b58ed0654b9361e-4240b4946c9624ae[5ee4508ef7e381bb]-01]
2026-09-16 00:15:11.916121511 (3.237833ms[3.234333ms]) HTTP(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35904]->[10.10.0.55 as payments.bank:8080] contentLen:78B responseLen:0B svc=[bank/payments go] traceparent=[00-d26f4bcda9f504056dedab66861ee139-4d646e6c54feb610[ba22d29ffb0a0474]-01]
2026-09-16 00:15:11.916121511 (3.246417ms[3.241458ms]) HTTP(subType=0) 201 POST /payments(/payments) [10.10.1.119 as api.bank:44606]->[10.10.0.55 as payments.bank:8080] contentLen:78B responseLen:0B svc=[bank/payments go] traceparent=[00-12da03faf2f0050652cbfd9f5a62de56-89240453f9487572[8a9bef921e118c97]-01]
2026-09-16 00:15:11.916121511 (3.276709ms[3.273292ms]) HTTP(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35946]->[10.10.0.55 as payments.bank:8080] contentLen:79B responseLen:0B svc=[bank/payments go] traceparent=[00-de07120c6b4fe21ad824c9434f791831-55f4aaf0d77ea085[640526260ace993d]-01]
2026-09-16 00:15:11.916121511 (3.328791ms[3.324875ms]) HTTP(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35992]->[10.10.0.55 as payments.bank:8080] contentLen:80B responseLen:0B svc=[bank/payments go] traceparent=[00-824cacdef3bec2b87f0a642837968845-ceb598917788776e[59c434c813fb5151]-01]
2026-09-16 00:15:11.916121511 (3.464917ms[3.460084ms]) HTTP(subType=0) 201 POST /payments(/payments) [10.10.1.119 as api.bank:44710]->[10.10.0.55 as payments.bank:8080] contentLen:80B responseLen:0B svc=[bank/payments go] traceparent=[00-1d57106f0320dfc74e2dff3c3d0e8e47-913d530811687402[ec1fd192aea38825]-01]
2026-09-16 00:15:11.916121511 (3.486958ms[3.481917ms]) HTTP(subType=0) 201 POST /payments(/payments) [10.10.1.119 as api.bank:44688]->[10.10.0.55 as payments.bank:8080] contentLen:79B responseLen:0B svc=[bank/payments go] traceparent=[00-5a0f9af2d8a8354617a51d4fda8c26f8-6f7f892e178ec490[692789b9b6f0524b]-01]
2026-09-16 00:15:11.916121511 (3.517042ms[3.513625ms]) HTTP(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35968]->[10.10.0.55 as payments.bank:8080] contentLen:80B responseLen:0B svc=[bank/payments go] traceparent=[00-d119617390b3a251699772dd92dd360b-7c22706a4e501ccd[488fdb03a68227db]-01]
2026-09-16 00:15:11.916121511 (3.542583ms[3.536958ms]) HTTP(subType=0) 201 POST /payments(/payments) [10.10.1.119 as api.bank:44680]->[10.10.0.55 as payments.bank:8080] contentLen:80B responseLen:0B svc=[bank/payments go] traceparent=[00-c8d5d665ea02f02c77294ed86cbeb83e-af75d9fba145e89a[1e02d8901bf8c407]-01]
2026-09-16 00:15:11.916121511 (3.72875ms[3.724959ms]) HTTP(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35880]->[10.10.0.55 as payments.bank:8080] contentLen:78B responseLen:0B svc=[bank/payments go] traceparent=[00-9a4e1fc1091344db824d0894ff3b34ce-fe08a5aac8055597[b9f57eca29be282a]-01]
2026-09-16 00:15:11.916121511 (3.993334ms[3.98675ms]) HTTP(subType=0) 201 POST /payments(/payments) [10.10.1.119 as api.bank:44570]->[10.10.0.55 as payments.bank:8080] contentLen:78B responseLen:0B svc=[bank/payments go] traceparent=[00-588b8046de9778f408001bc0554382d1-fba8b7fbf39531b3[55af656648f91be3]-01]
2026-09-16 00:15:11.916121511 (4.190542ms[4.185042ms]) HTTP(subType=0) 201 POST /payments(/payments) [10.10.1.119 as api.bank:44636]->[10.10.0.55 as payments.bank:8080] contentLen:80B responseLen:0B svc=[bank/payments go] traceparent=[00-d3e77fba011a890c64e75c8019654a3a-a4dd071ef845ada9[f04892f5b9be9192]-01]
2026-09-16 00:15:11.916121511 (4.491084ms[4.491084ms]) HTTPClient(subType=0) 200 GET /accounts/chk-1001(/accounts/*) [10.10.0.49 as api.bank:53884]->[10.11.199.21 as accounts.bank:80] contentLen:0B responseLen:187B svc=[bank/api go] traceparent=[00-d1023286de449bde9a65bcd72ce591b8-644ff7783cc0fe0c[686e5779b9fcdc9e]-01]
2026-09-16 00:15:11.916121511 (4.503459ms[4.497834ms]) HTTP(subType=0) 201 POST /payments(/payments) [10.10.1.119 as api.bank:44666]->[10.10.0.55 as payments.bank:8080] contentLen:80B responseLen:0B svc=[bank/payments go] traceparent=[00-0049e62032044d25f3e130863dc8ebf8-288f5a12c6a4a1d4[6ad91f66307e9fa1]-01]
2026-09-16 00:15:11.916121511 (4.639208ms[4.639208ms]) HTTPClient(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35960]->[10.11.123.216 as payments.bank:80] contentLen:80B responseLen:412B svc=[bank/api go] traceparent=[00-6ba43641babe3bb022ba465405e53263-e62064354b89f81a[24584bbd46c02cbd]-01]
2026-09-16 00:15:11.916121511 (4.785333ms[4.785333ms]) HTTPClient(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:36014]->[10.11.123.216 as payments.bank:80] contentLen:79B responseLen:425B svc=[bank/api go] traceparent=[00-bb61ca0e8d76c0f1d0b865df77af5ae2-377a935f51d172ef[40ecbc10dc0492bc]-01]
2026-09-16 00:15:11.916121511 (4.802541ms[4.802541ms]) HTTPClient(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35904]->[10.11.123.216 as payments.bank:80] contentLen:78B responseLen:416B svc=[bank/api go] traceparent=[00-d26f4bcda9f504056dedab66861ee139-ba22d29ffb0a0474[0036a2f075292988]-01]
2026-09-16 00:15:11.916121511 (4.833709ms[4.833709ms]) HTTPClient(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35948]->[10.11.123.216 as payments.bank:80] contentLen:79B responseLen:418B svc=[bank/api go] traceparent=[00-629b6ed4e1c81b746be11a2d7aba6201-691250ca7313e96b[be256db8cbdbc6f9]-01]
2026-09-16 00:15:11.916121511 (4.834291ms[4.834291ms]) HTTPClient(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35900]->[10.11.123.216 as payments.bank:80] contentLen:78B responseLen:409B svc=[bank/api go] traceparent=[00-03cc59d73d78cb53a50be7f359b92a1d-1588616ba528bbc1[151587e14fd329fe]-01]
2026-09-16 00:15:11.916121511 (4.914584ms[4.907667ms]) HTTP(subType=0) 201 POST /api/pay(/api/pay) [10.10.1.27 as client.forensic:32768]->[10.10.0.49 as api.bank:8080] contentLen:80B responseLen:0B svc=[bank/api go] traceparent=[00-6ba43641babe3bb022ba465405e53263-24584bbd46c02cbd[0000000000000000]-01]
2026-09-16 00:15:11.916121511 (4.94675ms[4.94675ms]) HTTPClient(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35946]->[10.11.123.216 as payments.bank:80] contentLen:79B responseLen:418B svc=[bank/api go] traceparent=[00-de07120c6b4fe21ad824c9434f791831-640526260ace993d[890d8a315b99ff74]-01]
2026-09-16 00:15:11.916121511 (4.975375ms[4.975375ms]) HTTPClient(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35920]->[10.11.123.216 as payments.bank:80] contentLen:80B responseLen:419B svc=[bank/api go] traceparent=[00-98cbc0e1156124cc05fe59236e2178de-a6af8256b92198af[dcdfdd209f69f989]-01]
2026-09-16 00:15:11.916121511 (496.208µs[491µs]) HTTP(subType=0) 200 POST /payments(/payments) [10.10.1.119 as api.bank:44536]->[10.10.0.55 as payments.bank:8080] contentLen:85B responseLen:0B svc=[bank/payments go] traceparent=[00-9228f15ade87603775cd9f075448d4a6-7f6b9bcf064bbf3d[22be70017f6e7f8a]-01]
2026-09-16 00:15:11.916121511 (5.070416ms[5.070416ms]) HTTPClient(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35992]->[10.11.123.216 as payments.bank:80] contentLen:80B responseLen:426B svc=[bank/api go] traceparent=[00-824cacdef3bec2b87f0a642837968845-59c434c813fb5151[c4905f270b16827f]-01]
2026-09-16 00:15:11.916121511 (5.0735ms[5.066875ms]) HTTP(subType=0) 201 POST /api/pay(/api/pay) [10.10.1.27 as client.forensic:32948]->[10.10.0.49 as api.bank:8080] contentLen:79B responseLen:0B svc=[bank/api go] traceparent=[00-bb61ca0e8d76c0f1d0b865df77af5ae2-40ecbc10dc0492bc[0000000000000000]-01]
2026-09-16 00:15:11.916121511 (5.089375ms[5.089375ms]) HTTPClient(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35924]->[10.11.123.216 as payments.bank:80] contentLen:80B responseLen:419B svc=[bank/api go] traceparent=[00-2801cfb33ca30b25269a34515d161b83-84bc3ad43ebd8120[5c6a46411ea7a93c]-01]
2026-09-16 00:15:11.916121511 (5.106292ms[5.099417ms]) HTTP(subType=0) 201 POST /api/pay(/api/pay) [10.10.1.27 as client.forensic:60914]->[10.10.0.49 as api.bank:8080] contentLen:78B responseLen:0B svc=[bank/api go] traceparent=[00-d26f4bcda9f504056dedab66861ee139-0036a2f075292988[0000000000000000]-01]
2026-09-16 00:15:11.916121511 (5.135292ms[5.129333ms]) HTTP(subType=0) 201 POST /api/pay(/api/pay) [10.10.1.27 as client.forensic:60992]->[10.10.0.49 as api.bank:8080] contentLen:79B responseLen:0B svc=[bank/api go] traceparent=[00-629b6ed4e1c81b746be11a2d7aba6201-be256db8cbdbc6f9[0000000000000000]-01]
2026-09-16 00:15:11.916121511 (5.183708ms[5.183708ms]) HTTPClient(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35940]->[10.11.123.216 as payments.bank:80] contentLen:80B responseLen:412B svc=[bank/api go] traceparent=[00-c927efb3a4557514affa2d892a885e0d-127a7dcfb4cb5e92[e8cc81c61cebb9ac]-01]
2026-09-16 00:15:11.916121511 (5.232333ms[5.224833ms]) HTTP(subType=0) 201 POST /api/pay(/api/pay) [10.10.1.27 as client.forensic:60906]->[10.10.0.49 as api.bank:8080] contentLen:78B responseLen:0B svc=[bank/api go] traceparent=[00-03cc59d73d78cb53a50be7f359b92a1d-151587e14fd329fe[0000000000000000]-01]
2026-09-16 00:15:11.916121511 (5.257625ms[5.251042ms]) HTTP(subType=0) 201 POST /api/pay(/api/pay) [10.10.1.27 as client.forensic:60986]->[10.10.0.49 as api.bank:8080] contentLen:79B responseLen:0B svc=[bank/api go] traceparent=[00-de07120c6b4fe21ad824c9434f791831-890d8a315b99ff74[0000000000000000]-01]
2026-09-16 00:15:11.916121511 (5.316125ms[5.309333ms]) HTTP(subType=0) 201 POST /api/pay(/api/pay) [10.10.1.27 as client.forensic:32884]->[10.10.0.49 as api.bank:8080] contentLen:80B responseLen:0B svc=[bank/api go] traceparent=[00-824cacdef3bec2b87f0a642837968845-c4905f270b16827f[0000000000000000]-01]
2026-09-16 00:15:11.916121511 (5.321ms[5.321ms]) HTTPClient(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35912]->[10.11.123.216 as payments.bank:80] contentLen:80B responseLen:419B svc=[bank/api go] traceparent=[00-3370d998f891fe844b65617085072a65-6dd763e244162d64[b1860570b05cf08c]-01]
2026-09-16 00:15:11.916121511 (5.372125ms[5.365583ms]) HTTP(subType=0) 201 POST /api/pay(/api/pay) [10.10.1.27 as client.forensic:60960]->[10.10.0.49 as api.bank:8080] contentLen:80B responseLen:0B svc=[bank/api go] traceparent=[00-98cbc0e1156124cc05fe59236e2178de-dcdfdd209f69f989[0000000000000000]-01]
2026-09-16 00:15:11.916121511 (5.423334ms[5.423334ms]) HTTPClient(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:36004]->[10.11.123.216 as payments.bank:80] contentLen:80B responseLen:426B svc=[bank/api go] traceparent=[00-49ff80aaa05aadf50b58ed0654b9361e-5ee4508ef7e381bb[723923b5243731a9]-01]
2026-09-16 00:15:11.916121511 (5.44025ms[5.434292ms]) HTTP(subType=0) 201 POST /api/pay(/api/pay) [10.10.1.27 as client.forensic:60972]->[10.10.0.49 as api.bank:8080] contentLen:80B responseLen:0B svc=[bank/api go] traceparent=[00-2801cfb33ca30b25269a34515d161b83-5c6a46411ea7a93c[0000000000000000]-01]
2026-09-16 00:15:11.916121511 (5.468625ms[5.468625ms]) HTTPClient(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35972]->[10.11.123.216 as payments.bank:80] contentLen:80B responseLen:419B svc=[bank/api go] traceparent=[00-b53ec3f62dbf3541c69ecf7d2b4bbe8d-851fa296ab423cb0[faf8c9c722672840]-01]
2026-09-16 00:15:11.916121511 (5.5245ms[5.5245ms]) HTTPClient(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35968]->[10.11.123.216 as payments.bank:80] contentLen:80B responseLen:419B svc=[bank/api go] traceparent=[00-d119617390b3a251699772dd92dd360b-488fdb03a68227db[564ad7bb9a38a73f]-01]
2026-09-16 00:15:11.916121511 (5.526708ms[5.519708ms]) HTTP(subType=0) 201 POST /api/pay(/api/pay) [10.10.1.27 as client.forensic:60976]->[10.10.0.49 as api.bank:8080] contentLen:80B responseLen:0B svc=[bank/api go] traceparent=[00-c927efb3a4557514affa2d892a885e0d-e8cc81c61cebb9ac[0000000000000000]-01]
2026-09-16 00:15:11.916121511 (5.623042ms[5.623042ms]) HTTPClient(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35986]->[10.11.123.216 as payments.bank:80] contentLen:80B responseLen:419B svc=[bank/api go] traceparent=[00-66d1f199ef75bdb4fd4197729ffdea58-ed92178240053591[564abd5a9de68fdd]-01]
2026-09-16 00:15:11.916121511 (5.692666ms[5.68625ms]) HTTP(subType=0) 201 POST /api/pay(/api/pay) [10.10.1.27 as client.forensic:60916]->[10.10.0.49 as api.bank:8080] contentLen:80B responseLen:0B svc=[bank/api go] traceparent=[00-3370d998f891fe844b65617085072a65-b1860570b05cf08c[0000000000000000]-01]
2026-09-16 00:15:11.916121511 (5.719334ms[5.712542ms]) HTTP(subType=0) 201 POST /api/pay(/api/pay) [10.10.1.27 as client.forensic:32930]->[10.10.0.49 as api.bank:8080] contentLen:80B responseLen:0B svc=[bank/api go] traceparent=[00-49ff80aaa05aadf50b58ed0654b9361e-723923b5243731a9[0000000000000000]-01]
2026-09-16 00:15:11.916121511 (5.728875ms[5.728875ms]) HTTPClient(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35898]->[10.11.123.216 as payments.bank:80] contentLen:77B responseLen:415B svc=[bank/api go] traceparent=[00-a1c19a195188946df2c5c09ae3dc0f49-a2586cedf728b331[1965639cb20488c7]-01]
2026-09-16 00:15:11.916121511 (5.773292ms[5.766542ms]) HTTP(subType=0) 201 POST /api/pay(/api/pay) [10.10.1.27 as client.forensic:32810]->[10.10.0.49 as api.bank:8080] contentLen:80B responseLen:0B svc=[bank/api go] traceparent=[00-b53ec3f62dbf3541c69ecf7d2b4bbe8d-faf8c9c722672840[0000000000000000]-01]
2026-09-16 00:15:11.916121511 (5.808916ms[5.802791ms]) HTTP(subType=0) 201 POST /api/pay(/api/pay) [10.10.1.27 as client.forensic:32796]->[10.10.0.49 as api.bank:8080] contentLen:80B responseLen:0B svc=[bank/api go] traceparent=[00-d119617390b3a251699772dd92dd360b-564ad7bb9a38a73f[0000000000000000]-01]
2026-09-16 00:15:11.916121511 (5.860666ms[5.860666ms]) HTTPClient(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:36000]->[10.11.123.216 as payments.bank:80] contentLen:80B responseLen:419B svc=[bank/api go] traceparent=[00-25f5a9faae2b8e610daeef6dca06160d-ddc49b1eadb2d92f[a2ad26cd17aac064]-01]
2026-09-16 00:15:11.916121511 (5.861458ms[5.861458ms]) HTTPClient(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35880]->[10.11.123.216 as payments.bank:80] contentLen:78B responseLen:423B svc=[bank/api go] traceparent=[00-9a4e1fc1091344db824d0894ff3b34ce-b9f57eca29be282a[a885e16370b75848]-01]
2026-09-16 00:15:11.916121511 (6.005958ms[5.998792ms]) HTTP(subType=0) 201 POST /api/pay(/api/pay) [10.10.1.27 as client.forensic:32828]->[10.10.0.49 as api.bank:8080] contentLen:80B responseLen:0B svc=[bank/api go] traceparent=[00-66d1f199ef75bdb4fd4197729ffdea58-564abd5a9de68fdd[0000000000000000]-01]
2026-09-16 00:15:11.916121511 (6.094458ms[6.084125ms]) HTTP(subType=0) 201 POST /api/pay(/api/pay) [10.10.1.27 as client.forensic:60898]->[10.10.0.49 as api.bank:8080] contentLen:77B responseLen:0B svc=[bank/api go] traceparent=[00-a1c19a195188946df2c5c09ae3dc0f49-1965639cb20488c7[0000000000000000]-01]
2026-09-16 00:15:11.916121511 (6.182792ms[6.175292ms]) HTTP(subType=0) 201 POST /api/pay(/api/pay) [10.10.1.27 as client.forensic:32902]->[10.10.0.49 as api.bank:8080] contentLen:80B responseLen:0B svc=[bank/api go] traceparent=[00-25f5a9faae2b8e610daeef6dca06160d-a2ad26cd17aac064[0000000000000000]-01]
2026-09-16 00:15:11.916121511 (6.249042ms[6.241875ms]) HTTP(subType=0) 201 POST /api/pay(/api/pay) [10.10.1.27 as client.forensic:60878]->[10.10.0.49 as api.bank:8080] contentLen:78B responseLen:0B svc=[bank/api go] traceparent=[00-9a4e1fc1091344db824d0894ff3b34ce-a885e16370b75848[0000000000000000]-01]
2026-09-16 00:15:11.916121511 (6.309708ms[6.309708ms]) HTTPClient(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35890]->[10.11.123.216 as payments.bank:80] contentLen:77B responseLen:415B svc=[bank/api go] traceparent=[00-d2c8b85792edc2875e7320550d6dc9ec-332e7dbf6b1be9cd[dfa200d1b50d93ee]-01]
2026-09-16 00:15:11.916121511 (6.69375ms[6.686542ms]) HTTP(subType=0) 201 POST /api/pay(/api/pay) [10.10.1.27 as client.forensic:60892]->[10.10.0.49 as api.bank:8080] contentLen:77B responseLen:0B svc=[bank/api go] traceparent=[00-d2c8b85792edc2875e7320550d6dc9ec-dfa200d1b50d93ee[0000000000000000]-01]
2026-09-16 00:15:11.916121511 (7.350791ms[7.350791ms]) HTTPClient(subType=0) 200 GET /payments/chk-1001(/payments/*) [10.10.0.49 as api.bank:35864]->[10.11.123.216 as payments.bank:80] contentLen:0B responseLen:1843B svc=[bank/api go] traceparent=[00-d1023286de449bde9a65bcd72ce591b8-f8e99eb022f52bbc[686e5779b9fcdc9e]-01]
2026-09-16 00:15:11.916121511 (8.173209ms[8.173209ms]) HTTPClient(subType=0) 201 POST /payments(/payments) [10.10.0.49 as api.bank:35876]->[10.11.123.216 as payments.bank:80] contentLen:85B responseLen:426B svc=[bank/api go] traceparent=[00-aeffb034b543441c6400400e8c4b171b-7795f87dc86ce2a9[382e713afbf9d994]-01]
2026-09-16 00:15:11.916121511 (8.556875ms[8.549709ms]) HTTP(subType=0) 201 POST /api/pay(/api/pay) [10.10.1.27 as client.forensic:60832]->[10.10.0.49 as api.bank:8080] contentLen:85B responseLen:0B svc=[bank/api go] traceparent=[00-aeffb034b543441c6400400e8c4b171b-382e713afbf9d994[0000000000000000]-01]
2026-09-16 00:15:12.916121512 (2.13225ms[2.13225ms]) HTTPClient(subType=0) 200 POST /accounts/chk-1002/debit(/accounts/*/debit) [10.10.0.55 as payments.bank:43886]->[10.11.199.21 as accounts.bank:80] contentLen:34B responseLen:190B svc=[bank/payments go] traceparent=[00-ca0c79b0cb10b5ff18cc001a070ce162-9f0a5ec613030986[d14385bfe07baacb]-01]
2026-09-16 00:15:12.916121512 (2.177625ms[2.177625ms]) HTTPClient(subType=0) 200 POST /accounts/chk-1002/debit(/accounts/*/debit) [10.10.0.55 as payments.bank:43880]->[10.11.199.21 as accounts.bank:80] contentLen:34B responseLen:183B svc=[bank/payments go] traceparent=[00-fbc86b9e5e58c1113c3e3e59007c31c4-1b66fde946b61ed9[91da06ed96502f3e]-01]
```

### demo 23 — the collector per cluster and Tempo's traces per cluster (demos/23-collector-per-cluster/check.sh 20)

```
$ demos/23-collector-per-cluster/check.sh 20
== poc1 ==
  otel-collector 10.11.134.126:4318 backends (as poc1-worker's agent sees them):
    60   10.11.134.126:4318/TCP    ClusterIP      1 => 10.10.0.212:4318/TCP (active)    
                                                  2 => 10.10.1.219:4318/TCP (active)    
  annotations: global=[] affinity=[]
  otel-collector-l67xh               queue=0 sent=3545 failed=0
  otel-collector-n5j4z               queue=0 sent=10899 failed=0
== poc2 ==
  otel-collector 10.21.246.251:4318 backends (as poc2-worker's agent sees them):
    26   10.21.246.251:4318/TCP   ClusterIP      1 => 10.20.0.128:4318/TCP (active)    
                                                 2 => 10.20.1.76:4318/TCP (active)     
  annotations: global=[] affinity=[]
  otel-collector-8f8c6fd76-4xmzb     queue=0 sent=0 failed=0
  otel-collector-8f8c6fd76-kj87x     queue=0 sent=11878 failed=0
== Tempo (central): traces per cluster, last 20 min ==
  k8s.cluster.name=poc1: 500 traces
  k8s.cluster.name=poc2: 500 traces
```

### demo 36 — one root, everywhere: the chain, the host, both clusters' Bundles, a pod (demos/36-trust-everywhere/check.sh)

```
$ demos/36-trust-everywhere/check.sh
== 1. the chain: the issuer, its CA, the wildcard it signed
  ClusterIssuer/ca-issuer signs with Secret: clustermesh-root-ca
  that Secret's certificate: subject=CN=clustermesh-root-ca sha256 Fingerprint=F4:FD:F8:B7:78:D9:D3:9E:69:53:E1:CB:FB:26:CD:1A:9B:85:48:66:D4:48:8D:08:0F:E9:73:7E:8A:97:BF:27 
  the wildcard: issuer=CN=clustermesh-root-ca subject= X509v3 Subject Alternative Name: critical     DNS:*.poc.local 

== 2. this host: its trust store, then the Gateway by name with no --cacert
  the System keychain trusts the root (security verify-cert: OK)
  curl by name with no --cacert → http 404, ssl_verify_result 0: the OS store verified the wildcard's chain

== 3. the clusters: trust-manager's Bundle, the ConfigMap in every namespace, one fingerprint everywhere
  kind-poc1: Bundle enterprise-root Synced=True; ConfigMap enterprise-root in 26 of 26 namespaces; 151 certificates per bundle; distinct bundles: 1; bundles carrying our root: 26 of 26
  kind-poc2: Bundle enterprise-root Synced=True; ConfigMap enterprise-root in 11 of 11 namespaces; 151 certificates per bundle; distinct bundles: 1; bundles carrying our root: 11 of 11

== 4. a pod with the bundle mounted (forensic/client, demo 11's rig): the Gateway with the mounted root, and without
  mounted: lrwxrwxrwx    1 root     root            13 Sep 15 23:19 ca.crt -> ..data/ca.crt subject=C=US, O=DigiCert, Inc., CN=DigiCert TLS ECC P384 Root G5 
  forensic/client → https://bank.poc.local  --cacert the mounted bundle: 200 rc=0   SSL_CERT_FILE=the bundle, no flag: 200 rc=0   with nothing: 000 rc=60
  ✓ SSL_CERT_FILE alone is enough for this image's curl (no CURL_CA_BUNDLE pinned in it)
  ✓ without the root the pod's curl is refused (curl exit 60: the peer certificate cannot be authenticated) — the mount is what makes the call trusted
  forensic/client → https://grafana.poc.local  --cacert the mounted bundle: 302 rc=0   SSL_CERT_FILE=the bundle, no flag: 302 rc=0   with nothing: 000 rc=60
  ✓ SSL_CERT_FILE alone is enough for this image's curl (no CURL_CA_BUNDLE pinned in it)
  ✓ without the root the pod's curl is refused (curl exit 60: the peer certificate cannot be authenticated) — the mount is what makes the call trusted

== 5. the mount without asking (Kyverno): a labelled pod that declared nothing, what admission added, a curl with no flag
  Kyverno v1.19.1; MutatingPolicy mount-enterprise-root: true
  trust/curl as admitted: volumes=kube-api-access-6x7rz enterprise-root mounts=/var/run/secrets/kubernetes.io/serviceaccount /etc/enterprise-root env=SSL_CERT_FILE CURL_CA_BUNDLE REQUESTS_CA_BUNDLE NODE_EXTRA_CA_CERTS
  ✓ the mutation is in the spec: the volume, the mount, SSL_CERT_FILE — the manifest declared none of them
  curl https://bank.poc.local/ from the pod, no --cacert, no flag: http 200, ssl_verify_result 0, rc=0
  ✓ verified through SSL_CERT_FILE alone
```

### demo 15 — the bank across the mesh, from inside, with two failovers (demos/15-bank/check.sh, run before the cell by lab-apps.sh)

```
$ cat captures/checks/demo15-check.txt

== 0. readiness and the merged service maps (both clusters must list BOTH payments backends)
  poc1 not-ready pods: 0
  poc2 not-ready pods: 0
  payments backends known: poc1=4 poc2=3 (after ~5s)
    poc1: 88   10.11.123.216:80/TCP      ClusterIP      1 => 10.10.0.219:8080/TCP (active)    
    poc1:                                               2 => 10.20.1.184:8080/TCP (active)    
    poc1: 89   10.11.211.178:80/TCP      ClusterIP      1 => 10.10.0.49:8080/TCP (active)     
    poc1:                                               2 => 10.10.1.119:8080/TCP (active)    

== 1. the whole path in one response: web's api -> accounts (must be poc2) and -> payments
{"api":"poc1","accounts":"poc2","accounts_pod":"accounts-77b86d786-d8rsb","balance_cents":207084,"payments":"poc1"}

== 2. a card payment: api(poc1) -> payments(either) -> accounts(poc2) -> postgres; then the SAME key again = idempotent replay, no second debit
{"balance_after":205834,"payments_cluster":"poc2","debited_by":"poc2","debited_pod":"accounts-77b86d786-d8rsb","replay":null}
{"replay":true,"payments_cluster":"poc2"}
{"balance_cents_after_ONE_debit":205834,"answered_by":"poc2"}

== 3. ACTIVE-ACTIVE: 40 payments through the global service — which cluster served each
       20 poc1
       20 poc2

== 4. FAILOVER A (default affinity): continuous traffic; at t=15s poc1's payments is scaled to 0 (sudden downtime); at t=40s restored
  t=0s ok=1 fail=0 poc1=1 poc2=0
  t=5s ok=22 fail=0 poc1=12 poc2=10
  t=10s ok=45 fail=0 poc1=20 poc2=25
  t=15s ok=69 fail=0 poc1=28 poc2=41
  >>> 00:22:04 scaling poc1 payments to 0
  t=20s ok=93 fail=0 poc1=30 poc2=63
  t=25s ok=116 fail=0 poc1=30 poc2=86
  t=30s ok=140 fail=0 poc1=30 poc2=110
  t=35s ok=164 fail=0 poc1=30 poc2=134
  t=40s ok=187 fail=0 poc1=30 poc2=157
  >>> 00:22:29 restoring poc1 payments to 1
  t=45s ok=211 fail=0 poc1=40 poc2=171
  t=50s ok=235 fail=0 poc1=54 poc2=181
  t=55s ok=258 fail=0 poc1=66 poc2=192
  TOTAL ok=281 fail=0 poc1=77 poc2=204
deployment "payments" successfully rolled out

== 5. FAILOVER B (affinity: local): prefer local, use remote only when no local backend is healthy
  with local healthy, 20 requests:
         20 poc1
  local scaled to 0, 20 requests:
         20 poc2
deployment "payments" successfully rolled out

== 6. the poc2 side: payments there reaches redis (poc1) and accounts (poc2) — a throwaway curl pod in poc2
   {'payments_cluster': 'poc1', 'debited_by': 'poc2', 'stored_in_redis_via_mesh': True}

== 7. the page through the Gateway (bank.poc.local on the wildcard cert)
  https://bank.poc.local -> http 200
  this page: poc1/web-bd8fb9474-9mm49 → api: poc1/api-6d44c9dd88-768q9 → accounts: poc2/accounts-77b86d786-d8rsb · payments: poc2/payments-77cb6b56cd-6twq8

balance now: 103774 cents on chk-1002 (started at 120000)
```

### demo 20 — the petclinic's API through the Gateway (demos/20-springboot/check.sh 5)

```
$ demos/20-springboot/check.sh 5
  GET /api/customer/owners                   200 in 0.016631s
  GET /api/customer/owners/1                 George Franklin pets: ['Leo']
  GET /api/vet/vets                          6 vets
  GET /api/visit/owners/1/pets/1/visits      3 visits
  GET /api/gateway/owners/1 (gateway fan-out) 200 in 0.013807s
  POST /api/visit/owners/1/pets/1/visits     201
  5 × GET /api/gateway/owners/1:
    200 0.013698s
    200 0.014244s
    200 0.015555s
    200 0.013860s
    200 0.012336s
```

### demo 19 — what Hubble denied in bank, both clusters, with the policy (demos/19-zero-trust-cell/drops.sh 20m)

```
$ demos/19-zero-trust-cell/drops.sh 20m
== poc1: 0 dropped flows ==
== poc2: 0 dropped flows ==
```

### the generated policies — every CiliumNetworkPolicy cf2cnp wrote in the chapters, as the agent sees it

```
$ policies
  cf2cnp-lab/pos                     Valid=True  captures/policies/31/cnp-pos-fqdn.yaml         Allow egress from pos in cf2cnp-lab: to shop on TCP/80; to example.com on TCP/443; to kube
  cf2cnp-lab/shop                    Valid=True  captures/policies/26/cnp-pos-to-shop.yaml      Allow ingress to shop in cf2cnp-lab: from pos on TCP/80
  cf2cnp-lab27/shop-backend          Valid=True  captures/policies/27/cnp-shop.yaml             Allow ingress to shop/backend in cf2cnp-lab27: from shop/frontend on TCP/80
  cf2cnp-lab27/shop-frontend         Valid=True  captures/policies/27/cnp-shop.yaml             Allow ingress to shop/frontend in cf2cnp-lab27: from pos on TCP/80
  cf2cnp-lab27/shop-frontend         Valid=True  captures/policies/32/shop-frontend-merged-again.yaml Allow ingress to shop/frontend in cf2cnp-lab27: from pos on TCP/80
  cf2cnp-lab27/shop-frontend         Valid=True  captures/policies/32/shop-frontend-merged.yaml Allow ingress to shop/frontend in cf2cnp-lab27: from pos on TCP/80
  cf2cnp-lab27/shop-frontend         Valid=True  captures/policies/32/shop-frontend.yaml        Allow ingress to shop/frontend in cf2cnp-lab27: from pos on TCP/80
  cf2cnp-lab30/shop-backend          Valid=True  captures/policies/30/cnp-shop-l7.yaml          Allow ingress to shop/backend in cf2cnp-lab30: from shop/frontend on TCP/80 (HTTP GET /api
  cf2cnp-lab30/shop-frontend         Valid=True  captures/policies/30/cnp-shop-l7.yaml          Allow ingress to shop/frontend in cf2cnp-lab30: from pos on TCP/80 (HTTP GET /, GET /check
  shop-core/catalog                  Valid=True  captures/policies/35/cnp-shop.yaml             Allow ingress to catalog in shop-core: from orders on TCP/80; from api-gateway in shop-edg
  shop-core/orders                   Valid=True  captures/policies/35/cnp-shop.yaml             Allow ingress to orders in shop-core: from api-gateway in shop-edge on TCP/80
  shop-edge/api-gateway              Valid=True  captures/policies/35/cnp-shop.yaml             Allow ingress to api-gateway in shop-edge: from shopper in shop-clients on TCP/80
  shop-merchant/merchant             Valid=True  captures/policies/35/cnp-shop.yaml             Allow ingress to merchant in shop-merchant: from payment-gateway in shop-payments on TCP/8
  shop-payments/payment-gateway      Valid=True  captures/policies/35/cnp-shop.yaml             Allow ingress to payment-gateway in shop-payments: from orders in shop-core on TCP/80; fro
  shop-reviews/reviews               Valid=True  captures/policies/35/cnp-shop.yaml             Allow ingress to reviews in shop-reviews: from api-gateway in shop-edge on TCP/80; from ra
  files: 8 generated, 8 flow captures under captures/policies
```

### demo 26 — the lab's verdicts with the deciding policy (demos/26-cf2cnp-policy-from-flows/verify.sh 20m)

```
$ demos/26-cf2cnp-policy-from-flows/verify.sh 20m
policies in cf2cnp-lab: ciliumnetworkpolicy.cilium.io/pos ciliumnetworkpolicy.cilium.io/shop ciliumnetworkpolicy.cilium.io/shop-default-deny-ingress 
   152  pos        → coredns-57b76644f6-8lkgv         :53    FORWARDED                
    94  pos        → coredns-57b76644f6-5x48m         :53    FORWARDED                
    34  pos        → shop-6d7d797759-rbdsk            :80    FORWARDED                
    28  pos        → example.com                      :443   FORWARDED                
    25  pos        → coredns-57b76644f6-8lkgv         :53    REDIRECTED                by pos
    16  stranger   → shop-6d7d797759-rbdsk            :80    DROPPED   POLICY_DENIED  
    16  pos        → coredns-57b76644f6-5x48m         :53    REDIRECTED                by pos
     7  pos        → shop-6d7d797759-rbdsk            :80    FORWARDED                by pos
     7  pos        → shop-6d7d797759-rbdsk            :80    FORWARDED                by shop
     7  pos        → example.com                      :443   FORWARDED                by pos
     4  stranger   → coredns-57b76644f6-8lkgv         :53    FORWARDED                
     3  stranger   → shop-6d7d797759-rbdsk            :80    FORWARDED                
     2  stranger   → coredns-57b76644f6-5x48m         :53    FORWARDED                
```

### demo 30 — method+path pairs from the proxy's flows (demos/30-l7-rules/l7-summary.sh cf2cnp-lab30 300)

```
$ demos/30-l7-rules/l7-summary.sh cf2cnp-lab30 300
  n source → destination         type      method  path                   code  direction verdict    policy
  5 shop-frontend → shop-backend REQUEST   GET     /api/orders                  INGRESS   FORWARDED  -
  5 pos → shop-frontend          REQUEST   GET     /                            INGRESS   FORWARDED  -
  5 shop-frontend → pos          RESPONSE  GET     /                      200   INGRESS   FORWARDED  -
  5 shop-backend → shop-frontend RESPONSE  GET     /api/orders            200   INGRESS   FORWARDED  -
  5 pos → shop-frontend          REQUEST   GET     /checkout                    INGRESS   FORWARDED  -
  5 shop-frontend → shop-backend REQUEST   GET     /api/orders?id=42            INGRESS   FORWARDED  -
  5 shop-frontend → pos          RESPONSE  GET     /checkout              200   INGRESS   FORWARDED  -
  5 shop-backend → shop-frontend RESPONSE  GET     /api/orders?id=42      200   INGRESS   FORWARDED  -
```

### demo 35 — the platform's pairs with the deciding policy (demos/35-shop-platform/verdicts.sh 300)

```
$ demos/35-shop-platform/verdicts.sh 300
   28  shopper@shop-clients         -> api-gateway@shop-edge        FORWARDED api-gateway
    7  api-gateway@shop-edge        -> catalog@shop-core            FORWARDED catalog
    5  merchant-5c5cc7d9b6-g7t9c@shop-merchant -> catalog@shop-core            FORWARDED catalog
    5  orders@shop-core             -> catalog@shop-core            FORWARDED catalog
    4  reviews@shop-reviews         -> catalog@shop-core            FORWARDED catalog
    3  shopper@shop-clients         -> catalog@shop-core            DROPPED   (no policy named)
    9  stranger@shop-clients        -> catalog@shop-core            DROPPED   (no policy named)
    6  payment-gateway@shop-payments -> merchant@shop-merchant       FORWARDED merchant
    7  api-gateway@shop-edge        -> orders@shop-core             FORWARDED orders
    8  api-gateway-7d77448bf5-2z6p4@shop-edge -> payment-gateway@shop-payments FORWARDED payment-gateway
    1  orders-6ccc94b59d-bxkv5@shop-core -> payment-gateway@shop-payments AUDIT     (no policy named)
    6  orders-6ccc94b59d-bxkv5@shop-core -> payment-gateway@shop-payments FORWARDED payment-gateway
    1  stranger@shop-clients        -> payment-gateway@shop-payments AUDIT     (no policy named)
    8  stranger@shop-clients        -> payment-gateway@shop-payments DROPPED   (no policy named)
    7  api-gateway@shop-edge        -> reviews@shop-reviews         FORWARDED reviews
    6  ratings@shop-reviews         -> reviews@shop-reviews         FORWARDED reviews
```
