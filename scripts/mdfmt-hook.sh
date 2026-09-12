#!/usr/bin/env bash
# mdfmt-hook.sh — Claude Code PostToolUse hook: after every Write/Edit of a *.md file inside this repository, run
# `mdfmt fix` on that one file and report what could not be fixed automatically. Reads the hook's JSON on stdin
# (tool_input.file_path). Exit 2 makes the remaining findings visible to the assistant so they get fixed by hand.
set -uo pipefail; cd "$(dirname "$(readlink -f "$0")")/.."
FILE=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("file_path",""))' 2>/dev/null)
case "$FILE" in *.md) ;; *) exit 0 ;; esac
case "$FILE" in "$PWD"/*) REL="${FILE#$PWD/}" ;; *) exit 0 ;; esac
git ls-files --error-unmatch "$REL" >/dev/null 2>&1 || [ -f "$REL" ] || exit 0
markdownlint-cli2 --fix "$REL" >/dev/null 2>&1
OUT=$(markdownlint-cli2 "$REL" 2>&1 | grep -E "^${REL}:" || true)
if [ -n "$OUT" ]; then echo "mdfmt: $REL still has findings after auto-fix — fix them by hand:"; echo "$OUT"; exit 2; fi
echo "mdfmt: $REL formatted and clean"
