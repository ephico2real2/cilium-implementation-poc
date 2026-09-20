#!/usr/bin/env python3
"""demo 56's documentary claims match the record (the TENTH apply, transcript line 6960
on), the sources and the live cluster as measured on 2026-09-20 (OB3 review).

1. 41-shopapi-ha.yaml: required anti-affinity on its own label needs a rollout
   strategy that frees a node first — maxSurge 0 / maxUnavailable 1. With the
   default 25%/25% (0/1 on two replicas) the new pod never schedules; runs 7–9
   served from demo 54's old ReplicaSet (Progressing=False, ProgressDeadlineExceeded).
2. No number that is not in the tenth run: "Established in 25 s" (every run
   recorded "after 3s"), "t+47" (Ready=Unknown was t+51 in run 10, t+43 in run 9),
   "no SYN on the leaf" (no tcpdump in the record).
3. The speaker sends no password: neither the plan (006 §4 row 56, §9.2) nor the
   10a/10b header comments may say the password is inline / `:lab-bgp:`.
4. `65100 65102 65021` is recorded on leaf1 in the tenth run; the pages must
   still say the bounce lands on the leaf the spine did NOT pick.
5. README links fabric/.env.example, not the gitignored fabric/.env.
6. The silent-node sentence names the Envoy Gateway controller's node and the
   post-grace probe count (run 10: 0 of 4 probes after t+51 succeeded).
7. "Runs that did not go to plan" may quote a multi-word backticked string that
   is not in the transcript only with a source citation in the same sentence.
8. 006 §9.2 may not call the Mac route "measured" (the record: "Mac route absent").
usage: python3 tests/demo56-claims.py   (exit 0 = pass)
"""
import re, sys

D = 'demos/56-kube-vip-bgp/'
tx_lines = [l.rstrip() for l in open(D + 'output/transcript.txt')]
tx = '\n'.join(tx_lines)
bad = []

# 1. rollout strategy on the anti-affinity Deployment
ha = open(D + '41-shopapi-ha.yaml').read()
if 'podAntiAffinity' in ha and not re.search(r'strategy:\s*\n\s+type:\s*RollingUpdate\s*\n\s+rollingUpdate:\s*\n\s+maxSurge:\s*0\s*\n\s+maxUnavailable:\s*1', ha):
    bad.append('41-shopapi-ha.yaml: required anti-affinity without strategy maxSurge 0 / maxUnavailable 1 (the rollout deadlocks on two nodes)')

# 2. numbers not in the record
for f in ('10a-kube-vip-ds-bgp-election.yaml', '10b-kube-vip-ds-bgp-active-active.yaml', 'apply.sh', 'README.md', 'RECAP.md', 'GUIDE.md'):
    s = open(D + f).read()
    for needle in ('Established in 25 s', 'in 25 s', 't+47', 'no SYN on the leaf'):
        if needle in s and needle not in tx:
            bad.append('%s: "%s" is not in the record' % (f, needle))
sheet = open('demos/46-bgp-fabric/NETWORK-TEAM-SHEET.md').read()
if 'Established in 25 s' in sheet:
    bad.append('NETWORK-TEAM-SHEET.md: "Established in 25 s" is not in the record (every run: "after 3s")')

# 3. no password on the speaker — plan and manifest comments
plan = open('enhancements/006-bgp-tutorial.md').read()
for m in re.finditer(r'.*(65101:lab-bgp:false|password inline).*', plan):
    bad.append('006-bgp-tutorial.md: %s' % m.group(0).strip()[:100])
for f in ('10a-kube-vip-ds-bgp-election.yaml', '10b-kube-vip-ds-bgp-active-active.yaml'):
    s = open(D + f).read()
    if re.search(r'kube-vip takes it inline|Password inline in bgp_peers', s):
        bad.append('%s: header comment says the password is inline; the value is "::false"' % f)

# 4. the spine bounce
for f in ('README.md', 'RECAP.md', 'GUIDE.md'):
    s = open(D + f).read()
    if '65100 65102 65021' in s and not re.search(r'(not pick|did not pick|the other leaf|whichever leaf)', s):
        bad.append('%s: states AS path 65100 65102 65021 without saying the bounce lands on the leaf the spine did NOT pick' % f)

# 5. the .env link
if 'fabric/.env)' in open(D + 'README.md').read():
    bad.append('README.md: links fabric/.env (gitignored); link fabric/.env.example')

# 6. the silent-node sentence
for f in ('README.md', 'RECAP.md'):
    s = open(D + f).read()
    if 'envoy-gateway' not in s or not re.search(r'post_notready ok=0 fail=4|not one of the four', s, re.I):
        bad.append('%s: the silent-node result must name the envoy-gateway controller\'s node and the post-grace probe count (run 10: 0 of 4 succeeded)' % f)

# 7. quoted strings in "Runs that did not go to plan"
readme = open(D + 'README.md').read()
m = re.search(r'## Runs that did not go to plan(.*?)(?=\n## )', readme, flags=re.S)
if m:
    for sent in re.split(r'(?<=\.)\s+', m.group(1)):
        for q in re.findall(r'`([^`]+)`', sent):
            if len(q.split()) < 3:
                continue  # an identifier or a value, not a quoted line of output
            if q not in tx and 'Recorded:' not in sent and not re.search(r'(cmd|pkg)/[\w/.-]+\.go:[0-9]+', sent):
                bad.append('README.md runs-that-did-not-go-to-plan: `%s` is not in the record and has no source citation' % q[:60])

# 8. the Mac route
if re.search(r'the Mac through\s+the VM route', plan):
    bad.append('006 §9.2: "the Mac through the VM route" was not measured (record: "Mac route absent — the client0 half is the record")')

for b in bad:
    print('CLAIM FAIL:', b)
print('%d claim failures' % len(bad))
sys.exit(1 if bad else 0)
