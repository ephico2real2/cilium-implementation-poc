# Review — the Cilium agent image rescanned (branch `docs-upstream-image-scan`, 2026-09-17)

The report's promise ([`docs/upstream/cilium-image-scan.md`](upstream/cilium-image-scan.md)): every number in it is
derivable from the scanner outputs it checks in, and its two reasoning steps — that the thirteen remaining findings
belong to the Ubuntu base image and to two `go.mod` lines on the `v1.20` branch, and that the vulnerable packages are
not linked into Cilium's binaries — are sound. Two reviewers, each in its own scratch copy. Codex (`codex exec -s
workspace-write`, gpt-5.6-sol, xhigh) had the report, both trivy tables, the five scanner JSON files and the three
binaries copied out of `quay.io/cilium/cilium:v1.20.2`, with a shell, `jq`, `strings` and Go; Cursor (`agent --mode
ask`, cursor-grok-4.6-high-fast) had the report alone and reasoned from the text. Same brief shape: three claims, a
verdict each (CONFIRMED / REFUTED / PLAUSIBLE), quoted evidence for every refutation. Every verdict was re-measured
before it was accepted.

## Verdicts

| Claim | Cursor | Codex | Outcome |
|---|---|---|---|
| C1 every number matches the files | CONFIRMED (internal arithmetic: 128 = 112 + 8 + 6 + 2, 13 = 8 + 3 + 2, 104, 115) | PLAUSIBLE — "mismatches: none"; the upstream digests and the base image's 2026-09-01 date are not in the supplied files | accepted; those two facts were measured in the session with `gh api` and `docker image inspect` and the report quotes the commands |
| C2 the "not linked" method and the CVE scopes | PLAUSIBLE — `strings \| grep` is a whole-file heuristic, not a pclntab parse; four sentences overstated | CONFIRMED — re-ran the counts (0 / 0 on both binaries, the x/crypto histogram identical), quoted the CVE descriptions from the JSON, "fair" | Cursor's four accepted (below); the method's wording now says what it is — a contrast, not a parse |
| C3 the pebble chain / nothing overstated | CONFIRMED — trivy counts per module version in build info, not per import (§2 said "that import them") | REFUTED — "the entrypoint is `cilium-agent`" is false: the image has no `Entrypoint`, its `Cmd` is `/usr/bin/cilium-dbg`; "nothing in the image references pebble" not established | both accepted; measured and rewritten (below) |

## What was corrected

- **§4, the entrypoint.** Codex read `.Metadata.ImageConfig.config` from the trivy JSON: `Entrypoint: null`,
  `Cmd: ["/usr/bin/cilium-dbg"]`. The sentence now says that, and that the chart's DaemonSet overrides it —
  measured on poc1, `kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].command}'`
  → `["cilium-agent"]`.
- **§4, "nothing references pebble".** Measured instead of asserted: `grep -rIl pebble /` over the image's filesystem
  returns nothing, `grep -c pebble` is 0 in `cilium-agent`, `cilium-dbg`, `hubble` and `cilium-cni`; the only traces
  are the binary and an empty `/var/lib/pebble`.
- **§6, x/crypto's binaries.** Candidate A listed `hubble` for CVE-2026-56854; trivy reports that CVE in
  `cilium-agent` and `cilium-dbg` only (§3 had it right). Fixed.
- **§5, the histogram.** The text said "the shipped binaries link `cryptobyte`…" with the histogram printed for
  `cilium-agent` alone; `cilium-dbg` (56/13/13/11) and `hubble` (56/13/13/11) were run and are printed.
- **§5, code search.** "Cilium has zero references to `grpc/xds`" was a repository search, which cannot see a
  dependency's imports; the sentence now says so and names the binary check as the one that counts.
- **§5 / §6, "not an exploitable one".** Replaced with what the evidence shows — the vulnerable package's code is not
  in the binary — without a claim about exploitability in general.
- **§2, how trivy counts.** "in the binaries that import them" → counted in every binary whose build info lists the
  module version; trivy matches the module version, not the import of the vulnerable package.

## What stands

The counts (Codex's `jq` reproduced 128 / 13 / 112 / 8, grype 55-204-30-2 and 7-99-7-2, the four per-binary totals,
the eight stdlib CVE ids with their packages, the three digests with their created dates); the pebble chain (`go
version -m` → go1.26.5, `github.com/canonical/pebble v1.32.2-0.20260721212932-7becfc3a9fad`; the current
`ubuntu:26.04` scan 0 / 0); both CVE scopes as quoted from the advisories in the JSON; the `strings` contrast (0 for
`x/crypto/ssh.` and `grpc/xds`, 59/56/56 for `cryptobyte.` in the same binaries).
