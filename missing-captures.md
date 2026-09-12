# Captures not taken yet

Demos whose visual evidence is missing because the workload is scaled down, paused, deleted, or blocked by the Docker/kind lab (root README, "Scope"). Each demo's `output/screenshots/MISSING-CAPTURE.md` is the marker in the folder where the images will go; the row here is the index. Take them when the MacBook has the headroom, then delete both.

| Demo | Why not now | What to capture |
|---|---|---|
| [demos/06-perf](demos/06-perf/README.md) | netkit, the bandwidth manager with BBR and BIG TCP cannot run on the Docker Desktop VM kernel (6.6.12-linuxkit; demo 06 Part 4 proves each); the iperf3 throughput runs themselves are recorded in the transcript. | Captures to add on a real kernel: `cilium status` showing netkit/BBR/BIG TCP enabled, the before/after iperf3 numbers. |
| [demos/11-kube-proxy-vs-cilium](demos/11-kube-proxy-vs-cilium/README.md) | poc3 (kindnet + kube-proxy) is paused to keep memory for the observability stack; its forensic comparison is recorded in the transcript. | Captures to add when poc3 runs again: the iptables chain counts on a poc3 node vs `cilium-dbg bpf lb list` on poc1, and `scripts/forensic.sh` output from both. |
| [demos/13-ztunnel](demos/13-ztunnel/README.md) | poc4, the throwaway cluster ztunnel was evaluated on, was deleted (ztunnel cannot run with a `cluster.id`, so never on the meshed clusters). | Captures to add if rebuilt: the WireGuard vs ztunnel encryption status and the −73 % throughput comparison. |
| [demos/14-tcp-crr-tuning](demos/14-tcp-crr-tuning/README.md) | the tuning runs need a quiet VM (they measure TCP_CRR under load); the numbers are in the transcript. | Captures to add: netperf output before/after each sysctl on a VM with headroom. |
| [demos/17-tetragon](demos/17-tetragon/README.md) | blocked on this machine: Docker Desktop 4.27.2's kernel has no `CONFIG_SECURITY`, so every Tetragon agent crash-loops (gotcha #60; fixed in Docker Desktop 4.30). | Captures to add on a kernel with LSM hooks: `tetra getevents` for a process exec and a policy violation, and the Tetragon Grafana dashboard. |
| [demos/20-springboot](demos/20-springboot/README.md) | petclinic (six JVMs) is scaled to zero to keep memory for the observability stack (`demos/20-springboot/scale.sh`). | Captures to add after `scale.sh up` with ~3 GB of VM headroom: `https://petclinic.poc.local`, the Spring Boot 3.x Statistics dashboard (`springboot-19004`, per service), Hubble L7 for `api-gateway`, and its OTel Java agent traces in Tempo. |

Demo 12 (BGP with an FRR router) has no folder yet: it is planned in `docs/summary/BGP_FRR_PLAN.md` and parked.
