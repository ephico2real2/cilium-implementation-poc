#!/usr/bin/env bash
# upstream-release-notes.sh — the raw material for an upstream release report: fetch only, no judgement.
# A person (or .claude/skills/upstream-release-notes) reads the file and writes docs/upstream/releases/.
#
#   scripts/upstream-release-notes.sh cilium [vX.Y.Z]     # default: the latest release of cilium/cilium
#   scripts/upstream-release-notes.sh hubble-observer     # onzack/hubble-observer (no GitHub Releases: the chart version on main is the release)
#   scripts/upstream-release-notes.sh cf2cnp              # onzack/cf2cnp (tags; the chart version on main)
#   OUT=path scripts/upstream-release-notes.sh …          # default: .tmp/upstream/<project>-<version>.md
#
#   step            what it writes
#   header          title, fetched-at UTC, one-line source (repo and what counts as a release)
#   pins            this repository's pins, grepped, | pin | file:line | value |
#   upstream        the release / chart / tags / fork-vs-upstream compare / commits / our PRs
#   keyword hits    cilium only: each release bullet that names a feature this lab runs
#   next            the skill that writes the report, and where it goes
#
# Every fact is preceded by the command that produced it, in a fenced sh block.
# Prints the output path on stdout as its last line. Exit 0 on success.
set -uo pipefail; cd "$(dirname "$0")/.."

# label|regex — first match wins; extend by adding a line. Case-insensitive against each `* ` bullet.
FEATURES=(
  'gateway-api|gateway.?api|httproute|listener|envoy'
  'l2-and-lb-ipam|l2.?announce|lb.?ipam|loadbalancer|externaltrafficpolicy|nodeport'
  'clustermesh|cluster.?mesh|clustermesh|remote cluster|global service'
  'hubble|hubble'
  'policy|policy|identit'
  'wireguard-and-encryption|wireguard|ipsec|encryption'
  'dns|dns|fqdn'
  'bgp|bgp'
  'kind-and-kernel|kind|kernel|netkit|bpf.?masquerade|tproxy'
)

FORK_OWNER=ephico2real2
FORK_BRANCH=develop
FETCHED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUTFILE=""
GH_JSON=""
_BODY=""

say() { printf '\n== %s  (%s)\n' "$1" "$(date +%H:%M:%S)" >&2; }
die() { echo "::error::$1" >&2; exit 1; }   # stderr: the contract is the output path on stdout
usage() {
  die "usage: scripts/upstream-release-notes.sh cilium [vX.Y.Z] | hubble-observer | cf2cnp  (OUT=path overrides .tmp/upstream/<project>-<version>.md)"
}

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not found in PATH"; }
need gh
need jq
gh auth status >/dev/null 2>&1 || die "gh auth status failed — not logged in (gh auth login)"

emit() { printf '%s\n' "$1" >> "$OUTFILE"; }
emit_cmd() { emit '```sh'; emit "$1"; emit '```'; emit ""; }

# trim100: table cells stay one line; a 100-char cap keeps README rows from blowing the table
trim100() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  if [ "${#s}" -gt 100 ]; then printf '%s' "${s:0:100}..."; else printf '%s' "$s"; fi
}
esc_cell() { printf '%s' "$1" | sed 's/|/\\|/g'; }

