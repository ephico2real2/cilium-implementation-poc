# Captures not taken yet — demos/11-kube-proxy-vs-cilium

poc3 (kindnet + kube-proxy) is paused to keep memory for the observability stack; its forensic comparison is recorded in the transcript. Captures to add when poc3 runs again: the iptables chain counts on a poc3 node vs `cilium-dbg bpf lb list` on poc1, and `scripts/forensic.sh` output from both.

When they are taken, put them in this folder and link them from the demo README's **Evidence** section; then remove this file and the row in `/missing-captures.md`.
