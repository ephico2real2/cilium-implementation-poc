#!/usr/bin/env bash
# Usage: bash tests/guide-structure-test.sh [path to guide-structure.py]
# Rule 12 of the demo-guide skill, as tests/guide-structure.py checks it: each case puts one bash block in a page
# that passes the heading and step checks, so only the block can fail it, and wants the checker's exit code and,
# for a failure, its "<file>:<line>: bash block (rule 12): <what>" line. Runs under bash 3.2 (macOS) and 5.
set -u
checker="${1:-$(dirname "$0")/guide-structure.py}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
page="${work}/page.md"
mismatches=0

# The block's first line is line 14 of the page.
write_page() {  # write_page <the block's info word>, the block on stdin
  {
    printf '# Demo test\n\nIntro.\n\n## Prerequisites\n\n- none\n\n## Exercises\n\n### 1. Run it\n\n'
    printf '```%s\n' "$1"
    cat
    # shellcheck disable=SC2016  # the backticks are Markdown fences, not a command substitution
    printf '```\n\n**Expect:**\n\n```text\nok\n```\n\n## Clean up\n\n- none\n'
  } > "${page}"
}

check_case() {  # check_case <name> <want exit> <want text in the output> [info word], the block on stdin
  local name="$1" want_exit="$2" want_text="$3" out got_exit verdict=ok
  write_page "${4:-bash}"
  out="$(python3 "${checker}" --kind guide "${page}" 2>&1)"
  got_exit=$?
  if [ "${got_exit}" -ne "${want_exit}" ] || [[ "${out}" != *"${want_text}"* ]]; then
    verdict=MISMATCH
    mismatches=$((mismatches + 1))
  fi
  printf '%-9s %-58s exit %s (want %s)\n' "${verdict}" "${name}" "${got_exit}" "${want_exit}"
  [ "${verdict}" = ok ] || printf '          output: %s\n' "${out}"
}

pass="GUIDE STRUCTURE PASS (guide)"
rule="${page}:"

# 12a: no prompt.
check_case "a: commands without a prompt" 0 "${pass}" <<'BLOCK'
kubectl get pods
kubectl get svc
BLOCK
check_case "a: a \$ prompt" 1 "${rule}14: bash block (rule 12): a prompt (\$) at the start of a line" <<'BLOCK'
$ kubectl get pods
BLOCK
check_case "a: a \$ prompt in a text block is not checked" 0 "${pass}" text <<'BLOCK'
$ kubectl get pods
BLOCK

# 12c: trailing comments on one column, two spaces or more after their command.
check_case "c: trailing comments on one column" 0 "${pass}" <<'BLOCK'
kubectl get pods  # the pods
kubectl get svc   # the services
BLOCK
check_case "c: trailing comments on two columns" 1 "${rule}15: bash block (rule 12): trailing comments not on one column (columns 18, 19)" <<'BLOCK'
kubectl get pods  # the pods
kubectl get svc  # the services
BLOCK
check_case "c: one space before a trailing comment" 1 "${rule}14: bash block (rule 12): fewer than two spaces before a trailing comment" <<'BLOCK'
kubectl get pods # the pods
BLOCK
check_case "c: a comment on its own line above the command" 0 "${pass}" <<'BLOCK'
# The pods, in every namespace.
kubectl get pods -A
BLOCK

# 12d: lines of 120 characters at most; a wrapped command's continuation lines indented two spaces.
check_case "d: a line of 120 characters" 0 "${pass}" <<BLOCK
echo $(printf 'x%.0s' $(seq 1 115))
BLOCK
check_case "d: a line of 121 characters" 1 "${rule}14: bash block (rule 12): a line over 120 characters (121)" <<BLOCK
echo $(printf 'x%.0s' $(seq 1 116))
BLOCK
check_case "d: a wrapped command, continuation indented two" 0 "${pass}" <<'BLOCK'
kubectl get pods \
  --all-namespaces \
  -o wide
BLOCK
check_case "d: a continuation indented four" 1 "${rule}15: bash block (rule 12): a continuation line not indented two spaces from its command's first line (4)" <<'BLOCK'
kubectl get pods \
    --all-namespaces
BLOCK

# 12e: one blank line between groups; none at a block's start or end, never two in a row.
check_case "e: one blank line between two groups" 0 "${pass}" <<'BLOCK'
kubectl get pods

kubectl get svc
BLOCK
check_case "e: a blank line at the start" 1 "${rule}14: bash block (rule 12): a blank line at the start of the block" <<'BLOCK'

kubectl get pods
BLOCK
check_case "e: a blank line at the end" 1 "${rule}15: bash block (rule 12): a blank line at the end of the block" <<'BLOCK'
kubectl get pods

BLOCK
check_case "e: two blank lines in a row" 1 "${rule}16: bash block (rule 12): two blank lines in a row" <<'BLOCK'
kubectl get pods


kubectl get svc
BLOCK

# A # inside quotes or in ${#var} is not a comment; a heredoc's body is not read.
check_case "quote: a # inside quotes is not a comment" 0 "${pass}" <<'BLOCK'
echo "issue #42" 'and #43'
kubectl get pods  # the pods
BLOCK
check_case "\${#x}: a length is not a comment" 0 "${pass}" <<'BLOCK'
names=(a b c)
echo "${#names[@]}" ${#names[@]}
BLOCK
check_case "heredoc: its body is not read" 0 "${pass}" <<'BLOCK'
cat <<'EOF' > notes.txt
$ not a prompt # not a comment


    not a continuation
EOF
kubectl get pods
BLOCK
check_case "heredoc: the check resumes after its end" 1 "${rule}17: bash block (rule 12): a prompt (\$) at the start of a line" <<'BLOCK'
cat <<EOF > notes.txt
text
EOF
$ kubectl get pods
BLOCK

echo "mismatches: ${mismatches}"
exit "${mismatches}"
