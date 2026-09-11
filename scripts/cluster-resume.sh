#!/usr/bin/env bash
# cluster-resume.sh — start the containers cluster-pause.sh stopped, each PINNED to its recorded
# address BEFORE it starts, then wait for the nodes.
#
# WHY PIN RATHER THAN START IN ORDER. Docker hands a starting container the lowest free address.
# Starting in ascending recorded order reproduces the map only if nothing below the cluster's range
# was freed meanwhile — and in this build something was (hubble-ui-proxy at .8 had been stopped),
# so poc2-worker came back on .8 instead of .9 (demo 11 transcript). `docker network disconnect` +
# `docker network connect --ip <recorded>` works on a STOPPED container and makes the address a
# property of the container, not of start order. The container keeps its name in docker DNS.
#
# Usage:  scripts/cluster-resume.sh <cluster> [<cluster>...]
set -uo pipefail
[ "$#" -ge 1 ] || { echo "usage: $0 <cluster> [<cluster>...]" >&2; exit 2; }
for c in "$@"; do
  map=".tmp/ipmap-$c.txt"; [ -s "$map" ] || { echo "no map for $c ($map) — was it paused with cluster-pause.sh?" >&2; exit 1; }
  net=$(docker inspect "$(awk 'NR==1{print $2}' "$map")" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')
  echo "== $c on '$net': pinning recorded addresses, then starting"
  while read -r ip name; do
    holder=$(docker network inspect "$net" --format "{{range .Containers}}{{if eq .IPv4Address \"$ip/16\"}}{{.Name}}{{end}}{{end}}")
    if [ -n "$holder" ] && [ "$holder" != "$name" ]; then echo "   $ip is held by '$holder' — stop or re-pin that container first" >&2; exit 1; fi
    docker network disconnect "$net" "$name" >/dev/null 2>&1
    docker network connect --ip "$ip" "$net" "$name" || { echo "   could not pin $name to $ip" >&2; exit 1; }
    docker start "$name" >/dev/null
    got=$(docker inspect "$name" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
    [ "$got" = "$ip" ] && echo "   $name -> $got  ok" || { echo "   $name -> $got  EXPECTED $ip" >&2; exit 1; }
  done < "$map"
  printf '   waiting for nodes Ready'
  for _ in $(seq 1 36); do
    n=$(kubectl --context "kind-$c" get nodes --no-headers 2>/dev/null | grep -c ' Ready'); t=$(kubectl --context "kind-$c" get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "$t" -gt 0 ] && [ "$n" = "$t" ] && break; printf '.'; sleep 5
  done; echo
  kubectl --context "kind-$c" get nodes 2>&1 | sed 's/^/   /'
done
