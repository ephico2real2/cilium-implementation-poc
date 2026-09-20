#!/usr/bin/env python3
"""demo 56's documentary claims match the record (the LAST apply,
2026-09-20T19:53:33Z, transcript from that header to the end).

1. 41-shopapi-ha.yaml: required anti-affinity on its own label needs a rollout
   strategy that frees a node first — maxSurge 0 / maxUnavailable 1. With the
   default 25%/25% (0/1 on two replicas) the new pod never schedules; runs 7–9
   served from demo 54's old ReplicaSet (Progressing=False, ProgressDeadlineExceeded).
2. No number that is not in the last run: "Established in 25 s" (every run
   recorded "after 3s"), "t+47" (Ready=Unknown was t+55 in the last apply),
   "no SYN on the leaf" (no tcpdump in the record).
3. The speaker sends no password: neither the plan (006 §4 row 56, §9.2) nor the
   10a/10b header comments may say the password is inline / `:lab-bgp:`.
4. If a page states `65100 65102 65021` it must still say the bounce lands on
   the leaf the spine did NOT pick. The last apply does not record that path.
5. README links fabric/.env.example, not the gitignored fabric/.env.
6. The silent-node sentence names the Envoy Gateway controller's node and the
   post-grace probe count (last apply: 2 of 4 probes after t+55 succeeded).
7. "Runs that did not go to plan" may quote a multi-word backticked string that
   is not in the transcript only with a source citation in the same sentence.
8. 006 §9.2 may not call the Mac route "measured" (the record: "Mac route absent").
9. README and RECAP quote the last apply's A and B summary lines verbatim.
   The tenth apply's B numbers (node_notready_s=51, post_notready ok=0 fail=4,
   recovery_s=7) must not appear as this run. FRR on these pages is 10.7.1.
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

# 6. the silent-node sentence (last apply: 3 of 4 probes after t+51)
LAST_A = 'A summary: withdrawal_s=0 ok=12 fail=0 recovery_s=2'
LAST_B = ('B summary: bgp_withdraw_s=8 node_notready_s=51 first_ok_after_s=58 '
          'post_notready ok=3 fail=1 recovery_s=10 eg_controller_node=eg-poc1-worker')
for f in ('README.md', 'RECAP.md'):
    s = open(D + f).read()
    if 'envoy-gateway' not in s or not re.search(r'post_notready ok=3 fail=1|three of the four', s, re.I):
        bad.append('%s: the silent-node result must name the envoy-gateway controller\'s node and the post-grace probe count (last apply: 3 of 4 succeeded)' % f)

# 9. last-apply scenario numbers; earlier B numbers and FRR 10.5.3 must not linger
OLD_B = (
    'node_notready_s=55',
    'post_notready ok=2 fail=2',
    'post_notready ok=0 fail=4',
    'first_ok_after_s=55',
    'bgp_withdraw_s=13',
    '2026-09-20T14:01',
    '2026-09-20T17:49',
)
for f in ('README.md', 'RECAP.md', 'GUIDE.md'):
    s = open(D + f).read()
    if f != 'GUIDE.md':
        if LAST_A not in s:
            bad.append('%s: missing last-apply A summary: %s' % (f, LAST_A))
        if LAST_B not in s:
            bad.append('%s: missing last-apply B summary: %s' % (f, LAST_B))
    for needle in OLD_B:
        if needle in s:
            bad.append('%s: "%s" is the tenth apply, not the last run' % (f, needle))
    if '10.5.3' in s:
        bad.append('%s: FRR 10.5.3 is not this fabric (pin is 10.7.1)' % f)
    if re.search(r'BGP withdrew at 13 s', s):
        bad.append('%s: scenario B still says withdrew at 13 s (last apply: 8 s)' % f)
    if re.search(r'Ready=Unknown` at 55 s', s):
        bad.append('%s: scenario B still says not-ready at 55 s (last apply: 51 s)' % f)

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

# 9. the check recorded after the last apply: 16 rows, all PASS, and the pages cite it
starts = [i for i, l in enumerate(tx_lines) if l.startswith('$ demos/56-kube-vip-bgp/check.sh')]
if not starts:
    bad.append('no check.sh recorded in the transcript')
else:
    rows = [l for l in tx_lines[starts[-1]:]
            if l.startswith('  PASS') or l.startswith('  FAIL') or l.startswith('  WARN')]
    if len(rows) != 16 or sum(1 for l in rows if l.startswith('  PASS')) != 16:
        bad.append('last recorded check is not 16 rows / 16 PASS (%d rows, %d PASS)'
                   % (len(rows), sum(1 for l in rows if l.startswith('  PASS'))))
    for page in ('RECAP.md', 'README.md', 'GUIDE.md'):
        if '2026-09-20T19:56:30Z' not in open(D + page).read():
            bad.append("%s does not cite the recorded check's timestamp" % page)

for b in bad:
    print('CLAIM FAIL:', b)
print('%d claim failures' % len(bad))
sys.exit(1 if bad else 0)
