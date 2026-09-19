#!/usr/bin/env python3
"""demo-guide skill: a RECAP.md guide (--kind recap, default), README.md (--kind readme) or GUIDE.md (--kind guide) has the template's H2 headings in order (Troubleshooting optional), one H3
per step under Steps ("### N. <Imperative…>", numbered from 1), and in every step a fenced code block followed by a
line starting "Result:". usage: python3 tests/guide-structure.py demos/NN-slug/RECAP.md  (exit 0 = passes)"""
import re, sys

KINDS = {
    "recap": (["What you get", "Architecture", "Prerequisites", "Steps", "Verify", "Reference", "Clean up", "What's next"],
              {"Troubleshooting"}, "Steps", r"Demo \d+ — .+"),
    "readme": (["Files", "Run it", "What was recorded", "Checks", "What is deliberately not here", "Clean up"],
               {"Runs that did not go to plan", "Summary context — the enterprise case"}, "What was recorded", r".+"),
    "guide": (["Prerequisites", "Exercises", "Clean up"], set(), "Exercises", r".+"),
}

def main(path, kind="recap"):
    REQUIRED, OPTIONAL, STEPS_H2, H1_RE = KINDS[kind]
    text = open(path, encoding="utf-8").read()
    # headings are read outside fenced blocks (a `# comment` inside ```bash is not a heading)
    # (same length, newlines kept, so offsets and line numbers still line up)
    blank = lambda m: re.sub(r"[^\n]", " ", m.group(0))
    outside = re.sub(r"```.*?```", blank, text, flags=re.S)
    errors = []
    h1 = re.findall(r"^# (.+)$", outside, re.M)
    if len(h1) != 1 or not re.match(H1_RE, h1[0]):
        errors.append(f"one H1 matching '{H1_RE}' expected, found {h1}")
    h2 = re.findall(r"^## (.+)$", outside, re.M)
    seen = [h for h in h2 if h not in OPTIONAL]
    if seen != REQUIRED:
        errors.append(f"H2 order must be {REQUIRED} (+ optional {sorted(OPTIONAL)}); found {h2}")
    unknown = [h for h in h2 if h not in REQUIRED and h not in OPTIONAL]
    if unknown:
        errors.append(f"H2 outside the template: {unknown}")
    # the Steps section
    m = re.search(rf"^## {re.escape(STEPS_H2)}\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    if not m:
        errors.append(f"no {STEPS_H2} section")
    else:
        body = m.group(1)
        body_outside = re.sub(r"```.*?```", blank, body, flags=re.S)
        # split on H3s found OUTSIDE code blocks, but keep each step's full text (blocks included)
        starts = [m.start() for m in re.finditer(r"^### ", body_outside, re.M)]
        steps = [body[a:b] for a, b in zip(starts, starts[1:] + [len(body)])]
        steps = [st[4:] for st in steps]
        if not steps:
            errors.append("Steps has no '### N. …' entries")
        for i, step in enumerate(steps, 1):
            title = step.splitlines()[0]
            if not re.match(rf"{i}\. [A-Z]", title):
                errors.append(f"step title must be '{i}. <Imperative…>', found '{title}'")
            if "```" not in step:
                errors.append(f"step {i} has no command block")
            if kind == "recap" and not re.search(r"^Result:", step, re.M):
                errors.append(f"step {i} has no 'Result:' line")
            if kind == "guide" and not re.search(r"^\*\*Expect:\*\*", step, re.M):
                errors.append(f"exercise {i} has no '**Expect:**' line")
        if kind == "recap" and re.search(r"(?i)\b(first|second|third|fourth) (apply|run)\b", body):
            errors.append("Steps narrate a numbered run — the guide shows what works, the README keeps the record")
    # rule 3: commands live in fenced bash blocks, never inline in prose
    prose = re.sub(r"```.*?```", "", text, flags=re.S)
    prose = "\n".join(l for l in prose.splitlines() if not l.startswith("|"))
    inline = re.findall(r"`((?:sudo |RECORD_STRICT=\S+ )?(?:kubectl|curl|docker|helm|kind|arping|arp|grpcurl|go run|bash|python3|route|netstat|openssl|hubble|cilium-dbg|crictl|scripts/\S+\.sh|demos/\S+\.sh)\b[^`]{4,})`", prose)
    for cmd in inline:
        errors.append(f"command inline in prose (rule 3 — use a ```bash block): `{cmd[:60]}`")
    if errors:
        print("GUIDE STRUCTURE FAIL:", *errors, sep="\n  ")
        return 1
    print(f"GUIDE STRUCTURE PASS ({kind}): {path}")
    return 0

if __name__ == "__main__":
    args = sys.argv[1:]
    kind = "recap"
    if args and args[0] == "--kind":
        kind = args[1]; args = args[2:]
    sys.exit(main(args[0], kind))
