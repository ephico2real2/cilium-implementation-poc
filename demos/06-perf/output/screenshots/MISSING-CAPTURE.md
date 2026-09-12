# Captures not taken yet — demos/06-perf

netkit, the bandwidth manager with BBR and BIG TCP cannot run on the Docker Desktop VM kernel (6.6.12-linuxkit; demo 06 Part 4 proves each); the iperf3 throughput runs themselves are recorded in the transcript. Captures to add on a real kernel: `cilium status` showing netkit/BBR/BIG TCP enabled, the before/after iperf3 numbers.

When they are taken, put them in this folder and link them from the demo README's **Evidence** section; then remove this file and the row in `/missing-captures.md`.
