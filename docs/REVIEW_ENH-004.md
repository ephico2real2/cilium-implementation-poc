# Review record — enhancement 004, phase 0: the CI lab bring-up

Adversarial pass, 2026-09-14, on a 10-claim brief for `scripts/lab-up.sh`, `scripts/lab-preflight.sh`,
`scripts/lab-route.sh`, the workflow and the per-cluster address plan at `875b5d2`, after run 34796271073
had gone green (two kind clusters, meshed, Cilium's suite 87/87). The question put to the reviewers was not
"does it work on the runner" but "what breaks on the next real use": a MacBook, three clusters, route B, a rerun.
Reviewers: Cursor (Grok 4.6 high fast, ask mode, no shell) and Codex (GPT-5.6, xhigh, shell, own copy of the
tree). Every verdict below was re-checked here before a decision; the fixes were tested on this machine with
stubs, then measured on the runner (the runs named at the end).

| Claim | Cursor | Codex | Decision |
|---|---|---|---|
| C1 no mesh inside `cluster_up` | CONFIRMED | CONFIRMED (grep: no `clustermesh.*` before `mesh_up`) | held |
| C2 the users ConfigMap gate; `--wait` and the agents | CONFIRMED | REFUTED: the ConfigMap is mounted by the `etcd` container, not the init container; the agents watch the projected peer files (`config.go` 173–279), so `rollout restart` is not what makes them read the mesh | **accepted** — the restart is conditional on `cilium-config` changing; gotcha #96's wording corrected |
| C3 the local cluster in the list is ignored | CONFIRMED (docs) | CONFIRMED (`clustermesh.go` 168–172: "Ignoring configuration for own cluster") | held |
| C4 route B: `connect` after `config.enabled=true` | PLAUSIBLE: the CLI writes a map-keyed list over `[]` — demos/13's transcript has "cannot overwrite table with non table" | CONFIRMED (the CLI accepts a missing, map or empty-list value) | **accepted on the risk**: route B declares like route A and `connect` is gone; the shared `cilium-ca` is compared, not assumed |
| C5 the DNS probe | CONFIRMED | CONFIRMED (BusyBox-shaped stub, five SERVFAILs then AAAA) | held |
| C6 the address plan | CONFIRMED | CONFIRMED (`ipaddress`: inside, disjoint, offsets equal; pins .201/.240/.241 inside poc1's pools) | held |
| C7 preflight | PLAUSIBLE: `grep -c \|\| echo 0` → `0\n0`; empty `MemTotal` aborts under `set -u`; the netkit probe via iproute2 | REFUTED: BSD `sort -V` fine, iproute2 6.19 on Ubuntu 26.04 fine, manifest inspect fine — but `dmem=$(( $(true) / … ))` is a syntax error | **accepted**: defaults for every Docker field, `grep -c \|\| true`, the kernel's `/proc/config.gz` first for netkit |
| C8 the route script's L2 line | CONFIRMED | REFUTED: `${mac:+…}${mac:-…}` expands both halves — the MAC printed twice (run 34796271073 shows it) | **accepted**: one string built by a test, in the script and the workflow |
| C9 the workflow flags | CONFIRMED | CONFIRMED (`cli/connectivity.go`: `!` exclusions, the flag at line 223) | held |
| C10 reruns and a third cluster | REFUTED on the stop point (line 65, not Step 8); the rerun always restarts the agents; route B links only `$1` to the others | REFUTED: the core install has no `--reuse-values`, so a rerun resets the release (Hubble, the apiserver and route B's `cilium-ca` removed and regenerated per cluster); with `LAB_CLUSTERS_DIR=clusters` a poc3 dies at Step 5 on the values file | **accepted**: every per-cluster file checked before anything; an existing release skips the core install; the agents restart only on a config change; route B declares every pair |

## Accepted findings

**C2 — the agents read the mesh live (Codex).** *Finding:* `pkg/clustermesh/common/config.go` watches the
projected clustermesh files with fsnotify; the agent template says peer additions must not restart the agent.
*Re-check:* read the source; the DaemonSet hash is unchanged by the mesh values (Codex's render). *Decision:*
`agents_reread` snapshots `cilium-config`'s resourceVersion and the DaemonSet generation before each upgrade and
restarts only when the ConfigMap changed (Hubble's step needs it, gotcha #97) — Codex's "never restart" would have
lost that case, and Cursor's generation-only guard restarted on every rerun.

**C4 — route B declares (Cursor).** *Finding:* `connect` on a release that already carries a list is the shape that
failed in demo 13. *Re-check:* the transcript line is real; the `cilium-ca` copy at Step 4 precedes Cilium on every
other cluster, so Helm-method certificates chain to one CA. *Decision:* one `mesh_up` for both routes; the CA
fingerprints compared on route B as the root's are on route A. Codex's `--connection-mode mesh` alternative kept
`connect`; not taken. **Unmeasured until the route-B run named at the end:** the workflow input `certmanager=false`.

**C7 — the preflight's empty fields (both).** *Decision:* Cursor's defaults, Codex's syntax-error artefact; the
netkit row reads `CONFIG_NETKIT` from the VM kernel's `/proc/config.gz` first (Cilium creates netkit through
netlink; iproute2 is only a proxy) and falls back to the device test. Test T1/T2 in the session log.

**C8 / N2 — the doubled MAC (both).** *Decision:* the `if` form in both places; test T3.

**C10 — reruns (both).** *Decision:* the three per-cluster files checked at the top (Cursor's and Codex's block,
merged); `helm status` decides whether the core install runs; `agents_reread` for the restarts. Codex's full
per-step rewrite of the core block was not taken — the smallest change that closes the hole.

**N1 — the masked suite (Codex).** *Finding:* the connectivity step had no `pipefail`; run 34794243096's jobs were
green with `1/87 tests failed`. *Re-check:* test T5. *Decision:* accepted; gotcha #101 extended.

**N3 — macOS route detection (both).** *Finding:* `netstat` prints `172.18`, not `172.18.0.0`; the present-route
check could never match. *Decision:* Codex's `route -n get` gateway comparison (Cursor's awk on the abbreviated
column had the wrong prefix in its own test). Measured on this Mac: `gateway: 192.168.86.1` with no Step 3.5 route.

**N4 — the probe network's fixed name (Codex).** *Decision:* accepted; a per-process name and an `EXIT` trap.

**N5 — the dual-stack temp file (Codex).** *Decision:* accepted; removed after `kind create`, success or failure.

**Not asked #5 — IPv6 on the kind network (Cursor).** *Decision:* accepted in a simpler form: create with `--ipv6`,
fall back to IPv4-only with a warning unless `LAB_IPFAMILY=dual`, which dies by name — kind's own fallback.

## Rejected

- **Cursor #6, generation-only restart guard:** restarts on every rerun; superseded by the ConfigMap snapshot.
- **Codex C2 "no restart at all":** loses the Hubble case measured in run 34784194103 (gotcha #97).
- **Codex's `--connection-mode mesh` connect on route B:** keeps the CLI in a path the declaration already covers.

## Outcome

Ten claims; four held by both, four refuted or risked by both on the same points (the empty Docker fields, the
doubled MAC, the reruns, the macOS route), Codex alone on the masked suite and the watcher, Cursor alone on the
route-B `connect` and the IPv6 network. Every accepted fix has a stub test in the session log and is measured by the
runs that follow this record.
