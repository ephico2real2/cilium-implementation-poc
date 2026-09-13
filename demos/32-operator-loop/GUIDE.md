# Demo 32 — the guide: exercises

Run from the repo root with poc1 up, demo 27's lab enforced (`cf2cnp-lab27`) and demo 25's cf2cnp behind the
Gateway. Exercise 0 needs nothing but `gh`; 1 reads; 2 and 3 write into the lab; 4 needs a GitHub repository
of your own.

## Exercise 0 — the binary from the release, verified (E10)

```bash
mkdir -p .tmp/cf2cnp && cd .tmp/cf2cnp
gh release download v0.6.1 -R ephico2real2/cf2cnp -p 'cf2cnp_0.6.1_darwin_amd64.tar.gz' -p 'cf2cnp_0.6.1_checksums.txt' --clobber
shasum -a 256 -c --ignore-missing cf2cnp_0.6.1_checksums.txt && tar -xzf cf2cnp_0.6.1_darwin_amd64.tar.gz && ./cf2cnp merge --help | head -4
cd ../..
```

*Expect:* `cf2cnp_0.6.1_darwin_amd64.tar.gz: OK` and the `merge` help. Four archives (linux/darwin × amd64/arm64)
and one checksums file per tag — pick yours by `uname -sm`.

## Exercise 1 — every caller, then only the intended ones (E4)

```bash
demos/32-operator-loop/callers.sh cf2cnp-lab27/shop-frontend /tmp/frontend.ndjson 300
demos/26-cf2cnp-policy-from-flows/generate.sh /tmp/frontend.ndjson /tmp/all.yaml
QUERY="exclude=app.kubernetes.io%2Fname%3Dstranger" demos/26-cf2cnp-policy-from-flows/generate.sh /tmp/frontend.ndjson /tmp/intent.yaml
diff /tmp/all.yaml /tmp/intent.yaml
```

*Expect:* the stranger's flows are `DROPPED` and still become a rule in `all.yaml` — cf2cnp reads flows, not
verdicts; the diff is that rule, gone. Then open `https://cf2cnp.poc.local/`, paste `/tmp/frontend.ndjson` and
look above the *Policy name* field: the peer checklist. Untick `stranger`, generate — same result, and the
request the page sent carried `exclude=`.

## Exercise 2 — a new client, merged in (E5) (writes: a pod and the shop-frontend policy)

```bash
kubectl --context kind-poc1 apply -f demos/32-operator-loop/10-kiosk.yaml; sleep 15
kubectl --context kind-poc1 -n cf2cnp-lab27 exec kiosk -- sh -c 'wget -S -qO- --timeout=3 http://shop-frontend.cf2cnp-lab27/ 2>&1 | grep -m1 HTTP/; echo rc=$?'
hubble observe -P --kube-context kind-poc1 --from-pod cf2cnp-lab27/kiosk --to-pod cf2cnp-lab27/shop-frontend --last 40 -o json > /tmp/kiosk.ndjson
.tmp/cf2cnp/cf2cnp merge --existing demos/32-operator-loop/policies/shop-frontend.yaml --input /tmp/kiosk.ndjson --output /tmp/merged.yaml
diff demos/32-operator-loop/policies/shop-frontend.yaml /tmp/merged.yaml
.tmp/cf2cnp/cf2cnp merge --existing /tmp/merged.yaml --input /tmp/kiosk.ndjson --output /tmp/again.yaml && cmp /tmp/merged.yaml /tmp/again.yaml && echo idempotent
kubectl --context kind-poc1 apply -f /tmp/merged.yaml
kubectl --context kind-poc1 -n cf2cnp-lab27 exec kiosk -- sh -c 'wget -S -qO- --timeout=3 http://shop-frontend.cf2cnp-lab27/ 2>&1 | grep -m1 HTTP/'
```

*Expect:* `rc=1` first (dropped), `1 rule(s) added`, a diff of exactly seven added lines (the kiosk rule — with
0.6.0 it was the whole file, README Part 2), `0 rule(s) added` and `idempotent` the second time, then
`200 OK`. pos still answers, the stranger is still dropped.

## Exercise 3 — merge refuses the wrong file

```bash
.tmp/cf2cnp/cf2cnp merge --existing demos/27-cf2cnp-release/policies/cnp-shop.yaml --input /tmp/kiosk.ndjson --output /tmp/x.yaml; echo rc=$?
```

*Expect:* a refusal — demo 27's file holds two documents (`shop-backend` first); `merge` takes one policy for one
workload and says which target it found. The E10 template keeps one file per workload for this reason.

## Exercise 4 — policy as code, on your own repository (E10)

Create a repository, copy [`enhancements/templates/policy-pr.yml`](../../enhancements/templates/policy-pr.yml) to
`.github/workflows/`, commit a flows file and the policy file it should evolve, turn on *Settings → Actions →
Allow GitHub Actions to create and approve pull requests*, then:

```bash
gh workflow run policy-pr.yml -R <you>/<repo> -f flows=flows/kiosk.ndjson -f policy=policies/shop-frontend.yaml -f l7=false
gh run watch -R <you>/<repo>; gh pr list -R <you>/<repo>
```

*Expect:* four green steps (install with checksum, merge, `kubectl-validate` against the 1.20.1 CRD, the PR) and a
pull request whose diff is the added rule. Without the setting the last step fails with the exact message in
README Part 3 — that is the second thing the first run found.

## Cleanup

`demos/32-operator-loop/cleanup.sh` — removes kiosk and restores demo 27's policy; the repository and its PR stay.
