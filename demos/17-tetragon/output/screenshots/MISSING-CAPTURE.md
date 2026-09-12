# Captures not taken yet — demos/17-tetragon

blocked on this machine: Docker Desktop 4.27.2's kernel has no `CONFIG_SECURITY`, so every Tetragon agent crash-loops (gotcha #60; fixed in Docker Desktop 4.30). Captures to add on a kernel with LSM hooks: `tetra getevents` for a process exec and a policy violation, and the Tetragon Grafana dashboard.

When they are taken, put them in this folder and link them from the demo README's **Evidence** section; then remove this file and the row in `/missing-captures.md`.
