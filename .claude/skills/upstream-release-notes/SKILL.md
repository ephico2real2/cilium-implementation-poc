---
name: upstream-release-notes
description: Pull an upstream release (cilium/cilium; onzack/hubble-observer and onzack/cf2cnp, whose "release" is a chart version and a fork/upstream divergence), summarise it, compare every item against what this lab actually runs — its values, scripts and demos — and write the report under docs/upstream/releases/, then update the lab's documentation and pins. Invoke when a new Cilium patch/minor lands, when an upstream we forked moves, or when the operator asks "what is new in X and how does it benefit us".
---

# Upstream release notes — fetch, compare with the lab, report, act

The operator's ask, verbatim (2026-09-17): *"we need create skill that we be using to pull and summarize release note
like you just did. In docs/upstream And create a formatted report and compare this to our demo Labs and update our
documentation. Don't forget our hubble observer upstream as well."* The first run — Cilium 1.20.2 against the lab on
1.20.1 — is the model: `docs/upstream/releases/cilium-v1.20.2.md`.

Two halves. **The script fetches** (`scripts/upstream-release-notes.sh`): the release text verbatim, the counts, the
lab's pins, keyword hits, and — for the forked projects — the chart versions, the fork/upstream divergence and our PRs
upstream. **You compare and write**: every "this touches us" claim is checked against the lab's files before it is
written, every "not for us" is a fact about our configuration, and the report says what to do and what it costs.

## Step 1 — fetch

```sh
scripts/upstream-release-notes.sh cilium v1.20.2         # or no version → the latest release
scripts/upstream-release-notes.sh hubble-observer         # onzack/hubble-observer: chart version on main, fork vs upstream
scripts/upstream-release-notes.sh cf2cnp                  # onzack/cf2cnp: tags, chart version, fork vs upstream
```

Each prints the path of a Markdown file under `.tmp/upstream/` with the material and the command behind every fact.
Read the whole file, not the keyword hits alone: the hits are where to start, the verbatim list is what you answer for.

## Step 2 — compare with the lab, item by item

For each release item that could touch the lab, find the lab's side **in the files**, and only then decide:

| The item is about | Look in |
|---|---|
| a Helm value or agent flag | `cilium/values-*.yaml`, `demos/16-monitoring/values-cilium-metrics.yaml`, `demos/*/values-*.yaml` — `grep -rn` the value; "not set" is a finding, write it |
| Gateway API, listeners, Envoy | demos 05, 09, 37; `enhancements/005-namespaced-gateway.md`; the measured numbers in `demos/37-two-gateways/output/` |
| L2 announcements, LB IPAM, `externalTrafficPolicy` | `cilium/lb-ippool-*.yaml`, `cilium/values-poc1.yaml` (`l2announcements`), demo 08, enhancement 005 |
| ClusterMesh | demos 21–24, `cilium/values-poc2.yaml`, `docs/GOTCHAS.md` #92–#94 |
| Hubble (metrics, export, relay, CLI) | demos 16, 22, 25, 26; `cilium/values-hubble-export.yaml` (dynamic exporter, `fieldMask`); `docs/HUBBLE-L7-LABELS.md`; the observer runs the `hubble` CLI from the **Cilium agent image** (`demos/25-hubble-observer-loki/values-hubble-observer.yaml` `tag:`) |
| policy, identities, named ports | demos 02, 03, 15, 26, 29–35; cf2cnp's generated policies (`demos/26-*/policies/`) |
| WireGuard / encryption | demo 04; `encryption.enabled` is **off** at baseline by design (`cilium/values-poc1.yaml`) |
| DNS / FQDN | demo 07; gotcha #63 (CoreDNS upstream) |
| BGP | `docs/summary/BGP_FRR_PLAN.md` — a plan, not running |
| the CI's connectivity test | `.github/workflows/lab-observability.yaml` (`cilium connectivity test --multi-cluster`) |
| security of the image | `docs/upstream/cilium-image-scan.md` — rescan the new tag with its §7 commands and update that file |

Rules of the comparison:

- **A claim about the lab is a grep, not a memory.** "We don't use `policy-deny-response`" is written only after
  `grep -rn policy-deny-response cilium/ demos/` returns nothing; quote the command in the report if the fact matters.
- **Read the upstream PR when the release line is ambiguous.** `gh pr view <n> -R cilium/cilium --json title,body`;
  the body's *release-note* block and `Fixes:` say what the symptom was. Quote it.
