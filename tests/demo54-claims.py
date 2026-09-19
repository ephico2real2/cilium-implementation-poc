#!/usr/bin/env python3
"""demo 54's documentary claims match the record and the accepted review decisions.

Rules, measured 2026-09-19 against output/transcript.txt and the sources:

1. docs/GOTCHAS.md #120 — `0.881` and `wget` are hand measurements, not in the
   transcript. They must not appear in the section (Grok finding 3 / Codex F3).
2. README and RECAP may say "zero preferred lifetime" only when the same
   document also writes the kernel reconciliation (net/ipv4/devinet.c
   set_ifa_lifetime → IFA_F_DEPRECATED / IFA_F_PERMANENT; inet_fill_ifaddr
   reports both lifetimes as infinity). Grok's "not a zero preferred lifetime"
   is rejected — kube-vip v1.2.4 pkg/vip/address.go:172-176 sets PreferedLft = 0.
3. No "every demo" for the /orders 503 — that path was 503 in demos 40/41
   (demo 41 README:125), not in every demo.
4. 45-shop-db.yaml — a sentence that cites the transcript may only name an
   HTTP status the transcript records (as "→ NNN" or "HTTP/x NNN"). The
   second apply recorded the body, not a status.
usage: python3 tests/demo54-claims.py   (exit 0 = pass)
"""
import re, sys

tx_lines = [l.rstrip() for l in open('demos/54-eg-poc1-kube-vip/output/transcript.txt')]
tx = '\n'.join(tx_lines)
bad = []

# 1. gotcha #120 — 0.881 / wget must be gone
g = open('docs/GOTCHAS.md').read()
m = re.search(r'## <a name="120"></a>120\..*?(?=\n## <a name=")', g, flags=re.S)
if not m:
    bad.append('GOTCHAS.md: section 120 not found')
else:
    body = m.group(0)
    for token in ('0.881', 'wget'):
        if token in body and token not in tx:
            bad.append('GOTCHAS #120 cites %r, which is not in the transcript' % token)

# 2. "zero preferred lifetime" only with the kernel reconciliation
kernel_re = re.compile(
    r'set_ifa_lifetime|IFA_F_DEPRECATED|inet_fill_ifaddr|devinet\.c',
    re.I,
)
for name in (
    'demos/54-eg-poc1-kube-vip/README.md',
    'demos/54-eg-poc1-kube-vip/RECAP.md',
):
    text = open(name).read()
    if 'zero preferred lifetime' in text and not kernel_re.search(text):
        bad.append(
            '%s says "zero preferred lifetime" without the kernel '
            'reconciliation (devinet.c set_ifa_lifetime / IFA_F_DEPRECATED)'
            % name
        )

# 3. no "every demo" for the /orders 503
for name in (
    'demos/54-eg-poc1-kube-vip/README.md',
    'demos/54-eg-poc1-kube-vip/RECAP.md',
    'demos/54-eg-poc1-kube-vip/GUIDE.md',
    'demos/54-eg-poc1-kube-vip/45-shop-db.yaml',
    'docs/GOTCHAS.md',
):
    text = open(name).read()
    if re.search(r'/orders.*every demo|every demo.*/orders', text, flags=re.I | re.S):
        bad.append('%s says /orders was 503 in every demo' % name)
    if re.search(r'had been 503 in every demo', text):
        bad.append('%s says 503 in every demo' % name)

# 4. shop-db header: a sentence that cites the transcript may only name an HTTP
#    status the transcript records (as "→ NNN" or "HTTP/x NNN")
y = open('demos/54-eg-poc1-kube-vip/45-shop-db.yaml').read()
header = ' '.join(l.lstrip('# ').rstrip() for l in y.splitlines() if l.startswith('#'))
for sent in re.split(r'(?<=[.!?])\s+(?=[A-Z`/])', header):
    if 'transcript' not in sent:
        continue
    for code in set(re.findall(r'(?<![\w.])([1-5]\d\d)(?![\w.])', sent)):
        if not re.search(r'(→|HTTP/\S+) %s\b' % code, tx):
            bad.append(
                '45-shop-db.yaml header cites the transcript for status %s, '
                'which the transcript never records' % code
            )

for b in bad:
    print('CLAIM NOT IN RECORD:', b)
sys.exit(1 if bad else 0)