# gh_api PATH — sets GH_JSON. 0 ok, 2 HTTP 404 (caller prints —). dies here so exit is not trapped in a subshell.
gh_api() {
  local path="$1" out rc=0
  out=$(gh api "$path" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then GH_JSON=$out; return 0; fi
  GH_JSON=""
  if printf '%s' "$out" | grep -qE 'HTTP 404|Not Found'; then return 2; fi
  die "gh api $path failed: $out"
}

open_out() { # <project> <version> — OUT= wins; mkdir so a fresh clone still works
  local project="$1" version="$2"
  if [ -n "${OUT:-}" ]; then OUTFILE=$OUT
  else OUTFILE=".tmp/upstream/${project}-${version}.md"; fi
  mkdir -p "$(dirname "$OUTFILE")"
  : > "$OUTFILE"
}

write_header() { # <project> <source-line>
  emit "# $1 — upstream release material, fetched ${FETCHED}"
  emit ""
  emit "source: $2"
  emit ""
}

write_next() { # <project> <version>
  emit "## Next"
  emit ""
  emit "Write the report with the \`upstream-release-notes\` skill (.claude/skills/upstream-release-notes/SKILL.md): every 'affects us' claim checked against the lab's values and demos, the report at docs/upstream/releases/$1-$2.md."
  emit ""
}

# pin_add PIN FILE PATTERN — grep -n of THIS repo; — when the pattern hits nothing (never a silent hole)
pin_add() {
  local pin="$1" file="$2" pat="$3" hits=0 line num rest
  if [ ! -f "$file" ]; then emit "| $pin | $file | — |"; return 0; fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    hits=1
    num="${line%%:*}"; rest="${line#*:}"
    emit "| $pin | ${file}:${num} | $(esc_cell "$(trim100 "$rest")") |"
  done < <(grep -n -- "$pat" "$file" || true)
  [ "$hits" -eq 1 ] || emit "| $pin | $file | — |"
}

pins_table_start() {
  emit "## The lab's pins"
  emit ""
  emit_cmd "$1"
  emit "| pin | file:line | value |"
  emit "| --- | --- | --- |"
}

# the repository line plus the next tag: — that's the image the observer actually pulls
pin_cf2cnp_image() {
  local file="demos/25-hubble-observer-loki/values-hubble-observer.yaml" n tag_n line
  n=$(grep -n 'ghcr.io/ephico2real2/cf2cnp' "$file" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -z "$n" ]; then emit "| cf2cnp image | $file | — |"; return 0; fi
  line=$(sed -n "${n}p" "$file")
  emit "| cf2cnp image repository | ${file}:${n} | $(esc_cell "$(trim100 "$line")") |"
  tag_n=$(awk -v s="$n" 'NR > s && /tag:/ { print NR; exit }' "$file")
  if [ -n "$tag_n" ]; then
    line=$(sed -n "${tag_n}p" "$file")
    emit "| cf2cnp image tag | ${file}:${tag_n} | $(esc_cell "$(trim100 "$line")") |"
  else
    emit "| cf2cnp image tag | $file | — |"
  fi
}

# --- cilium -------------------------------------------------------------------

# Docker Manifests list every image; the lab pulls three (agent, relay, generic operator)
trim_manifests() {
  awk '
    BEGIN { in_docker = 0; keep_sub = 0 }
    /^## Docker Manifests([[:space:]]|$)/ { in_docker = 1; keep_sub = 0; print; next }
    in_docker && /^## / { in_docker = 0; print; next }
    in_docker && /^### / {
      if ($0 ~ /^### (cilium|hubble-relay|operator-generic)[[:space:]]*$/) { keep_sub = 1; print }
      else keep_sub = 0
      next
    }
    in_docker { if (keep_sub) print; next }
    { print }
  '
}

count_sections() {
  awk '
    /^\*\*[^*]+:\*\*/ {
      if (name != "") printf "| %s | %d |\n", name, n
      name = $0
      sub(/^\*\*/, "", name)
      sub(/:\*\*[[:space:]]*$/, "", name)
      n = 0
      next
    }
    name != "" && /^## / {
      printf "| %s | %d |\n", name, n
      name = ""; n = 0
      next
    }
    name != "" && /^\* / { n++ }
    END { if (name != "") printf "| %s | %d |\n", name, n }
  '
}

