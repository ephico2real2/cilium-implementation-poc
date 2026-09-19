#!/usr/bin/env python3
"""demo-guide skill: a RECAP.md guide has the template's H2 headings in order (Troubleshooting optional), one H3
per step under Steps ("### N. <Imperative…>", numbered from 1), and in every step a fenced code block followed by a
line starting "Result:". usage: python3 tests/guide-structure.py demos/NN-slug/RECAP.md  (exit 0 = passes)"""
import re, sys

REQUIRED = ["What you get", "Architecture", "Prerequisites", "Steps", "Verify", "Reference", "Clean up", "What's next"]
OPTIONAL = {"Troubleshooting"}

def main(path):
    text = open(path, encoding="utf-8").read()
    errors = []
    h1 = re.findall(r"^# (.+)$", text, re.M)
    if len(h1) != 1 or not re.match(r"Demo \d+ — .+", h1[0]):
        errors.append(f"one H1 'Demo NN — <what you get>' expected, found {h1}")
    h2 = re.findall(r"^## (.+)$", text, re.M)
    seen = [h for h in h2 if h not in OPTIONAL]
    if seen != REQUIRED:
        errors.append(f"H2 order must be {REQUIRED} (+ optional Troubleshooting); found {h2}")
    unknown = [h for h in h2 if h not in REQUIRED and h not in OPTIONAL]
    if unknown:
        errors.append(f"H2 outside the template: {unknown}")
    # the Steps section
    m = re.search(r"^## Steps\n(.*?)(?=^## )", text, re.M | re.S)
    if not m:
        errors.append("no Steps section")
    else:
        body = m.group(1)
        steps = re.split(r"^### ", body, flags=re.M)[1:]
        if not steps:
            errors.append("Steps has no '### N. …' entries")
        for i, step in enumerate(steps, 1):
            title = step.splitlines()[0]
            if not re.match(rf"{i}\. [A-Z]", title):
                errors.append(f"step title must be '{i}. <Imperative…>', found '{title}'")
            if "```" not in step:
                errors.append(f"step {i} has no command block")
            if not re.search(r"^Result:", step, re.M):
                errors.append(f"step {i} has no 'Result:' line")
        if re.search(r"(?i)\b(first|second|third|fourth) (apply|run)\b", body):
            errors.append("Steps narrate a numbered run — the guide shows what works, the README keeps the record")
    # rule 3: commands live in fenced bash blocks, never inline in prose
    prose = re.sub(r"```.*?```", "", text, flags=re.S)
    prose = "\n".join(l for l in prose.splitlines() if not l.startswith("|"))
    inline = re.findall(r"`((?:sudo |RECORD_STRICT=\S+ )?(?:kubectl|curl|docker|helm|kind|arping|grpcurl|go run|bash|python3|route|netstat|openssl|scripts/\S+\.sh|demos/\S+\.sh)\b[^`]{4,})`", prose)
    for cmd in inline:
        errors.append(f"command inline in prose (rule 3 — use a ```bash block): `{cmd[:60]}`")
    if errors:
        print("GUIDE STRUCTURE FAIL:", *errors, sep="\n  ")
        return 1
    print(f"GUIDE STRUCTURE PASS: {path}")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
