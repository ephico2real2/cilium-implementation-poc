# hubble-observer 2.7.0 — upstream released the fork's work; what differs, and what it means for this lab

Source: `onzack/hubble-observer` has no GitHub Releases and no tags; its release is the chart version on `main`, pushed
to `oci://ghcr.io/onzack/helm-charts/hubble-observer` by `.github/workflows/helm-publish.yml`. On 2026-09-15 `main`
went `2.7.0-alpha → 2.7.0` (commit `665d540c`, "bump version to 2.7.0 and remove alpha flag"), and `helm show chart
oci://ghcr.io/onzack/helm-charts/hubble-observer` answers `version: 2.7.0, appVersion: 1.16.4` — fetched 2026-09-17.
The lab installs **the fork's `develop` branch**, not the published chart (`OBSERVER_BRANCH=develop`,
`scripts/lab-stack.sh:44`, through `demos/25-hubble-observer-loki/chart-from-fork.sh`); on poc1 today: release
`hubble-observer`, chart `hubble-observer-2.7.0`, the observer container on `quay.io/cilium/cilium:v1.20.1@sha256:ae9ea21f…`
and `cf2cnp` on `ghcr.io/ephico2real2/cf2cnp:0.9.0` (`helm list` / `kubectl get deploy`, 2026-09-17).

## In one paragraph

