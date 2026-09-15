# Enhancement 004 — the lab in CI: the clusters built, the demos run and photographed by a GitHub Actions job

Status: **plan, researched 2026-09-13** — waiting on the operator's decision on the two questions in §5, then phase 0.

## 1. Why, in one paragraph

The afternoon of 2026-09-13 (demo 29 Part 10) was spent fighting the laptop, not the lab: a review job's `go test`
and six petclinic JVMs pushed the Docker VM's load average to 190 on 16 cores, Prometheus was killed by its own
liveness probe 21 times (gotcha #91), every dashboard capture had to be retaken, and a Tempo row that was built and
verified had to be parked for lack of memory. The operator's fluentd-hec project answers this the way a CI lab
should: a workflow builds the whole environment on a fresh runner, runs the tests against it, saves the evidence,
and throws the runner away. This plan brings the PoC's clusters, demos and screenshot captures onto GitHub-hosted
runners, so that "test everything we need for this lab" runs there — and a later minikube setup on the MacBook is a
second consumer of the same scripts, not a second lab.

## 2. The facts the plan rests on (measured or cited, 2026-09-13)

| Fact | Source | Consequence |
|---|---|---|
| `cilium-implementation-poc` is a **public** repository | `gh repo view` | standard runners are the public tier: **4 vCPU, 16 GB RAM, 14 GB SSD** on `ubuntu-latest` ([GitHub docs](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)); a private repository would get 2 vCPU / 8 GB, and larger runners are a paid, organisation-level feature ([larger runners](https://docs.github.com/en/actions/reference/runners/larger-runners)) |
| A job runs at most 6 hours; a workflow 35 days; artifacts default to 90 days | GitHub docs (usage limits) | one job per demo group, not one job for the whole lab |
| The lab today: poc1 = 3 control planes + 2 workers, poc2 = 1 + 1, Cilium 1.20.1 on kind v0.33.0 with `kindest/node:v1.36.4`, kube-prometheus-stack, Loki, Tempo, the observer, ~10 GB resident on the VM | `docker stats`, `clusters/*.yaml`, `cilium/values-*.yaml` | the CI clusters must be smaller: **poc1 = 1 control plane + 1 worker, poc2 = 1 + 1**, one stack per job |
| The fluentd-hec pattern: pinned `MINIKUBE_VERSION` / `KUBERNETES_VERSION`, `minikube start --driver=docker --container-runtime=containerd --cpus 2 --memory 4096 -n 2`, wait loops with deadlines and `::error::` annotations, a debug workflow on `workflow_dispatch` | `ephico2real2/fluentd-hec` `.github/workflows/ci_build_test.yaml`, `debug-splunk-pod.yaml` | the shape to keep: pinned versions, explicit waits, a dispatchable debug job |
| **minikube cannot put two profiles on one docker network.** `--network <shared>` for a second profile fails with "can't create with that IP, address already in use" (the IP is computed from the node index, not the profile); the issue is closed *not planned* | [kubernetes/minikube#14799](https://github.com/kubernetes/minikube/issues/14799) | two minikube clusters cannot see each other's node IPs, which ClusterMesh needs |
| `--static-ip` (docker driver) is ignored when combined with `--network`; the PR that would fix it is open | [kubernetes/minikube#19284](https://github.com/kubernetes/minikube/issues/19284), [tutorial](https://minikube.sigs.k8s.io/docs/tutorials/static_ip/) | the one flag meant to solve #14799 does not work today |
| The two workarounds in #14799: (a) `docker network connect --alias` both KIC containers to a third network after start; (b) a proxy on the host, reached from the clusters as `host.minikube.internal` | #14799 comments (the operator pointed at (b)) | (a): the nodes carry a second IP the kubelet did not register — Cilium's tunnels and the mesh apiserver use the node's InternalIP, so `kubelet.node-ip` must be set before start; (b): a TCP proxy carries the **control plane** (`cilium clustermesh connect --destination-endpoint host.minikube.internal:<port>` reaches the other cluster's clustermesh-apiserver) but not the **datapath** — ClusterMesh needs "IP connectivity between nodes using the configured InternalIP" and "pods in all clusters must have IP connectivity between each other" ([Cilium ClusterMesh setup](https://docs.cilium.io/en/stable/network/clustermesh/setup/)), i.e. VXLAN between node IPs and pod-to-pod packets, which no host proxy forwards. (b) alone gives cross-cluster service reachability through the host, not a mesh |
| **What actually blocks two minikube profiles from meshing is Docker's own rule, not minikube's:** Docker isolates user-defined bridge networks from each other with the `DOCKER-ISOLATION-STAGE-1/2` chains, and reserves the `DOCKER-USER` chain, evaluated before its own rules, for the administrator's exceptions | [Docker bridge driver](https://docs.docker.com/engine/network/drivers/bridge/), [Docker and iptables](https://www.net7.be/blog/article/docker_iptables.html) | give each profile its own network (minikube's default) and let the host route between the two bridges — two `iptables -I DOCKER-USER -i br-<poc1> -o br-<poc2> -j ACCEPT` rules and the reverse — and every node IP is routable from the other cluster, VXLAN included: ClusterMesh's prerequisite, met without `--network` or `--static-ip`. A Linux runner has root; the MacBook's Docker VM can be reached with the `nsenter` trick `demos/20-springboot/scale.sh` already uses. This is the path phase 0 measures first |
| Cilium's own documentation on minikube: with the docker driver "kube-proxy replacement features like host-reachable services may not work" | [Cilium docs, minikube](https://docs.cilium.io/en/v1.9/gettingstarted/minikube/) (the page exists only up to 1.9; newer docs dropped minikube) | KPR on minikube/docker is unsupported territory; demo 03 and demo 11 rest on KPR |
| **kind puts every cluster on the one `kind` docker network** — that is how poc1 and poc2 mesh today, and how Cilium's own CI meshes two clusters on GitHub Actions: `conformance-clustermesh.yaml` creates cluster 1 and cluster 2 with `helm/kind-action` and two config files | [cilium/cilium conformance-clustermesh.yaml](https://fossies.org/linux/cilium/.github/workflows/conformance-clustermesh.yaml); `docs/SETUP.md` | the mesh-in-CI problem is solved upstream with kind, on the same runners |
| `helm/kind-action` creates several clusters in one job (called twice with `cluster_name` and `config`); default kind v0.33.0 — the PoC's version | [helm/kind-action](https://github.com/helm/kind-action) | the PoC's `clusters/*.yaml` and `cilium/values-*.yaml` port with one change: node count |
| `medyagh/setup-minikube` takes `start-args` ("any flags you would regularly pass"), one profile per invocation | [setup-minikube](https://github.com/marketplace/actions/setup-minikube) | fine for a single-cluster job; the multi-profile limit is minikube's, not the action's |
| The kind docker subnet on Linux is `172.18.0.0/16` — the PoC's LB pools (`172.18.255.200–250`), Gateway addresses (`.240`, `.241`) and `hosts-entries.sh` are written for it | `cilium/lb-ippool-poc1.yaml`, `docker network inspect kind` | on a Linux runner the pools apply unchanged; `/etc/hosts` is writable with `sudo` |
| Playwright with chromium installs on `ubuntu-latest` (`npx playwright install --with-deps chromium`); the PoC's captures are already playwright scripts (`scripts/evidence/capture.js`, `demos/16-monitoring/browser/*.js`) | Playwright docs; this repository | the screenshots move to CI as they are |

### 2.1 Measured on the runner (phase 0, first runs, 2026-09-13)

| What | Measured | Where |
|---|---|---|
| the runner | `6.17.0-1022-azure`, 4 vCPU, 15,989 MB, `default_qdisc=fq_codel`, congestion controls `reno cubic` (BBR is the `tcp_bbr` module, loaded with `modprobe`) | [run 34784194103](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/34784194103) |
| two kind clusters (1 + 1) with Cilium 1.20.1, KPR, Hubble | up in **3 min 15 s** from checkout; 4,141 MB used with both clusters, agents at 1.1 GB per control plane and 0.47 GB per worker | same |
| BIG TCP with the lab's VXLAN | the agent refuses to start: `BIG TCP in tunneling mode requires pending kernel support` — a Cilium rule (BIG TCP needs native routing), not a runner limit; dropped from the features entry, its own entry when wanted | same, job `kernel-features` |
| two meshed kind clusters, Gateway API, the pools, the mesh connected — the whole `lab-up.sh` | **291–334 s**; a Gateway programmed with `172.18.255.241` from the pool; `ClusterMesh: 1/1 remote clusters ready` on both; 5 GB used | [run 34785181164](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/34785181164) |
| the features the laptop's kernel refused, on the runner (`kernel-features`) | **netkit: `Device Mode: netkit`**; **dual-stack: KPR on IPv4 and IPv6, IPAM from `fd00:1:10::/64`, BPF masquerading for both**; BBR loaded on the host (`reno cubic bbr`) but **the bandwidth manager stays Disabled in kind**: the agent reads `/host/proc/sys/net/core/default_qdisc`, a sysctl of the host's network namespace only, and a kind node's own namespace has no such file — the laptop's "seven entries in net/core" was this too, not only linuxkit | same run, job `kernel-features` |
| a Helm change to Cilium's ConfigMap after install | rolls nothing; the operator kept its flags, and the agents died five minutes after the next restart with `Unable to find all Cilium CRDs necessary within 5m0s` — the mesh's certificate job then could not even get a network | same, job `base`; fixed in `scripts/lab-up.sh`: the Gateway API CRDs before Cilium, Gateway API in the one install |
| the mesh apiserver switched on without the mesh declared | `Init:0/1` for ten minutes, `FailedMount … configmap "clustermesh-remote-users" not found` — chart 1.20.1 mounts the users ConfigMap whenever TLS auth is not legacy but renders it only under `clustermesh.config.enabled` (gotcha #96) | [run 34791073921](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/34791073921); fixed: every member declared (name, address, port 32379) in the upgrade that turns the apiserver on, from live state — so all clusters are created before any is completed |
| the mesh declared on poc1 while poc2 had no Cilium yet | `cilium status --wait` spent its full 10 minutes on `controller remote-etcd-poc2 … failed to retrieve cluster configuration: not found` on every agent (KVStoreMesh reads each peer through the LOCAL apiserver's cache, which had nothing for poc2), `ClusterMesh: OK` on the same status; the run died at 00:26:34 after starting the step at 00:15:25 (gotcha #92) | [run 34791947500](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/34791947500), [run 34792046715](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/34792046715); fixed: the mesh became a phase after every cluster is complete and independent (`mesh_up`); the link is checked last, with every apiserver up |
| the kind docker network created by the script, subnet pinned, `--ip-range` the lower half | `created: 172.18.0.0/16 fc00:f853:ccd:e793::/64` at 00:14:33, both clusters up on it by 00:15:27 (gotcha #95) | run 34792046715, both jobs |
| poc1 alone, clusters created → core verified → DNS → pools → metrics-server → cert-manager root + issuer | **1 min 40 s** (00:15:29 → 00:17:13, job `base`); the whole column is per cluster, so two clusters cost twice that plus Hubble/mesh/Tetragon | run 34792046715 |
| the DNS probe | `external name resolved: Address: 1.0.0.1` followed by the warning that it had failed — `grep -m1` under `pipefail` (gotcha #93); the base job's probe found no answer 16 s after the CoreDNS roll — the probe landed before the new endpoints served | run 34792046715; fixed: captured then searched, six probes across the roll, the raw output printed and the run stopped on the last failure |
| one pool file (`cilium/lb-ippool.yaml`) applied to every cluster | not measured — the runs never reached poc2's Step 8; the operator caught it in the log: poc2 would have been given poc1's `172.18.255.200–250` on the same bridge, with no L2 policy of its own (gotcha #94) | fixed at `bed849f`: one /26 per cluster, `cilium/lb-ippool-<cluster>.yaml`, poc2 announcing; the workflow proves both clusters' addresses from the runner |
| **the whole bring-up, end to end — the first green** | `lab up: poc1 poc2` in **500 s** (`kernel-features`) / **566 s** (`base`) from `Step 0–1` to the mesh verified; per cluster ≈ 4 min (clusters created 00:56:23–00:57:23; poc1 core → DNS → its block → metrics-server → cert-manager → Hubble → Tetragon → "complete" at 01:00:57; poc2 the same by 01:04:19); `All 2 nodes are connected to all clusters`, `All 1 KVStoreMesh replicas are connected`, `ClusterMesh: 1/1 remote clusters ready` on both; Tetragon 2/2 on both; `Device Mode: netkit` in `kernel-features`; Hubble UI at `172.18.255.201`, the Gateway at `.241`, poc2's `rebel-base-lb` at **`172.18.255.136` — its own block — HTTP 200 from the runner** | [run 34794243096](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/34794243096) |
| Cilium's connectivity test, multi-cluster, on that lab | **86 of 87 tests passed** (`base`: 2/512 actions failed, 986 s; `kernel-features`: 4/816, 1403 s); the one failure is `check-log-errors/no-errors-in-logs`, which reads the agents' whole log: `Failed waiting for clustermesh synchronization` at poc1's restart while poc2 had no Cilium (the ordering, fixed by the mesh phase), `Error initially creating lease lock … already exists` once (client-go leader election losing the create race for an L2 lease at a rollout restart — an exception now, with the reason in the workflow), and in `kernel-features` the bandwidth manager's `could not read procfs` warning on every agent (the overlay no longer declares it) | same |
| `ping` to an L2-announced address | never answers; three addresses that served HTTP 200 were reported `NO ANSWER` (gotcha #104) — the probes are TCP + the neighbour table now | same |
| **the phase design, end to end — the first fully green run** | each cluster "complete and independent" with no mesh in it (poc1 at 01:36:39, poc2 at 01:39:05, from clusters created at 01:33:16), then `mesh_up`: apiserver on + 2 members declared per cluster in 33 s and 11 s, agents restarted with every apiserver up, `ClusterMesh: OK` on both; **`lab up: poc1 poc2` in 445 s**; from the runner: the Gateway `.241` and Hubble UI `.201` on poc1, `rebel-base-lb 172.18.255.136` on poc2, each `L2 ARP answered by <the lease holder's MAC>`; **Cilium's connectivity test: `All 87 tests (512 actions) successful`** (`base`, 890 s) and `All 87 tests (816 actions) successful` (`kernel-features`, 1273 s) — the log check clean on both | [run 34796271073](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/34796271073) |
| `Warning: cilium.io/v2alpha1 CiliumCIDRGroup is deprecated; use cilium.io/v2 CiliumCIDRGroup`, twelve times per job during test 49 | not the lab's and not cf2cnp's: cilium-cli's own `client-egress-to-cidrgroup-deny` / `-by-label` tests apply their `…-v2alpha1.yaml` CiliumCIDRGroup manifest whenever Cilium is newer than 1.17.0 (`connectivity/builder/client_egress_to_cidrgroup_deny.go`, unchanged on main; the switch was added by upstream commit `4b518c3f3`, whose title says the opposite — "for Cilium versions below v1.18"), the API server answers with the deprecation warning and client-go prints it (`warnings.go:107`). cf2cnp writes only `cilium.io/v2` CiliumNetworkPolicy / CiliumClusterwideNetworkPolicy (`internal/policy/types.go` line 62) and its `validate` refuses any other apiVersion (`generator.go` 186–189); it never emits a CiliumCIDRGroup. The tests pass; the warning ends when upstream flips the switch or drops the alpha manifest | same; upstream |
| the `⌛ Waiting for pod … to reach DNS server on … echo-same-node/echo-other-node pod` lines | Cilium's connectivity test deploying its own DNS test server inside the echo pods and waiting until each client can resolve through it — its readiness phase, not an error; in run 34794243096 the phase ran from the deploys at 01:06:43 to `Running 137 tests` at 01:11:26 on a 4 vCPU runner (image pulls included), and every test that followed passed. The same lines preceded a real failure once, run 34787222878's `Resolving timed out` (gotcha #98), which is fixed | runs 34794243096, 34796271073 |
| the reviewed head (`docs/REVIEW_ENH-004.md`), route A | `lab up: poc1 poc2` in **480 s** / 542 s; the agents restarted for nothing at the mesh phase (`cilium-config and the DaemonSet unchanged, no restart` — they read the declared peers through the projected volume's watcher); `All 87 tests successful` on both jobs, with the step's exit code now the suite's | [run 34864635454](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/34864635454) |
| **route B** (`certmanager=false`: Helm certificates, SETUP 9.3b) — the first time it ran anywhere but the laptop | the first attempt stopped at poc2's Hubble step: `Secret "cilium-ca" … exists and cannot be imported into the current release: invalid ownership metadata` (a copied Secret is not Helm's — run 34864652168); with the first cluster's CA passed as `tls.ca.cert`/`tls.ca.key` at install (the guide's "clean way"): `cilium-ca fingerprint identical in 2 clusters`, the same declaration as route A and no `connect`, `lab up` in **359 s** / 504 s, `All 87 tests successful` on both jobs | [run 34865986688](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/34865986688) |
| `Unable to contact Hubble Relay, disabling Hubble telescope and flow validation` in every connectivity run | the lab's relay requires a client certificate (demo 25's mTLS) and the CLI presents none; the suite passes without flow validation — phase 2 decides whether to hand the CLI the certificate | every run since the relay went mTLS |
| **`lab-route-b.yaml`** — the route-A workflow cloned for route B, end to end, with the guide's checks laid on the meshed lab (the operator's order: clusters set up, mesh available, only then route B's checks) | `lab up` **419 s** / 485 s; SETUP 9.3b: `one CA behind both clusters' mesh certificates` (the server certificates' `ca.crt` fingerprints and dates equal); 9.5: both clusters connected; demo 07 Part 4: 20 requests spread `8 poc1 / 12 poc2` (`base`) and `10 / 10` (`kernel-features`); Part 5, poc1's backends to zero: **18 of 20 answered by poc2, none by poc1** — two requests met a backend the datapath had not dropped 5 s after the scale-down (the laptop measured 20/20 after settling), so the check now waits for the EndpointSlice to empty and prints the exact count; Cilium's suite `All 87 tests successful` on both jobs (897 s / 1269 s) | [run 34872720896](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/34872720896) |
| `lab-route-b.yaml` as one job (the operator: no base entry there), the demo 07 client as the guide has it — one pod, waited for, warmed, `exec`'d for both parts | the missing two of twenty were the client's own start-up, not the mesh: a pod created per measurement answered 18 of 20 in Part 4 AND Part 5 (run 34879584075, 8/10 then 18) even with poc1's EndpointSlice measured empty; with one warmed pod: spread **10 / 10**, failover **20 of 20 by poc2** — the guide's numbers, on the runner | [run 34879584075](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/34879584075) (87/87, 1263 s), [run 34882806257](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/34882806257) (bring-up 490 s) |
| **`lab-observability.yaml`, first green run** — the stack on the meshed lab, the labs, the summaries, the captures | bring-up 481 s (route A); the stack: demo 09's Gateway with its wildcard certificate; demo 16: 15 ServiceMonitors, 31 dashboards provisioned, 18–29 Prometheus targets up within 2 min; Tempo ready; the collectors up in both clusters (poc2's exporting to the `tempo-central` global Service); Loki 1/1, the observer 1/1 from the fork's `develop` (200dcd3: cf2cnp 0.7.0, hubble-policy-verdicts 0.4.0 as subcharts), the cf2cnp route Accepted; OBI 2/2 on both clusters; **memory with everything up: 8,002 MB used of 15,989** (poc1's nodes 3.1 GB each, poc2's 1.7–2.0 GB); the labs: every call answered as the chapters expect (the kiosk dropped by demo 27's enforced default-deny, `rc=1`); demo 26's verify: `pos → shop :80 AUDIT 9`, `stranger → shop :80 AUDIT 7` beside the forwarded DNS and world flows; demo 30's l7-summary: the method+path pairs with their 200s; captures: Cilium Metrics 75 panels / 0 "No data", Hubble Metrics 33 / 0, the verdicts dashboard 45 / 0, the observer's flows 8 / 2, network overview 8 / 1, L7 HTTP 11 / 7 (two minutes of traffic), DNS 4 / 4 (no DNS visibility policy yet — demo 31's chapter), the Hubble UI's service map of cf2cnp-lab30 at 81.5 flows/s, cf2cnp's page | [run 34891888521](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/34891888521); the three runs before it found the certificate wait, the peer's namespace and gotcha #105 |
| the pipeline with the images step, the traffic loop and the wait, the captures on the run page | `scripts/lab-images.sh`: `bankdemo:local` built in 41 s (21 MB) and `routedemo:local` in 28 s, both loaded into both clusters before any manifest; the labs plus demo 02's Star Wars app (`Ship landed`, the exhaust port `403`, the xwing dropped), the bank in both clusters with demo 19's seven cell policies (four egress probes DENIED as the chapter records), demo 31's DNS-visibility policy; six rounds of every generator, then the wait: **HTTP 1.75 req/s, 2,819 DNS queries, 973 dropped verdicts, 132k flows, 1,942 observer lines in Loki**; captures: L7 HTTP **11 panels / 1 "No data"** (was 7 with the `client` reporter default; the policy sits on the servers), DNS 4 / 1, the observer's flows 8 / 0, both verdict dashboards 45 / 0, the Hubble UI's service maps of cf2cnp-lab30 (160 flows/s) and of the bank; published to the `ci-captures` branch under a time-and-job folder and shown on the run page (a summary strips data: URIs, discussion #35932); 8.0 GB of 16 with everything up | [run 34909704970](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/34909704970); the three runs before it found the bank's image (built on the laptop, never on a runner), gotcha #93 a second time, and the L7 reporter |
| the report on the run page (`scripts/lab-report.sh`: the demos' own checks after the traffic), the metrics wait extended to Tempo per cluster | run 34918170151, green: HTTP 1.69 req/s, 2,534 DNS queries, 917 dropped verdicts, 123,663 flows, 1,827 observer lines; **Tempo: 200 traces from poc1, 0 from poc2** — the report's demo 23 section said why: `services "otel-collector" not found` on poc2 (the stack applied demo 23's per-cluster Service on poc1 only, so OBI there had nowhere to send) and `global=[true]` on poc1's Service (the OBI step re-applied demo 18's global-annotated Service over demo 23's — gotcha #70's shape); the trouble-word column counted `failed=0` (2 and 7); the observer's flows dashboard showed cf2cnp-lab27 as 83% of the DROPPED flows (the lab never put demo 27's components under audit — its default-deny enforced from the start) and `example.com` as 39% (the recorded DNS-visibility policy pins the address example.com resolved to on its day). All four fixed in `c271ff2` | [run 34918170151](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/34918170151) |
| **the cf2cnp chapters and the pages as tests, first run** (`scripts/lab-policies.sh`, `scripts/capture/lab.yaml` with expectations, the forensic client, the petclinic, the strict wait) | run 34922062949 (cancelled by hand after the report step had sat 94 minutes): the lab up, images, stack, labs in 20 min; the petclinic's six services rolled out in ~2 min, host memory 10,548 → 12,357 MB, requests 1,536 Mi / limits 2,368 Mi; the forensic client Ready; the audit rounds; **chapter 26** — one INGRESS AUDIT flow captured, `http=200` from the API, `cf2cnp validate` 1 ok, the server dry run ok, `Valid=True`, audit off: `pos → shop FORWARDED by shop`, `stranger → shop DROPPED POLICY_DENIED`; **chapter 27** — 11 AUDIT flows kept (5 kiosk and 8 stranger left out), two policies, pos 200, the stranger and the kiosk rc=1; **chapter 32 stopped**: `merge` refused "the flows produce 2 policies" — the capture held both sides of the kiosk's flows (fixed: `--traffic-direction ingress`, the recorded file's shape); the enforced traffic and the wait: HTTP 1.66 req/s, 4,521 DNS queries, 781 dropped verdicts, 243,598 flows, 829 ICMP flows, 1,557 observer lines, **Tempo 200 traces from poc1 and 200 from poc2** (the collector Service on the peer); the report hung on demo 15's check from the forensic namespace (the cell denies it; the check's curls have no timeout — moved before the cell, every section under a 10-minute deadline); chapter 27's Valid check silently skipped (`kubectl apply -o json` is a `List` for two documents — gotcha #106) | [run 34922062949](https://github.com/ephico2real2/cilium-implementation-poc/actions/runs/34922062949) |

## 3. Decision: kind for the clusters, minikube where one cluster is enough

The operator asked for minikube and pointed at the host-proxy workaround in #14799. Measured against ClusterMesh's
prerequisites, that proxy reaches the other cluster's control plane but not its nodes or pods (§2), so it is not a
mesh. What does meet the prerequisite is the Docker-level fix in §2: one network per profile, as minikube already
does, and two `DOCKER-USER` rules on the host so the two bridges route to each other — then node IPs are reachable,
VXLAN runs, and `cilium clustermesh connect` needs no `--destination-endpoint` at all. That is untested on a runner
and is exactly what phase 0 tests first; what is still documented as unsupported is KPR on minikube's docker driver
(Cilium's minikube page), which demo 03 and demo 11 rest on. kind builds the PoC's topology with none of these
questions, on the same runner, the way Cilium's own CI does. So the position, pending phase 0:

- **kind for every job that needs poc1 + poc2, KPR, Gateway API or L2 announcements** — the PoC's own configs,
  scaled to 1 + 1 nodes. Nothing in the demos changes: same cluster names (`kind-poc1`, `kind-poc2`), same CIDRs,
  same pools, same `hosts-entries.sh`.
- **minikube for the single-cluster jobs that do not need KPR** (the cf2cnp lab of demo 26, the dashboard chart of
  demo 28, the observer of demo 25), because that is the fluentd-hec shape the operator knows and the shape the
  MacBook setup will take. `--cni=false`, Cilium installed by the same `scripts/install-cilium.sh` with
  `kubeProxyReplacement=false` there — and the job records `cilium status` so the difference is visible.
- **Phase 0 measures the minikube mesh first**, in a dispatchable job (§4): two profiles on their own networks,
  the two `DOCKER-USER` rules, distinct pod CIDRs, Cilium with `cluster.id` 1 and 2, `cilium clustermesh
  enable/connect`, `cilium clustermesh status --wait`, `cilium connectivity test --multi-cluster`, and `cilium
  status` with KPR on to see what the docker driver breaks. If it passes, the decision flips to minikube for
  everything — the operator's preference — and this section says so; if it does not, the job's log is the record,
  and the host-proxy variant is tried second for what it can give (control plane only).

## 4. The plan

### Phase 0 — two spikes, one dispatchable workflow each (a day)

- `lab-spike-kind.yaml` (`workflow_dispatch`): `helm/kind-action` twice with `clusters/ci/poc1.yaml` and
  `clusters/ci/poc2.yaml` (1 + 1 nodes, the PoC's CIDRs), `scripts/install-cilium.sh` for both, Gateway API CRDs,
  the pools, `cilium clustermesh enable/connect`, `cilium clustermesh status --wait`, `cilium connectivity test
  --multi-cluster`, then `scripts/verify.sh` — and `docker stats`, `free -m`, the job's wall clock, as the
  measurement. The budget question this answers: how much of the PoC fits in 4 vCPU / 16 GB.
- `lab-spike-minikube.yaml` (`workflow_dispatch`), **run first**: the minikube mesh of §3 step by step — `minikube
  start -p poc1 --driver=docker --container-runtime=containerd --cni=false --extra-config=kubeadm.skip-phases=addon/kube-proxy
  --extra-config=kubeadm.pod-network-cidr=10.10.0.0/16 --service-cluster-ip-range=10.11.0.0/16 -n 2` and the same
  for `poc2` with `10.20/16` and `10.21/16`; `iptables -I DOCKER-USER` both ways between the two `br-*` bridges
  (their names from `docker network inspect`); `scripts/install-cilium.sh` with `k8sServiceHost` = the profile's
  control-plane IP (`minikube -p poc1 ip`), `cluster.name`/`cluster.id`; the mesh; the connectivity test; then a
  Gateway and an L2-announced LoadBalancer from a pool inside each profile's subnet. Each step's output captured;
  the result recorded in this document either way.

### Phase 0, what the runs taught (the fifth cut of `lab-up.sh`, from the sysdump warnings of run 34787222878)

The sysdump is the lab's evidence file, and every "the server could not find the requested resource" in it was a
piece of the laptop lab missing from the CI lab. The bring-up now carries: the ten Gateway API v1.6.1 CRDs
vendored under `crds/` (TLSRoute, GRPCRoute, TCPRoute, UDPRoute, ListenerSet were absent); the egress gateway,
local redirect policy and endpoint-slice CRDs on (enhancement 002 needs the first two); metrics-server (the lab
never had one — HPA in 002 needs it); Tetragon 1.7.1 with the `/procHost` mount and the kernel-symbol check that
was demo 17's blocker on the MacBook; cert-manager v1.21.1 with demo 08's root and demo 24's order — Cilium on
Helm certificates first, then the root, then one upgrade that puts the mesh apiserver and Hubble on
`ClusterIssuer/ca-issuer`, then `connect` (no `clustermesh enable`, no certgen Job, no "Trying to get secret … by
deprecated name" poll); cilium-cli 0.20.0 (0.19.7 did not know 1.20's `CiliumCIDRGroup` v2). Warnings that stay,
by design: no `hubble-generate-certs` CronJob (the method is cert-manager, not cronjob), no `cilium-node-init`
(a cloud-provider DaemonSet), no `cilium-etcd-secrets` (no external kvstore).

### The order is a dependency order (operator, 2026-09-13)

The demos were built in stages on purpose, to teach; a lab built for testing does the right thing. `scripts/lab-up.sh`
makes **each cluster fully functional on its own** — the Gateway API CRDs, Cilium's core verified (status, nodes,
kube-proxy replaced), CoreDNS upstreams, the pools, metrics-server, cert-manager with the root (created once, copied
to every other cluster), then Hubble and the mesh apiserver in one upgrade on the issuer, then Tetragon — and only
then connects the mesh. The table of what must exist before what is at the top of the script. What that removed,
each measured in a run: Helm waiting on a Hubble UI LoadBalancer that had no pool yet; Helm certificates issued only
to be replaced by cert-manager's; a certgen Job whose secret the CLI polled for; Tetragon before its host was ready.

Two more rules from the same principle, added 2026-09-14 after runs 12 and 13:

- **The mesh is a phase on complete clusters, never a step inside one.** *"We need both clusters to be up and
  independent before creating or running clustermesh steps or scripts."* `cluster_up` finishes a cluster with no
  mesh in it — core, DNS, its LB block, metrics-server, its issuer, Hubble, Tetragon, each verified; `mesh_up` then
  runs on all of them: the apiserver on and every member declared (the CLI's `enable` as Helm values plus demo 24's
  list), the agents restarted once every apiserver exists, the strict `cilium status --wait` on each, then
  `clustermesh status --wait`. The link is pairwise, so it is the last thing checked (gotcha #92).
- **"Independent" includes the address plan.** *"A cluster is independent before it joined a mesh and this is true
  for the pool IPs reserved as well. So poc2 must have its own. We can subdivide what is reserved on the network
  between poc1 and poc2. This is how we set up in an enterprise."* (the operator). The reserved top /24 is
  subdivided into /26 blocks with one layout inside each — poc1 `.192/26`, poc2 `.128/26`, poc3 `.64/26`, `.0/26`
  for shared VIPs — one file per cluster, and the bring-up refuses a cluster without its block (NETWORKING_DESIGN
  §3 item 4, gotcha #94).

### Where it stands (2026-09-14, after run 34796271073)

| Phase | State |
|---|---|
| 0 — the spike | **done and green**: kind, two clusters, dependency order, the mesh phase, Cilium's own multi-cluster connectivity test `All 87 tests successful` on both matrix jobs; question 1 below is answered by measurement (kind; minikube cannot mesh two profiles) |
| 1 — the scripts | `lab-up.sh`, `lab-down.sh`, `lab-route.sh`, `gateway-api-crds.sh`, and now **`lab-stack.sh`** (demos 09, 16, 21, 10/22/23, 25, 18, the CLI's certificate), **`lab-apps.sh`** (the labs of 26, 27, 30, 32, 35 with their traffic), **`lab-capture.sh`** with `scripts/capture/walk.js` (a JSON spec of pages) — measured green in run 34891888521 |
| 2 — the workflow per demo group | **built, being measured**: `lab-observability.yaml` = the clusters and the mesh, the images built and loaded, the whole stack, the labs (26–35, the Star Wars app, the bank and the cell, demo 11's forensic client, demo 20's petclinic), traffic under audit, the cf2cnp chapters of 26/27/32/30/31/35 (`scripts/lab-policies.sh`: raw flows kept, policies generated through the API, validated three ways, applied, re-tested), the enforced traffic with a strict wait (Prometheus, Loki, Tempo from both clusters), the demos' own checks as a report on the run page, the pages captured with their expectations measured (every verdict-dashboard panel has data but the ones named with a reason; the Hubble UI shows the labs). Green through the report and the captures in runs 34891888521, 34909704970 and 34918170151 on the earlier shape; the chapters and the page tests first ran in 34922062949 (§2.1) |
| 3 — the images and charts under test | **not started** (cf2cnp and hubble-policy-verdicts still test only themselves) |
| 4 — the MacBook | pending phase 2 |
| the review pass on the bring-up | **not done**: `scripts/lab-up.sh`, the workflow and the per-cluster address plan have had no Codex/Cursor pass; they get one before phase 2 builds on them |

Two corrections to the plan below from what phase 0 measured: Tetragon is IN scope (it runs on the runner with the
`/procHost` mount, `tetragon 2/2` on both clusters), and the `policy-tools` group runs on kind like the others.

**Next, in order — what can be built while the MacBook is busy (2026-09-14):**

| # | Task | Needs | State |
|---|---|---|---|
| 1 | The review pass on the bring-up: `scripts/lab-up.sh` (`mesh_up`, the DNS probe, reruns, a third cluster), the address plan, `scripts/lab-preflight.sh`, `scripts/lab-route.sh`, the workflow — ten claims, both reviewers on copies | Codex + Cursor | **done and measured** (route A and route B green on the fixed head): `docs/REVIEW_ENH-004.md` — ten claims, eight accepted findings (the masked connectivity step, the doubled MAC, the empty Docker fields, reruns resetting the release, route B's `connect`, the macOS route check, the watcher-based agent restart, the temp file), measured by the two runs after it |
| 2 | Phase 1: `scripts/lab-stack.sh` from demos 09, 16, 21, 10/22/23, 25, 18 — deadline-guarded, measured on the runner beside the two clusters: 8 GB of 16 with everything up | the runner | **done** (run 34891888521) |
| 3 | Phase 2: one job per demo group — `lab-route-b.yaml` (SETUP 9.3b/9.5, demo 07) and `lab-observability.yaml` (the stack, the labs, the chapters of 26–35 generated and applied, the report, the captures as tests) are the first two; next: the per-demo self-description (`demos/<nn>/lab.yaml`: needs, apply, wait, traffic, check, pages — so adding a demo is adding paths, the operator's goal) and a generic runner over it | the runner | **the two jobs built**; the self-description not started |
| 4 | hubble-policy-verdicts follow-up: source before destination in the top-10 workloads table (chart 0.4.x, held by `hack/check-dashboard.py`) | the chart repo | not started |
| 5 | The 0.4.0 "top" capture with the who-talked-to-whom table populated | the laptop clusters resumed, or task 3's observability group | waits |
| 6 | Phase 3: `cf2cnp_ref` / `hpv_ref` inputs — build the image on the runner, `kind load`, vendor the chart | task 3 | not started |
| 7 | The schedule question, §5 item 2 | the operator | open |
| — | On the M5 (or this Mac once Docker Desktop 4.91.0 has launched once): `scripts/lab-preflight.sh`, then `scripts/lab-up.sh poc1 poc2` — the CI-size lab is the default (`clusters/ci`); the paused full-size clusters must be deleted first because the names collide (`scripts/lab-down.sh poc1 poc2`, the operator's call) | the Mac, 4 CPUs / 8 GB | waits |

### Phase 1 — the bring-up as scripts (what the MacBook will reuse)

- `scripts/lab-up.sh <kind|minikube> [poc1] [poc2]`: creates the clusters from `clusters/ci/*.yaml`, installs
  Cilium from `cilium/values-*.yaml` plus a `cilium/values-ci.yaml` overlay (no WireGuard, no bandwidth manager,
  Hubble relay + UI on, the L2 and pool settings), the Gateway API CRDs, the pools, the mesh when both clusters are
  asked for. Idempotent; prints what `docs/SETUP.md` prints, so the manual path and the CI path are one path.
- `scripts/lab-stack.sh <monitoring|loki|tempo|observer>`: the demo 16 / 21 / 25 installs from their values files.
- `scripts/lab-down.sh`.

### Phase 2 — the workflow, one job per demo group

`.github/workflows/lab.yaml` on `workflow_dispatch` (with a `demos` input) and on a weekly schedule; a matrix of
groups, each job: checkout → `lab-up.sh` → the group's stacks → the group's demo scripts under `scripts/record.sh`
→ `scripts/evidence/collect.sh` → playwright captures → `actions/upload-artifact` (transcripts, evidence, screenshots,
`cilium sysdump` on failure) → `lab-down.sh`. Groups by what they need:

| Group | Clusters | Stacks | Demos |
|---|---|---|---|
| core | poc1 | — | 01, 02, 03, 05, 08, 09 |
| mesh | poc1 + poc2 | — | 07, 29, 35 (the audit / verdict scripts) |
| observability | poc1 | monitoring, loki, observer | 16, 25, 26, 27, 28, 30–34 |
| policy-tools | minikube | observer, cf2cnp | 26 (API and page), 32 (the policy-PR template), 35 (regenerate and `cf2cnp validate`) |

Out of scope for CI, said so in the README: demo 06 / 11 / 14 (performance numbers on a shared runner mean
nothing — demo 11's client pod is used, not its measurements), 13 (ztunnel), 22 (a third cluster). Back in scope
by measurement: 17 (Tetragon runs with the `/procHost` mount) and 20 (the six JVMs fit: 8 GB of 16 were free with
every stack up in run 34909704970; the observability job deploys the petclinic behind the `springboot` input and
measures its memory).

### Phase 2b — every demo describes itself (the operator's goal, 2026-09-14: "identify the path of the yamls and add it")

Today the observability job knows the demos through three scripts' function bodies (`lab-apps.sh` deploys and
exercises, `lab-policies.sh` runs a chapter, `lab-report.sh` names a check) and one spec of pages. The shape to
grow into, so that adding a demo is adding paths and not editing three scripts: one `demos/<nn>-<name>/lab.yaml`
per demo, YAML because a person edits it —

```yaml
needs: [routes, monitoring, hubble-cli]        # the stacks (lab-stack.sh's steps) this demo reads
apply:   [10-lab.yaml, 20-http-visibility.yaml] # in order, `kubectl apply` on the context
ready:   [cf2cnp-lab30]                         # namespaces whose pods must be Ready
setup:   [demos/26-cf2cnp-policy-from-flows/audit-mode.sh shop Enabled]   # commands, in order
traffic: [demos/30-l7-rules/calls.sh]           # the round's generators (the observation is the pods' own loops)
chapter: 30                                     # a lab-policies.sh chapter to run once the traffic exists
check:   [demos/30-l7-rules/l7-summary.sh cf2cnp-lab30 300]   # the report's section(s)
pages:   [grafana-policy-verdicts, hubble-ui-cf2cnp-lab30]     # entries of scripts/capture/lab.yaml
```

and a generic runner (`scripts/lab-demo.sh <nn> apply|traffic|check`) that `lab-apps.sh`, the report and the
capture step read instead of their own tables. The chapters keep their own code (a chapter is a sequence with
measured lines, not a list of files), named from the descriptor. Not started; the three scripts are the reference
for what the descriptor must express, and every demo they run today is a test of the migration.

### Phase 3 — the images and charts under test

The cf2cnp and hubble-policy-verdicts repositories already build and test themselves; the lab workflow takes their
**released** versions by default and accepts an input to test a branch build (`cf2cnp_ref`, `hpv_ref`): the job
builds the image on the runner (`docker build`, `kind load docker-image`) and vendors the chart from the branch —
the "run the generated image and the analysis" the operator described.

### Phase 4 — the MacBook

kind on the MacBook too (phase 0 settled it), with the SAME cluster files and values as the runner; the operator's
next machine is an Apple silicon (M5 Pro) MacBook. What the research settled (2026-09-14): the `6.6.12-linuxkit`
kernel that refused netkit was Docker Desktop 4.27.2's (February 2024) on the 2019 Intel MacBook — Desktop 4.89.0
ships kernel v7.0.12 (release notes), on both CPUs, above netkit's 6.8 floor (Cilium 1.20.1 system requirements,
which also need `CONFIG_NETKIT` — measured, not assumed). The pinned `kindest/node` digest is the OCI index with
`linux/amd64` and `linux/arm64` (read from the registry), so nothing in `clusters/` changes for arm64. What does not
change with the chip: the bandwidth manager off inside kind nodes and BIG TCP off under VXLAN (gotcha #103). What is
unmeasured: Step 3.5's host route under Docker VMM (measured only on the Apple Virtualization framework with
`kernelForUDP`). `scripts/lab-preflight.sh` measures all of it on the machine before a cluster exists — the runner
prints the same table — so the M5's first command is that script, and its table is the record.

## 5. Two questions for the operator

1. **Run phase 0's minikube spike before choosing?** (§3) — if the `DOCKER-USER` route meshes two profiles on the
   runner, minikube everywhere is the answer; if not, kind for the mesh jobs and minikube for the single-cluster
   jobs, or minikube only with the mesh demos (07, 22, 29, 35) staying on the laptop.
2. **Which groups run on the weekly schedule** — all four (about four runner-hours a week, free on a public
   repository), or `core` and `policy-tools` only, the rest on dispatch?

## 6. Risks

- **The runner is 4 vCPU.** Two kind clusters with Cilium and Hubble fit (Cilium's own CI does it); adding
  kube-prometheus-stack, Loki and the observer to the same job is the phase 0 measurement, not an assumption. If the
  observability group does not fit, it splits.
- **Time.** Cluster bring-up is 3–5 minutes per cluster on a runner; a demo group of ten demos with captures is
  30–60 minutes. The 6-hour cap is far, the schedule's cost is not: it is the reason for question 2.
- **Flakiness the laptop hid.** A fresh runner has no image cache and no warm Prometheus: every demo script that
  waits for a condition needs a deadline (the fluentd-hec loops), and every capture needs Grafana's loading state
  checked (learned twice today).
- **minikube's docker driver and eBPF.** Even for single-cluster jobs, Cilium on minikube/docker is a path the
  Cilium project does not test; a job that fails there is a minikube finding, not a PoC finding, and the README
  says so.
