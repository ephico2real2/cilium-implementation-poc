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
  # shellcheck disable=SC2046
  docker stop $(awk '{print $2}' "$map") >/dev/null && echo "   stopped."
done
echo; echo "resume with: scripts/cluster-resume.sh $*"