2.7.0 is the release that carries this lab's contributions: five of the fork's pull requests merged upstream on
2026-09-15 (#9 the pod's network policy, #10 the CLI-image documentation, #11 `fieldMask` and `extraArgs`, #13 the
policy-verdicts dashboard as an optional dependency, #14 `is_reply` kept in the mask). After merging, the maintainer
made six commits of their own — most notably **removing the `containerName` value** #13 had added, because with their
dashboard a second release under another container name showed nothing. The fork is 29 commits ahead of upstream and 0
behind (`compare onzack:main...ephico2real2:develop`): it keeps `containerName`, carries the dashboard of the still-open
PR #16 (whose `Container` variable is what makes `containerName` safe), the second-release example, and pins the
cf2cnp subchart to the fork's build. Nothing to move — the lab already runs everything 2.7.0 has and more; the work is
upstream hygiene: get #16 in, then re-propose `containerName` on top of it.

## What upstream did after merging our PRs (the six commits, `gh api repos/onzack/hubble-observer/commits?since=2026-09-15`)

| Commit | Change | The fork / the lab |
|---|---|---|
| `a1b6f474` fix: remove containerName value (would broke the dashboard) | `deployment.yaml` back to `name: {{ .Chart.Name }}`; the value and its comment deleted from `values.yaml` | The fork keeps it (`compare` shows the one-line deployment diff and the six-line value). The lab **does not set it** (`grep containerName demos/25-hubble-observer-loki/ scripts/` → nothing), so upstream and fork render the same container name here. Their reason is right for their dashboard: its LogQL hardcodes `container="hubble-observer"`; the fork's dashboard (PR #16) selects on a `Container` variable, so a second release *is* visible there. Order of merging decided this. |
| `2cc842c9` feat: update subchart 'hubble-policy-verdicts' | dependency `0.2.2 → 0.4.0` (from `https://ephico2real2.github.io/hubble-policy-verdicts` — our repository is upstream's source for that chart) | The lab enables it (`policyVerdictsDashboard.enabled: true`, `values-hubble-observer.yaml:105`); the fork's `Chart.yaml` names the same repository. Same chart both sides. |
| `473bb78d` fix: remove chart lock; `61e6729c` fix: remove temporary dependency charts (tar) | `Chart.lock` and the vendored `charts/cf2cnp-0.4.0.tgz`, `charts/hubble-policy-verdicts-0.2.2.tgz` deleted — the publish workflow resolves dependencies itself | The fork's `chart-from-fork.sh` runs `helm dependency build` from the forks' Helm repositories (`lab-stack.sh:193`); nothing vendored on our side either. |
| `7416aa1e` chore: remove confusing example | `examples/values-policy-verdicts.yaml` (the second release streaming `--type policy-verdict`) deleted | The fork keeps it; it depends on `containerName`, so removing one meant removing the other. The lab does not deploy a second release. |
| `ebdc8fd8` fix: update github actions | `actions/checkout@v7`, `azure/setup-helm@v5` (Helm version pin commented out), `docker/login-action@v4` | Fork workflows unchanged; only publishing is affected. |
| `665d540c` fix: bump version to 2.7.0 and remove alpha flag | `2.7.0-alpha → 2.7.0`, the OCI chart published | The fork's `Chart.yaml` is also `2.7.0` — the lab's `helm list` shows `hubble-observer-2.7.0`. Two different charts under one version number: **that is the divergence to watch** (see Actions). |

## What the fork carries that upstream does not (the `compare`'s nine files)

| File | +/− | What it is | Upstream state |
|---|---|---|---|
| `helm/hubble-observer/dashboard/cilium-hubble-flows.json` | +201 −39 | PR #16: *Flows per Drop Reason* and *Policy drops by denying policy* pies, the bars under Statistics named, the `Container` variable on every selector | **onzack/hubble-observer#16 open** since 2026-09-15, no review yet; one comment (ours, the README preview) |
| `templates/deployment.yaml`, `values.yaml` | +1 −1, +6 | `containerName` | removed upstream (`a1b6f474`) |
| `examples/values-policy-verdicts.yaml` | +46 | the second-release example | removed upstream (`7416aa1e`) |
| `Chart.yaml` | +12 −2 | cf2cnp dependency pinned `0.7.0` from `https://ephico2real2.github.io/cf2cnp` with the version history as a comment; upstream: `version: "*"` from `oci://ghcr.io/onzack/helm-charts` | upstream's `*` resolves to **cf2cnp chart 0.4.0, appVersion 0.3.1** (`helm show chart oci://ghcr.io/onzack/helm-charts/cf2cnp`) — everything in onzack/cf2cnp#3 (0.5.0 → 0.7.0, open) and the fork's 0.8.0/0.9.0 is absent from an upstream install |
| `README.md`, `docs/HUBBLE-CLI-IMAGE.md`, `assets/grafanadashboard.png` | +5 −1, +24 −7, binary | the dashboard preview and the CLI-image notes for the extended dashboard | follow #16 |
| `.gitignore` | +2 | local artefacts | — |

Not in either yet: the flow table's *Source Cluster* / *Destination Cluster* columns — **ephico2real2/hubble-observer#1**
(the fork's own PR, open for the operator); it goes upstream beside #16 once merged on the fork.

## Where the lab meets it

- The lab runs the fork branch, so 2.7.0 upstream changes nothing on the clusters. What it changes is the **story**:
  the fieldMask (`values-hubble-observer.yaml:21`, thirteen fields, −27 % per dropped flow), the pod's policy, the
  CLI-from-the-agent-image pattern (`:14`) are now upstream features, and demo 25's README can say so.
- A reader who installs **upstream** 2.7.0 gets our mask and policy but **cf2cnp 0.3.1** — no `download_url` behind a
  proxy, no ClusterMesh-aware selectors, no L7/DNS rules, no `merge`, no structured logging. The Grafana action of demo 26
  works against the fork's chart only until onzack/cf2cnp#3 lands. That is the cost of the split, and the reason the lab
  keeps installing from the fork.
- The fork's `Chart.yaml` pins the cf2cnp **chart** at 0.7.0 while the lab's values override the **image** to 0.9.0
  (`values-hubble-observer.yaml:76-77`): the 0.9.0 binary runs with the 0.7.0 chart's deployment (no `--log-format`
  args, so text logs — noted in `m5-resume-point`). Bumping the pin to 0.9.0 is a one-line fork change.

## Security

The observer runs the `hubble` CLI from the Cilium agent image, so its findings are the agent image's
([`../cilium-image-scan.md`](../cilium-image-scan.md)): 128 HIGH on the 1.20.1 digest it runs today, 13 on 1.20.2. The
chart's default image `quay.io/cilium/hubble:v1.16.4` (upstream's `appVersion`) is the unmaintained one PR #10
documented (last pushed 2024-11-21); upstream 2.7.0 still defaults to it — the values example in the merged docs is the
fix a reader has to apply.

## Cost of moving

Nothing to move for the lab. Two fork-side changes are cheap: `Chart.yaml` cf2cnp `0.7.0 → 0.9.0` (the chart the
0.9.0 binary was released with; gives the deployment its `--log-format json` args), and the observer image tag to the
1.20.2 digest together with the Cilium upgrade (`docs/upstream/releases/cilium-v1.20.2.md`, Cost of moving).

## Documentation this changes

- `demos/25-hubble-observer-loki/README.md` — a line that PRs #9/#10/#11/#13/#14 are upstream in 2.7.0 and what upstream
  changed afterwards (containerName removed, cf2cnp `*` → 0.4.0); the lab stays on the fork for cf2cnp ≥ 0.7.0 and the
  #16 dashboard.
- `docs/upstream/README.md` §3 — the observer row's status: five PRs merged in 2.7.0, #16 open; §5 this report.

## Actions

Done: this report; the demo 25 README line. For the operator: merge ephico2real2/hubble-observer#1 (then it can go
upstream); the cf2cnp chart pin 0.7.0 → 0.9.0 on the fork. Upstream, only on the operator's word: nudge #16 (a review
has not started; the maintainer merged five PRs in one day, so a short comment naming what changed since — the README
preview — is likely all it needs), and after it, a small PR re-adding `containerName` now that the dashboard's
`Container` variable makes a second release visible — the argument the maintainer's `a1b6f474` message lacked.
