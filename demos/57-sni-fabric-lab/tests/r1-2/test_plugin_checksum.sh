#!/usr/bin/env bash
# Usage: test_plugin_checksum.sh <observability/grafana/image>
# The Grafana image build must fail when the plugin archive does not match the pinned SHA-256.
set -u
tag="localhost/fabric-grafana:checksum-test"
asset="victoriametrics-logs-datasource-v0.32.0.tar.gz"
log="$(mktemp)"
trap 'rm -f "${log}"' EXIT
podman build --no-cache --layers=false --build-arg PLUGIN_SHA256="$(printf '%064d' 0)" \
  -t "${tag}" "$1" >"${log}" 2>&1
status=$?
if podman image exists "${tag}"; then podman rmi "${tag}" >/dev/null; built=yes; else built=no; fi
if grep -Fq "${asset}: FAILED" "${log}"; then cause=sha256; else cause=other; fi
echo "build with a wrong SHA-256: exit ${status}, image built: ${built}, failure: ${cause}"
[ "${status}" -ne 0 ] && [ "${built}" = no ] && [ "${cause}" = sha256 ]
