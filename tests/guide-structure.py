#!/usr/bin/env python3
"""demo-guide skill: a RECAP.md guide (--kind recap, default), README.md (--kind readme) or GUIDE.md (--kind guide) has the template's H2 headings in order (Troubleshooting optional), one H3
per step under Steps ("### N. <Imperative…>", numbered from 1), and in every step a fenced code block followed by a
line starting "Result:". usage: python3 tests/guide-structure.py demos/NN-slug/RECAP.md  (exit 0 = passes)

Every kind also gets rule 12, inside every ```bash, ```sh and ```shell block: no "$ " prompt; trailing comments on
one column, two spaces or more after their command; no line over 120 characters; a continuation line indented two
spaces from its command's first line; no blank line at a block's start or end, never two in a row. A # inside
quotes or in ${#var} is not a comment, and a heredoc's body is not read. Each problem is one line,
"<file>:<line>: bash block (rule 12): <what>"."""
import re, sys

SHELL = {"bash", "sh", "shell"}  # the info words of the blocks rule 12 applies to
WIDTH = 120
FENCE = re.compile(r"^( {0,3})(`{3,}|~{3,})\s*([^\s`]*)")
HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*\\?(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")  # <<EOF, <<-'EOF'; not <<<
WORD_START = " \t;&|()<>"  # a # starts a comment only at the start of a word: after one of these, or the line's start

KINDS = {
    "recap": (["What you get", "Architecture", "Prerequisites", "Steps", "Verify", "Reference", "Clean up", "What's next"],
              {"Troubleshooting"}, "Steps", r"Demo \d+ — .+"),
    "readme": (["Files", "Run it", "What was recorded", "Checks", "What is deliberately not here", "Clean up"],
               {"Runs that did not go to plan", "Summary context — the enterprise case"}, "What was recorded", r".+"),
    "guide": (["Prerequisites", "Exercises", "Clean up"], set(), "Exercises", r".+"),
}

def shell_blocks(text):
    """Each ```bash, ```sh or ```shell block as [(line index, line)], its fence's indent removed. A fence closes
    on the same character, at least as long, with nothing after it (CommonMark)."""
    blocks, fence, block = [], None, []
    for i, line in enumerate(text.splitlines()):
        if fence is None:
            m = FENCE.match(line)
            if m:
                fence = (m.group(1), m.group(2), m.group(3).lower() in SHELL)
                block = []
            continue
        indent, mark, shell = fence
        if re.fullmatch(rf" {{0,3}}{re.escape(mark[0])}{{{len(mark)},}}\s*", line):
            if shell:
                blocks.append(block)
            fence = None
        elif shell:
            block.append((i, line[len(indent):] if line.startswith(indent) else line.lstrip(" ")))
    return blocks


def lex(line, quote):
    """Read one line of shell, starting in the quote the line before left open (None, ', ", ` or $').
    Returns (the column of the # that starts a comment, or None; whether a backslash outside quotes continues the
    command on the next line; the heredocs the line opens, as delimiter words; the quote left open)."""
    i, heredocs = 0, []
    while i < len(line):
        c = line[i]
        if quote == "'":
            quote = None if c == "'" else quote
        elif quote:  # ", ` and $' take backslash escapes
            if c == "\\":
                i += 1
            elif c == quote[-1]:
                quote = None
        elif c == "\\":
            if i == len(line) - 1:
                return None, True, heredocs, None
            i += 1
        elif c == "#" and (i == 0 or line[i - 1] in WORD_START):
            return i, False, heredocs, None
        elif c == "$" and line[i + 1:i + 2] == "'":
            quote, i = "$'", i + 1
        elif c in "'\"`":
            quote = c
        elif m := HEREDOC.match(line, i):
            heredocs.append(m.group(2))
            i = m.end()
            continue
        i += 1
    return None, False, heredocs, quote


def bash_block(block):
    """(line index, what) for each rule-12 problem in one shell block, given as [(line index, line)]. A heredoc's
    body is not read; a line that starts inside a quote is data, so it is not checked for a prompt or an indent."""
    found, trailing = [], []
    quote, pending, heredoc, start, continued, blank = None, [], None, 0, False, False
    for k, (i, line) in enumerate(block):
        if heredoc:
            if line.strip() == heredoc:
                heredoc = pending.pop(0) if pending else None
            blank = False
            continue
        if not line.strip():
            where = "start" if k == 0 else "end" if k == len(block) - 1 else None
            if where:
                found.append((i, f"a blank line at the {where} of the block"))
            elif blank:
                found.append((i, "two blank lines in a row"))
            blank, continued = True, False
            continue
        blank = False
        if len(line) > WIDTH:
            found.append((i, f"a line over {WIDTH} characters ({len(line)})"))
        indent = len(line) - len(line.lstrip(" "))
        if quote is None:
            if continued and indent != start + 2:
                found.append((i, "a continuation line not indented two spaces from its command's first line"
                                 f" ({indent - start})"))
            if not continued:
                start = indent
                if re.match(r"\s*\$\s", line):
                    found.append((i, "a prompt ($) at the start of a line"))
        col, continued, opened, quote = lex(line, quote)
        if col is not None and line[:col].strip():
            trailing.append((i, col))
            if not line[:col].endswith("  "):
                found.append((i, "fewer than two spaces before a trailing comment"))
        pending += opened
        if pending and not continued and quote is None:
            heredoc = pending.pop(0)
    columns = sorted({c for _, c in trailing})
    if len(columns) > 1:
        first_off = next(i for i, c in trailing if c != trailing[0][1])
        found.append((first_off, "trailing comments not on one column (columns "
                                 f"{', '.join(str(c + 1) for c in columns)})"))
    return found


def rule12(path, text):
    """Every rule-12 problem in the page, as "<file>:<line>: bash block (rule 12): <what>", in line order."""
    return [f"{path}:{i + 1}: bash block (rule 12): {what}"
            for block in shell_blocks(text) for i, what in sorted(bash_block(block))]


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
    blocks = rule12(path, text)
    for problem in blocks:
        print(problem)
    if errors or blocks:
        return 1
    print(f"GUIDE STRUCTURE PASS ({kind}): {path}")
    return 0

if __name__ == "__main__":
    args = sys.argv[1:]
    kind = "recap"
    if args and args[0] == "--kind":
        kind = args[1]; args = args[2:]
    sys.exit(main(args[0], kind))
