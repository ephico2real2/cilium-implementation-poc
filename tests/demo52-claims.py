#!/usr/bin/env python3
"""demo 52's documentary claims match what was measured on kind-eg-poc2 (2026-09-19,
OB3 review) and the sources at the pinned versions.

1. Announcing node — README and RECAP may name `eg-poc2-worker` as the node that
   answers only where the same page states why: the door Services are
   `externalTrafficPolicy: Local` and MetalLB v0.16.0's L2 election keeps only nodes
   with a serving endpoint (speaker/layer2_controller.go ShouldAnnounce:
   `nodesWithEndpoint`). The memberlist/sha256 hash is not the reason; the pod's node is.
2. T8b — the unrouted service is not "Envoy answers 404": measured with
   `curl --http2-prior-knowledge` the door answers `HTTP/2 200` with `grpc-status: 12`
   and no grpc-message (Envoy converts its local reply for a gRPC request). Neither
   probe/nope.proto nor the README may claim a 404 on that path; the README names
   `grpc-status: 12`.
3. GRPCRoute precedence — the CRD (crds/gateway-api/v1.6.1 grpcroutes.yaml) ranks
   "Characters in a matching method" before "Header matches", and Envoy Gateway v1.9.1
   sorts Exact `/service/method` above Prefix `/service` (internal/gatewayapi/sort.go).
   The RECAP's "most specific first" table must list the GetOrder row before the
   x-version row; 50-routes.yaml must not describe rule (a) as a "method+header" rule.
4. D8 — enhancements/007 row D8 names every root eg-up.sh can export
   (.tmp/eg-root-ca.crt, .tmp/eg-poc1-root-ca.crt, .tmp/eg-poc2-root-ca.crt): three
   roots live today (fingerprints 6A:37:32…, 91:84:DE…, A3:D7:73…), not "two files".
5. Clean up — the README's cleanup paragraph names the pools before the uninstall
   (chart 0.16.0 templates its CRDs; the uninstall removes them).
usage: python3 tests/demo52-claims.py   (exit 0 = pass)
"""
import re, sys

bad = []
D = 'demos/52-eg-poc2-metallb/'
readme = open(D + 'README.md').read()
recap = open(D + 'RECAP.md').read()

# 1. announcing node ⇒ the ETP Local reason on the same page
etp_re = re.compile(r'externalTrafficPolicy:?\s*Local', re.I)
src_re = re.compile(r'nodesWithEndpoint|layer2_controller\.go')
for name, text in (('README.md', readme), ('RECAP.md', recap)):
    if 'eg-poc2-worker' in text and not (etp_re.search(text) and src_re.search(text)):
        bad.append('%s names the announcing node without the ETP Local reason '
                   '(externalTrafficPolicy: Local + layer2_controller.go nodesWithEndpoint)' % name)

# 2. T8b is grpc-status 12 on a 200, not a 404
nope = open(D + 'probe/nope.proto').read()
if '404' in nope:
    bad.append('probe/nope.proto claims a 404; the wire is HTTP/2 200 + grpc-status: 12')
if re.search(r'T8b[^\n]*404|404[^\n]*T8b', readme):
    bad.append('README ties T8b to a 404')
if 'grpc-status: 12' not in readme:
    bad.append('README does not state the measured T8b wire (grpc-status: 12)')

# 3. precedence: GetOrder row before the x-version row in the RECAP table
m = re.search(r'GRPCRoute rules \(most specific first\):\n\n(\|.*?)\n\n', recap, re.S)
if not m:
    bad.append('RECAP: GRPCRoute rules table not found')
else:
    rows = m.group(1).splitlines()
    idx = {k: next((i for i, r in enumerate(rows) if k in r), None)
           for k in ('GetOrder', 'x-version')}
    if None in idx.values() or idx['GetOrder'] > idx['x-version']:
        bad.append('RECAP GRPCRoute table: the GetOrder (method) row must precede the '
                   'x-version (header) row — the CRD ranks method characters before header matches')
routes = open(D + '50-routes.yaml').read()
if 'method+header' in routes:
    bad.append('50-routes.yaml: rule (a) is service+header, not "method+header"; '
               'the spec ranks a method rule above it')

# 4. D8 names every ROOT_CRT eg-up.sh exports
up = open('scripts/eg-up.sh').read()
roots = sorted(set(re.findall(r'ROOT_CRT=(\.tmp/\S+\.crt)', up)))
plan = open('enhancements/007-envoy-gateway-lab.md').read()
d8 = re.search(r'^\| D8 \|.*$', plan, re.M)
if not d8:
    bad.append('plan: row D8 not found')
else:
    for r in roots:
        if r not in d8.group(0):
            bad.append('plan D8 does not name %s (eg-up.sh exports it)' % r)

# 5. README clean-up paragraph: pools before the uninstall
m = re.search(r'^cleanup\.sh removes.*?(?=\n\n|\Z)', readme, re.M | re.S)
if not m:
    bad.append('README: cleanup paragraph not found')
else:
    p = m.group(0)
    if 'pool' not in p or p.find('pool') > p.find('uninstall'):
        bad.append('README cleanup paragraph: the pools must be emptied before the uninstall '
                   '(chart 0.16.0 templates its CRDs)')

for b in bad:
    print('CLAIM FAIL:', b)
print('demo52-claims: %d finding(s)' % len(bad))
sys.exit(1 if bad else 0)