write_keyword_hits() { # reads global _BODY (not $1: a Cilium body can exceed ARG_MAX)
  local spec label regex remaining hits new_remaining b n body="$_BODY"
  emit "## Keyword hits"
  emit ""
  remaining=""
  while IFS= read -r b || [ -n "$b" ]; do
    [ -n "$b" ] || continue
    remaining="${remaining}${b}"$'\n'
  done < <(printf '%s\n' "$body" | grep '^\* ' || true)
  for spec in "${FEATURES[@]}"; do
    label="${spec%%|*}"
    regex="${spec#*|}"
    hits=""; new_remaining=""
    while IFS= read -r b || [ -n "$b" ]; do
      [ -n "$b" ] || continue
      if grep -qiE "$regex" <<< "$b"; then hits="${hits}${b}"$'\n'
      else new_remaining="${new_remaining}${b}"$'\n'; fi
    done < <(printf '%s' "$remaining")
    remaining=$new_remaining
    if [ -n "$hits" ]; then
      emit "### $label"
      emit ""
      printf '%s' "$hits" >> "$OUTFILE"
      emit ""
    fi
  done
  n=0
  while IFS= read -r b || [ -n "$b" ]; do
    [ -n "$b" ] || continue
    n=$((n + 1))
  done < <(printf '%s' "$remaining")
  emit "${n} bullets matched no feature — read the verbatim list"
  emit ""
}

do_cilium() {
  local version="${1:-}" list_json list_rc=0 view_json view_rc=0 tag published url body counts trimmed cadence="" cadence_cmd=""
  local list_cmd="gh release list -R cilium/cilium --limit 30 --json tagName,isLatest,publishedAt"
  local view_cmd

  if [ -z "$version" ]; then
    say "cilium: latest release (isLatest)"
    list_json=$(gh release list -R cilium/cilium --limit 30 --json tagName,isLatest,publishedAt 2>&1) || list_rc=$?
    [ "$list_rc" -eq 0 ] || die "gh release list -R cilium/cilium failed: $list_json"
    version=$(printf '%s' "$list_json" | jq -r '[.[] | select(.isLatest == true)][0].tagName')
    [ -n "$version" ] && [ "$version" != "null" ] || die "cilium/cilium has no release with isLatest"
    cadence=$(printf '%s' "$list_json" | jq -r '.[0:3][] | "\(.tagName)  \(.publishedAt)"')
    cadence_cmd=$list_cmd
  else
    say "cilium: $version"
  fi

  view_cmd="gh release view ${version} -R cilium/cilium --json tagName,publishedAt,url,body"
  view_json=$(gh release view "$version" -R cilium/cilium --json tagName,publishedAt,url,body 2>&1) || view_rc=$?
  if [ "$view_rc" -ne 0 ]; then
    if printf '%s' "$view_json" | grep -qE 'HTTP 404|Not Found|could not find|release not found'; then
      die "release tag ${version} does not exist on cilium/cilium"
    fi
    die "gh release view ${version} -R cilium/cilium failed: $view_json"
  fi

  tag=$(printf '%s' "$view_json" | jq -r .tagName)
  published=$(printf '%s' "$view_json" | jq -r .publishedAt)
  url=$(printf '%s' "$view_json" | jq -r .url)
  body=$(printf '%s' "$view_json" | jq -r '.body // empty' | tr -d '\r')
  counts=$(printf '%s\n' "$body" | count_sections)
  trimmed=$(printf '%s\n' "$body" | trim_manifests)

  open_out cilium "$tag"
  write_header cilium "cilium/cilium GitHub Release (a git tag with a GitHub Release is the release)."

  pins_table_start "$(printf '%s\n' \
    "grep -n 'CILIUM_VERSION=' scripts/lab-stack.sh" \
    "grep -n 'CILIUM_VERSION=' scripts/lab-preflight.sh" \
    "grep -n '| Cilium |' README.md" \
    "grep -n 'tag: \"v1\\.' demos/25-hubble-observer-loki/values-hubble-observer.yaml")"
  pin_add CILIUM_VERSION scripts/lab-stack.sh 'CILIUM_VERSION='
  pin_add CILIUM_VERSION scripts/lab-preflight.sh 'CILIUM_VERSION='
  pin_add 'README Cilium row' README.md '| Cilium |'
  pin_add 'observer hubble CLI image' demos/25-hubble-observer-loki/values-hubble-observer.yaml 'tag: "v1\.'
  emit ""

  emit "## Upstream"
  emit ""
  if [ -n "$cadence_cmd" ]; then
    emit_cmd "$cadence_cmd"
    emit "latest (isLatest): \`${tag}\`"
    emit ""
    emit "three most recent tags (cadence):"
    emit ""
    printf '%s\n' "$cadence" | while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      emit "- \`${line}\`"
    done
    emit ""
  fi
  emit_cmd "$view_cmd"
  emit "| field | value |"
  emit "| --- | --- |"
  emit "| tagName | ${tag} |"
  emit "| publishedAt | ${published} |"
  emit "| url | ${url} |"
  emit ""
  emit "section counts (\`**<Section>:**\` headings, \`* \` bullets under each):"
  emit ""
  emit "| section | bullets |"
  emit "| --- | --- |"
  if [ -n "$counts" ]; then printf '%s\n' "$counts" >> "$OUTFILE"
  else emit "| — | — |"; fi
  emit ""
  emit "Docker Manifests below keep only \`### cilium\`, \`### hubble-relay\` and \`### operator-generic\` (the images this lab pulls)."
  emit ""
  emit "## Release notes (verbatim)"
  emit ""
  printf '%s\n' "$trimmed" >> "$OUTFILE"
  emit ""

  _BODY=$body
  write_keyword_hits
  write_next cilium "$tag"
  printf '%s\n' "$OUTFILE"
}