- **Distinguish four outcomes** for each item and write the one that applies: *fixes something we measured* (name the
  gotcha, demo or review that recorded it), *changes a constraint we wrote down* (name the file and line to update),
  *could hit us but has not* (the feature is in our values), *not for us* (the feature is not — say which value proves
  it). Do not pad the "for us" column: a patch release for a kind lab is mostly "not for us", and saying so is the
  value of the report.
- **Numbers from the release, not from the summary line.** Count the bullets; the script's count table is the source.
- **The forked projects' "release" is a divergence.** For hubble-observer and cf2cnp the questions are: what did
  upstream merge from us (our PRs, state, dates), what did upstream change that the fork does not have (the compare's
  file list — read the diff of each: `gh api repos/onzack/<r>/commits/<sha>`), what does the fork carry that upstream
  still lacks (open PRs), and does the lab set any value upstream removed (grep the demo's values and `lab-stack.sh`).

## Step 3 — write the report: `docs/upstream/releases/<project>-<version>.md`

Format, in this order, every section present (write "none" rather than dropping one):

1. **Title and provenance** — `# <Project> <version> — what is new, and what it means for this lab`; one paragraph:
   source (release URL / chart version and commit), published date, fetched when, counted how ("one minor change, 43
   bugfixes, 29 CI, 66 misc — `gh release view … --json body`"), what the lab runs today with the file:line of the pin.
2. **In one paragraph** — the release as a reader with no time needs it; kind of release (patch/minor), the one or two
   items that matter most to us, the verdict (move / wait / nothing to do).
3. **What touches this lab** — a table `| Fix or change (upstream PR) | Where the lab meets it | Outcome |`, one row
   per item with a lab side, the outcome one of the four above, with the file/gotcha/demo named. Order: fixes
   something we measured → changes a written constraint → could hit us → notable but neutral.
4. **Not for us** — one paragraph listing what was skipped and the value that proves each is not our configuration
   (ENI/EKS/GKE/Azure, DSR, IPv6, LocalRedirectPolicy, hostNetwork Gateways… as applicable).
5. **Security** — for Cilium: the image rescanned (`docs/upstream/cilium-image-scan.md` §7 commands) with the new
   totals against the previous ones; for the forks: the image/chart the fork publishes.
6. **Cost of moving** — the exact pins (file:line), the operation (`helm upgrade … --reuse-values` per cluster; an
   agent rollout = the Gateway off the air, gotcha #42), the order (poc1, verify, poc2), what verifies it (the demo
   checks, the dashboards, a green `lab-observability` run), and what the operator must decide.
7. **Documentation this changes** — the list of files updated because of this release, each with the sentence that
   changed (a constraint that no longer holds, a version row, a gotcha's "fixed in" line).
8. **Actions** — what was done (pins moved, PR number), what is recommended and left to the operator, what to watch.

Then link it: a row in `docs/upstream/README.md` §5 "Release reports" (create the section on first use), and the
root README's versions table if a pin moved. Run `scripts/mdfmt fix` on every file written.

## Step 4 — act, within the standing rules

- **Pins move in a PR**, never on `main` (protected). The bump of a Cilium patch is: `CILIUM_VERSION` in
  `scripts/lab-stack.sh` and `scripts/lab-preflight.sh`, the observer's `tag:` (the hubble CLI image, pinned by
  digest — take the digest from the release's *Docker Manifests*), the README's versions row, gotcha lines that say
  "fixed in". Then `helm upgrade cilium cilium/cilium --version <v> -n kube-system --kube-context kind-poc1 --reuse-values`,
  wait for the DaemonSet, run the demo checks that prove the doors and dashboards are back (demo 37 `check.sh`, demo 16's
  Grafana, demo 25's observer), then poc2, then the PR; the CI run on the branch is the proof the report cites.
- **Outward posts only on the operator's word** — an upstream issue, a comment on a PR, anything on a repository that
  is not ours. The report may *draft* them.
- The adversarial-review skill applies to the PR that moves a pin; the changelog skill records the session.
- Say what you did not do. A recommendation ("move to 1.20.2") is not an action until the operator says so.

## Cadence

Cilium ships a patch roughly every three to four weeks (`gh release list -R cilium/cilium --limit 5` shows the dates).
Run this skill when the operator asks, when the scan report's §7 shows a new tag, or at the start of a session that
will upgrade anything. Do not run it "to check" — the `.tmp/upstream/` file is cheap, the analysis is not.
