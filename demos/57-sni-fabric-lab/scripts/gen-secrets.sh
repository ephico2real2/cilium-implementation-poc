#!/usr/bin/env bash
# Writes the lab's secrets to <demo>/secrets (ignored by git), one value per file, mode 600.
#
# By default the values are the fixed lab credentials below, so anyone running the lab can
# log in without looking anything up. They are public (this repository is public): use them
# only for this lab, which listens on 127.0.0.1 only. --random writes random values instead.
#
# Usage: scripts/gen-secrets.sh [--force] [--random] [-h|--help]
#   --force   overwrite existing files (then rebuild: scripts/run.sh --fresh, because Postgres
#             and Grafana take their passwords only when their data volumes are first created)
#   --random  random values instead of the lab credentials
#   -h, --help  print this help
set -euo pipefail
umask 077

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DEMO_DIR
readonly OUT_DIR="${DEMO_DIR}/secrets"

# name=value. MQ requires at least 8 characters.
readonly LAB_CREDENTIALS="
admin-token=fabric-admin
postgres-password=fabric-postgres
mq-admin-password=fabric-mq-admin
mq-app-password=fabric-mq-app
grafana-admin-password=fabric-grafana
"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

force=0
random=0
for arg in "$@"; do
  case "${arg}" in
    --force) force=1 ;;
    --random) random=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "gen-secrets: unknown argument: ${arg}" >&2; exit 1 ;;
  esac
done

mkdir -p "${OUT_DIR}"
echo "${LAB_CREDENTIALS}" | while IFS='=' read -r name value; do
  [ -n "${name}" ] || continue
  file="${OUT_DIR}/${name}"
  if [ "${force}" -eq 0 ] && [ -s "${file}" ]; then
    echo "kept    ${name}"
    continue
  fi
  if [ "${random}" -eq 1 ]; then
    # 24 random bytes as 32 URL-safe characters: no quoting problems in any config file.
    openssl rand -base64 24 | tr '+/' '-_' | tr -d '=\n' > "${file}"
    echo "created ${name} (random)"
  else
    printf '%s' "${value}" > "${file}"
    echo "created ${name} = ${value}"
  fi
done