# --- forks: hubble-observer, cf2cnp ------------------------------------------

# macOS date -v vs GNU -d: the 90-day commit window
iso_since() {
  if date -u -v-90d +%Y-%m-%dT00:00:00Z >/dev/null 2>&1; then
    date -u -v-90d +%Y-%m-%dT00:00:00Z
  else
    date -u -d '90 days ago' +%Y-%m-%dT00:00:00Z
  fi
}

# GitHub wraps the contents payload; newlines would corrupt the decode
chart_fields() { # stdout: version<TAB>appVersion   or empty
  local decoded v a
  decoded=$(printf '%s' "$GH_JSON" | jq -r '.content // empty' | tr -d '\n' | base64 -d 2>/dev/null) || return 0
  [ -n "$decoded" ] || return 0
  v=$(printf '%s\n' "$decoded" | awk '/^version:/ { print $2; exit }' | tr -d \'\")
  a=$(printf '%s\n' "$decoded" | awk '/^appVersion:/ { print $2; exit }' | tr -d \'\")
  [ -n "$v" ] || return 0
  printf '%s\t%s\n' "$v" "$a"
}

emit_dash_block() { emit "—"; emit ""; }

write_tags() { # <label> <api-path>  — [] or 404 → — (fork may be renamed)
  local label="$1" path="$2" rc=0 lines
  emit_cmd "gh api \"$path\""
  emit "${label}:"
  emit ""
  gh_api "$path" || rc=$?
  if [ "$rc" -eq 2 ]; then emit_dash_block; return 0; fi
  lines=$(printf '%s' "$GH_JSON" | jq -r '.[]? | "\(.name)  \(.commit.sha[0:8])"')
  if [ -z "$lines" ]; then emit_dash_block; return 0; fi
  printf '%s\n' "$lines" | while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    emit "- \`${line}\`"
  done
  emit ""
}

write_compare() { # <R> <owner> <default>
  local R="$1" owner="$2" default="$3" path rc=0 ahead behind files
  path="repos/${R}/compare/${owner}:${default}...${FORK_OWNER}:${FORK_BRANCH}"
  emit_cmd "gh api \"$path\""
  gh_api "$path" || rc=$?
  if [ "$rc" -eq 2 ]; then emit_dash_block; return 0; fi
  ahead=$(printf '%s' "$GH_JSON" | jq -r '.ahead_by // "—"')
  behind=$(printf '%s' "$GH_JSON" | jq -r '.behind_by // "—"')
  emit "ahead_by: ${ahead}  (head \`${FORK_OWNER}:${FORK_BRANCH}\` vs base \`${owner}:${default}\`)"
  emit "behind_by: ${behind}"
  emit ""
  files=$(printf '%s' "$GH_JSON" | jq -r '.files[]? | "\(.filename)  +\(.additions) -\(.deletions)"')
  if [ -z "$files" ]; then emit_dash_block; return 0; fi
  emit "changed files:"
  emit ""
  printf '%s\n' "$files" | while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    emit "- \`${line}\`"
  done
  emit ""
}

write_commits() { # <R>
  local R="$1" since path rc=0 lines
  since=$(iso_since)
  path="repos/${R}/commits?since=${since}&per_page=100"
  emit_cmd "gh api \"$path\""
  emit "since ${since} (last 90 days), per_page=100:"
  emit ""
  gh_api "$path" || rc=$?
  if [ "$rc" -eq 2 ]; then emit_dash_block; return 0; fi
  lines=$(printf '%s' "$GH_JSON" | jq -r '.[]? | "\(.sha[0:8])  \(.commit.author.date[0:10])  \(.commit.message | split("\n")[0])"')
  if [ -z "$lines" ]; then emit_dash_block; return 0; fi
  printf '%s\n' "$lines" | while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    emit "- \`${line}\`"
  done
  emit ""
}

write_prs() { # <R>
  local R="$1" json rc=0 rows
  emit_cmd "gh pr list -R ${R} --state all --author ${FORK_OWNER} --json number,title,state,mergedAt"
  json=$(gh pr list -R "$R" --state all --author "$FORK_OWNER" --json number,title,state,mergedAt 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || die "gh pr list -R ${R} failed: $json"
  rows=$(printf '%s' "$json" | jq -r '.[]? | "| \(.number) | \(.title | gsub("\\|"; "\\\\|")) | \(.state) | \(.mergedAt // "—") |"')
  if [ -z "$rows" ]; then emit_dash_block; return 0; fi
  emit "| number | title | state | mergedAt |"
  emit "| --- | --- | --- | --- |"
  printf '%s\n' "$rows" >> "$OUTFILE"
  emit ""
}

do_fork() { # <project>  hubble-observer | cf2cnp
  local project="$1" R="onzack/${1}" chart_path default rc=0 src_line version="unknown" app="" fork_v fork_a
  local up_cmd fork_cmd decoded_line rel rc_rel=0
  case "$project" in
    hubble-observer)
      chart_path="helm/hubble-observer/Chart.yaml"
      src_line="onzack/hubble-observer (no GitHub Releases: the chart version on the default branch is the release); the lab installs the fork ${FORK_OWNER}/hubble-observer@${FORK_BRANCH}."
      ;;
    cf2cnp)
      chart_path="helm/cf2cnp/Chart.yaml"
      src_line="onzack/cf2cnp (tags; the chart version on the default branch); the lab installs the fork ${FORK_OWNER}/cf2cnp@${FORK_BRANCH}."
      ;;
  esac

  say "${project}: default branch + Chart.yaml"
  gh_api "repos/${R}" || die "gh api repos/${R} failed (upstream missing?)"
  default=$(printf '%s' "$GH_JSON" | jq -r .default_branch)
  [ -n "$default" ] && [ "$default" != "null" ] || die "repos/${R} has no default_branch"

  # quoted: gh api treats ?ref= as a glob in zsh; we are bash but quote anyway
  up_cmd="gh api \"repos/${R}/contents/${chart_path}?ref=${default}\""
  gh_api "repos/${R}/contents/${chart_path}?ref=${default}" || die "gh api ${R} Chart.yaml on ${default} failed"
  decoded_line=$(chart_fields)
  version=$(printf '%s' "$decoded_line" | cut -f1)
  app=$(printf '%s' "$decoded_line" | cut -f2)
  [ -n "$version" ] || version="unknown"

  open_out "$project" "$version"
  write_header "$project" "$src_line"

  case "$project" in
    hubble-observer)
      pins_table_start "$(printf '%s\n' \
        "grep -n 'OBSERVER_BRANCH=' scripts/lab-stack.sh" \
        "grep -n 'OBSERVER_COMMIT=' scripts/lab-stack.sh" \
        "grep -n 'hubble-observer' README.md")"
      pin_add OBSERVER_BRANCH scripts/lab-stack.sh 'OBSERVER_BRANCH='
      pin_add OBSERVER_COMMIT scripts/lab-stack.sh 'OBSERVER_COMMIT='
      pin_add 'README hubble-observer' README.md 'hubble-observer'
      ;;
    cf2cnp)
      pins_table_start "$(printf '%s\n' \
        "grep -n 'CF2CNP_VERSION=' scripts/lab-policies.sh" \
        "grep -n 'ghcr.io/ephico2real2/cf2cnp' demos/25-hubble-observer-loki/values-hubble-observer.yaml" \
        "grep -n 'cf2cnp' README.md")"
      pin_add CF2CNP_VERSION scripts/lab-policies.sh 'CF2CNP_VERSION='
      pin_cf2cnp_image
      pin_add 'README cf2cnp' README.md 'cf2cnp'
      ;;
  esac
  emit ""

  emit "## Upstream"
  emit ""
  emit "### Chart.yaml (what counts as a release)"
  emit ""
  emit_cmd "gh api repos/${R} --jq .default_branch"
  emit "default_branch: \`${default}\`"
  emit ""
  emit_cmd "$(printf '%s\n' "$up_cmd" "# decode .content (base64), grep version: / appVersion:")"
  fork_cmd="gh api \"repos/${FORK_OWNER}/${project}/contents/${chart_path}?ref=${FORK_BRANCH}\""
  emit_cmd "$(printf '%s\n' "$fork_cmd" "# decode .content (base64), grep version: / appVersion:")"
  emit "| source | version | appVersion |"
  emit "| --- | --- | --- |"
  emit "| ${R}@${default} | ${version} | ${app:-—} |"
  rc=0
  gh_api "repos/${FORK_OWNER}/${project}/contents/${chart_path}?ref=${FORK_BRANCH}" || rc=$?
  if [ "$rc" -eq 2 ]; then
    emit "| ${FORK_OWNER}/${project}@${FORK_BRANCH} | — | — |"   # 404 on the fork is not fatal — it may have been renamed
  else
    decoded_line=$(chart_fields)
    fork_v=$(printf '%s' "$decoded_line" | cut -f1)
    fork_a=$(printf '%s' "$decoded_line" | cut -f2)
    if [ -n "$fork_v" ]; then emit "| ${FORK_OWNER}/${project}@${FORK_BRANCH} | ${fork_v} | ${fork_a:-—} |"
    else emit "| ${FORK_OWNER}/${project}@${FORK_BRANCH} | — | — |"; fi
  fi
  emit ""

  emit "### Tags"
  emit ""
  write_tags "$R" "repos/${R}/tags?per_page=10"
  write_tags "${FORK_OWNER}/${project}" "repos/${FORK_OWNER}/${project}/tags?per_page=10"

  emit "### Fork vs upstream"
  emit ""
  write_compare "$R" "${R%%/*}" "$default"

  emit "### Commits on upstream in the last 90 days"
  emit ""
  write_commits "$R"

  emit "### Our pull requests upstream"
  emit ""
  write_prs "$R"

  if [ "$project" = cf2cnp ]; then
    emit "### GitHub Releases"
    emit ""
    emit_cmd "gh release list -R ${R} --limit 5"
    rel=$(gh release list -R "$R" --limit 5 2>&1) || rc_rel=$?
    [ "$rc_rel" -eq 0 ] || die "gh release list -R ${R} failed: $rel"
    if [ -n "$rel" ]; then printf '%s\n' "$rel" >> "$OUTFILE"; emit ""
    else emit_dash_block; fi
  fi

  write_next "$project" "$version"
  printf '%s\n' "$OUTFILE"
}

# --- dispatch ----------------------------------------------------------------

PROJECT="${1:-}"
VERSION="${2:-}"
[ -n "$PROJECT" ] || usage
[ $# -ge 1 ] && [ $# -le 2 ] || usage
case "$PROJECT" in
  cilium) ;;
  hubble-observer|cf2cnp)
    [ $# -eq 1 ] || die "$PROJECT takes no version argument (the chart version on the default branch is the release)"
    ;;
  *) usage ;;
esac

case "$PROJECT" in
  cilium)           do_cilium "$VERSION" ;;
  hubble-observer)  do_fork hubble-observer ;;
  cf2cnp)           do_fork cf2cnp ;;
esac
