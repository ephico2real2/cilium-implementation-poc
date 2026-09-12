# Demo 17 — Tetragon (runtime security observability): blocked by this Docker Desktop, measured

## Summary context

[Tetragon](https://tetragon.io) is Cilium's eBPF runtime-security agent: process exec/exit events,
kprobe-based tracing policies, enforcement. Demo 10 named it as the runtime-tracing alternative to
the spans Hubble cannot produce. This demo set out to install it on poc1 the way the
[getting-started guide](https://tetragon.io/docs/getting-started/install-k8s/) does — and hit two
independent blockers, both measured, both recorded in [`output/transcript.txt`](output/transcript.txt).
Nothing about Tetragon itself is wrong; this rig cannot run it **yet**.

| Blocker | What | Fix | Who decides |
|---|---|---|---|
| **1. The VM kernel has no `CONFIG_SECURITY`** | Tetragon's base exec sensor attaches a kprobe to `security_bprm_committing_creds`; the symbol does not exist in Docker Desktop 4.27.2's `6.6.12-linuxkit` kernel → every agent crash-loops | Docker Desktop **≥ 4.30.0** — the config was restored there ([docker/for-mac#7250](https://github.com/docker/for-mac/issues/7250), closed 2024-05-06 as completed). This Mac runs 4.27.2; the cask offers 4.90.0 | you — it restarts the Docker VM, i.e. every kind node |
| **2. No `/procHost` mount on the nodes** | kind nodes have their own PID namespace; Tetragon detected it (`inode mismatch: procfs does not appear to be host procfs`) and, per [tetragon#4883](https://github.com/cilium/tetragon/issues/4883), then loses `pod`, `binary`, `exec_id` on kprobe events **silently** | the docs' `extraMounts: [{hostPath: /proc, containerPath: /procHost}]` + `tetragon.hostProcPath=/procHost`. kind mounts are creation-time only; Docker cannot add a bind mount to a running container | you — it means a cluster (re)build; the mount is now in `clusters/poc1.yaml`, `poc2.yaml` and `poc4.yaml` for the next one |

## Part 1 — the attempt, as run

**Pre-flight, recorded.** The node's PID namespace is not the VM's, there is no `/procHost`, and
the kernel does have BTF (so the FAQ's usual Docker-Desktop failure did not apply):

```
kind node pid ns:  pid:[4026533142]
VM root pid ns:    pid:[4026531836]
/procHost on node: ls: cannot access '/procHost': No such file or directory
6.6.12-linuxkit /sys/kernel/btf/vmlinux
```

**Install**, pinned to the newest chart, with a ServiceMonitor for the demo 16 stack
([`values-tetragon.yaml`](values-tetragon.yaml), every deviation commented):

```bash
helm search repo cilium/tetragon --versions | head -2              # 1.7.1 (app v1.7.1)
helm install tetragon cilium/tetragon --version 1.7.1 -n kube-system --kube-context kind-poc1 \
  -f demos/17-tetragon/values-tetragon.yaml
kubectl --context kind-poc1 -n kube-system rollout status ds/tetragon --timeout=5m
```

```
STATUS: deployed
error: timed out waiting for the condition                          ← ds/tetragon never became Ready
deployment "tetragon-operator" successfully rolled out

POD              NODE                  READY        CONTAINERS
tetragon-52m8r   poc1-worker2          true,false   export-stdout,tetragon
… ×5, all nodes                                                     ← the agent container, RESTARTS 5, CrashLoopBackOff
```

**The agent log, two lines that matter** (poc1-worker, `--previous`):

```
level=warn  msg="inode mismatch: procfs does not appear to be host procfs" path=/procRoot/1/ns/pid inode=4026533142 "expected inode"=4026531836
level=error msg="Failed to execute tetragon" error="sensor __base__ from collection __base__ failed to load:
  failed prog /var/lib/tetragon/bpf_execve_bprm_commit_creds.o kern_version 394764 loadInstance:
  attaching 'tg_kp_bprm_committing_creds' failed: creating perf_kprobe PMU (arch-specific fallback for
  \"security_bprm_committing_creds\"): token __x64_security_bprm_committing_creds: not found: no such file or directory"
```

The first is blocker 2 (Tetragon checks for exactly this). The second is blocker 1.

**Blocker 1 traced to the kernel config, not to Tetragon.** In the VM:

```
# CONFIG_SECURITY is not set
CONFIG_LSM="yama,loadpin,safesetid,integrity"
security_* symbols in kallsyms: 3
bprm symbols: bprm_change_interp bprm_execve free_bprm alloc_bprm cap_bprm_creds_from_file     ← no security_bprm_*
  security_bprm_committing_creds     0        ← what the sensor needs
  wake_up_new_task                   1        ← the sensor's other attach point, present
  acct_process                       1
```

And in Tetragon's source (`pkg/sensors/base/base.go`, v1.7.1) the base sensor lists exactly
`sched/sched_process_exec`, `kprobe/security_bprm_committing_creds` and `kprobe/wake_up_new_task` —
there is no alternative attach point to fall back to. Uninstalled after the evidence was captured;
five agents reloading BPF on every backoff were not worth keeping.

**Why this Docker Desktop.** [docker/for-mac#7250](https://github.com/docker/for-mac/issues/7250),
opened by a Cilium/Tetragon user in April 2024 with the same error on `6.6.16-linuxkit`
(Docker Desktop 4.28.0). The Docker maintainer's reply and the close:

> "sorry for breaking your workflow! I'll put that config back. Also, FYI, Docker Desktop uses its
> own kernel config, now. It's not using the Linuxkit config anymore." — 2024-04-22
> "It should be back in 4.30.0" — 2024-04-23
> "Closing this issue because a fix has been released in Docker Desktop 4.30.0" — 2024-05-06

This Mac: **Docker Desktop 4.27.2**, engine 25.0.3, kernel `6.6.12-linuxkit` — older than the
break *and* the fix (the config was dropped between 4.27 and 4.28 and restored in 4.30).
`brew info --cask docker-desktop` offers 4.90.0.

**Blocker 2, why the mount is not optional.** The getting-started guide only says *"Tetragon's
correct operation depends on access to the host /proc filesystem"*. [tetragon#4883](https://github.com/cilium/tetragon/issues/4883)
(open, 2026-04-18) measured what happens without it on Docker Desktop kind: the startup
`/proc` snapshot sees 41 % of processes (39 of 95), `wake_up_new_task` only tracks a child whose
parent is in the map, so missing ancestors exclude their whole subtree, and kprobe events for those
processes come out with `binary`, `exec_id`, `flags` and `pod` **empty** — "exec-only", with
pod-scoped tracing policies neutralised. That is the failure mode of a security tool that is
*running*: silent.

## Part 2 — what has to happen, in order (not run)

1. **Upgrade Docker Desktop** to the current cask (4.90.0). The VM restarts; every kind node comes
   back the way a reboot brings it back — re-pin addresses with `scripts/cluster-resume.sh` (gotcha #43).
   Verify the one fact this demo needs before anything else:

   ```bash
   docker run --rm --privileged --pid=host alpine nsenter -t 1 -m -u -- sh -c \
     'uname -r; zcat /proc/config.gz | grep "^CONFIG_SECURITY="; grep -c " security_bprm_committing_creds$" /proc/kallsyms'
   ```

   Expected: `CONFIG_SECURITY=y` and `1`.
2. **A cluster with the mount.** The `extraMounts` are now in the three cluster configs; they apply
   to the next `kind create`. Two ways to get one without touching poc1/poc2's state:
   - a throwaway `poc4` on the `kind-lab` network (the demo 13 pattern) — `clusters/poc4.yaml`
     has the mount and the design already reserves its ranges;
   - or the next full rebuild of poc1/poc2, which the day-1 rule (TUNING §6) wants anyway.
3. **Install with the docs' flag** — the values file gains one line, and then this demo's Parts 3+
   (exec events for the bank, a `TracingPolicy` on the Postgres data directory, the ServiceMonitor
   feeding the demo 16 Grafana) are written from recorded output like every other demo here:

   ```bash
   helm install tetragon cilium/tetragon --version 1.7.1 -n kube-system --kube-context kind-poc4 \
     -f demos/17-tetragon/values-tetragon.yaml --set tetragon.hostProcPath=/procHost
   ```

## What to take away

- **Two blockers, two owners.** The kernel one is Docker Desktop's version; the `/proc` one is
  kind's creation-time config. Neither is a helm value. Both are now written down where the next
  build will read them.
- **Tetragon's own warning was the tell.** `inode mismatch: procfs does not appear to be host procfs`
  is the check that #4883 describes; treat it as fatal even though the process keeps running.
- **Docker Desktop's kernel config is Docker's, not linuxkit's** (maintainer, above). Demo 06 proved
  the same for netkit, BBR and BIG TCP: the VM kernel is the ceiling of this lab, and it moves with
  Docker Desktop releases.

## Evidence

**Captures not taken yet** — blocked on this machine: Docker Desktop 4.27.2's kernel has no `CONFIG_SECURITY`, so every Tetragon agent crash-loops (gotcha #60; fixed in Docker Desktop 4.30). Captures to add on a kernel with LSM hooks: `tetra getevents` for a process exec and a policy violation, and the Tetragon Grafana dashboard. See [`output/screenshots/MISSING-CAPTURE.md`](output/screenshots/MISSING-CAPTURE.md) and [`/missing-captures.md`](../../missing-captures.md).
