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
| The kind docker subnet on Linux is `172.18.0.0/16` — the PoC's LB pools (`172.18.255.200–250`), Gateway addresses (`.240`, `.241`) and `hosts-entries.sh` are written for it | `cilium/lb-ippool.yaml`, `docker network inspect kind` | on a Linux runner the pools apply unchanged; `/etc/hosts` is writable with `sudo` |
| Playwright with chromium installs on `ubuntu-latest` (`npx playwright install --with-deps chromium`); the PoC's captures are already playwright scripts (`scripts/evidence/capture.js`, `demos/16-monitoring/browser/*.js`) | Playwright docs; this repository | the screenshots move to CI as they are |

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
nothing), 13 (ztunnel), 17 (Tetragon needs the host's `/proc`), 20 (six JVMs), 22 (a third cluster).

### Phase 3 — the images and charts under test

The cf2cnp and hubble-policy-verdicts repositories already build and test themselves; the lab workflow takes their
**released** versions by default and accepts an input to test a branch build (`cf2cnp_ref`, `hpv_ref`): the job
builds the image on the runner (`docker build`, `kind load docker-image`) and vendors the chart from the branch —
the "run the generated image and the analysis" the operator described.

### Phase 4 — the MacBook

`scripts/lab-up.sh minikube poc1` on the MacBook (docker driver, one profile) for the single-cluster demos; kind
stays the tool for the mesh there too, unless phase 0 says otherwise.

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
