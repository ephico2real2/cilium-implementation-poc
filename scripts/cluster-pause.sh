#!/usr/bin/env bash
# cluster-pause.sh — stop a kind cluster's node containers to free memory/CPU, in a way that can be
# UNDONE. A multi-node kind cluster only survives a stop/start if every node comes back with the
# SAME IP (etcd peer URLs and the API server certificate are bound to them — gotcha #6). Docker
# does not remember a container's IP; it hands out the lowest free address on the network. So this
# script records the name -> IP map first, and cluster-resume.sh starts the containers in ascending
# IP order — which reproduces the map exactly, PROVIDED nothing else took those addresses meanwhile.
# That is why poc3 lives on its own docker network (clusters/poc3.yaml): it cannot take them.
#
# Usage:  scripts/cluster-pause.sh <cluster> [<cluster>...]        e.g.  scripts/cluster-pause.sh poc1 poc2
# Writes: .tmp/ipmap-<cluster>.txt  (one line per container: "<ip> <name>", ascending)
set -uo pipefail
[ "$#" -ge 1 ] || { echo "usage: $0 <cluster> [<cluster>...]" >&2; exit 2; }
mkdir -p .tmp
for c in "$@"; do
  nodes=$(kind get nodes --name "$c" 2>/dev/null); [ -n "$nodes" ] || { echo "no such cluster: $c" >&2; exit 1; }
  net=$(docker inspect "$(echo "$nodes" | head -1)" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')
  map=".tmp/ipmap-$c.txt"
  docker network inspect "$net" --format '{{range .Containers}}{{.IPv4Address}} {{.Name}}{{println}}{{end}}' \
    | sed 's#/[0-9]*##' | grep -E " $c-" | sort -t. -k4 -n > "$map"
  echo "== $c on network '$net' — recorded $(wc -l < "$map" | tr -d ' ') containers to $map:"; sed 's/^/   /' "$map"
  # kind starts its nodes with --restart=on-failure:1, and `docker stop` ends a node with exit 137 — a "failure" —
  # so Docker restarted every node about a minute after the first pause (2026-09-18: all four back "Up" while the
  # operator was told they were down; gotcha #119). The policy is turned off before the stop and restored by
  # cluster-resume.sh. Docker Desktop sometimes answers "did not receive an exit event" and stops the node anyway;
  # the loop below re-stops whatever is still running, then verifies nothing came back.
  # shellcheck disable=SC2046
  docker update --restart=no $(awk '{print $2}' "$map") >/dev/null
  for _ in 1 2 3; do
    running=$(docker ps --format '{{.Names}}' | grep -F -x -f <(awk '{print $2}' "$map") || true)
    [ -z "$running" ] && break
    # shellcheck disable=SC2086
    docker stop -t 30 $running >/dev/null 2>&1 || true
  done
  sleep 5
  if running=$(docker ps --format '{{.Names}}' | grep -F -x -f <(awk '{print $2}' "$map")); then
    echo "   NOT stopped (still running): $running" >&2; exit 1
  fi
  echo "   stopped (restart policy set to 'no' until cluster-resume.sh)."
done
echo; echo "resume with: scripts/cluster-resume.sh $*"
