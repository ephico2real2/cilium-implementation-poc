#!/usr/bin/env bash
# colima-registry.sh — local registry for the Colima family (enhancement 008
# §3.1 rule 5). Runs registry:2 as kind-registry, published on
# 127.0.0.1:5001, connected to kind-eg-colima. A push from the Mac
# appears in the VM's catalog (measured). No kind load.
#
#   scripts/colima-registry.sh up|down|status
#
# Every docker call is --context "$CTX". Refuses desktop-linux.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
. scripts/fabric-colima-lib.sh

usage() {
  echo "usage: $0 up|down|status" >&2
}

if [ $# -ne 1 ]; then
  usage
  exit 2
fi

if ! fabric_colima_refuse_wrong_ctx; then
  exit 1
fi

cmd=$1
name="$KIND_REGISTRY_NAME"
port="$KIND_REGISTRY_PORT"
net="$KIND_EG_COLIMA_NET"

case "$cmd" in
  up)
    if ! fabric_colima_require_ctx; then
      exit 1
    fi
    fabric_colima_ensure_kind_net
    if dk inspect "$name" >/dev/null 2>&1; then
      state=$(dk inspect -f '{{.State.Running}}' "$name")
      if [ "$state" != true ]; then
        dk start "$name"
      fi
      echo "registry $name present"
    else
      # Join kind-eg-colima at create so nodes resolve the name. A later
      # connect is the fallback if the container already existed on bridge.
      dk run -d --restart=always \
        --name "$name" \
        --network "$net" \
        -p "127.0.0.1:${port}:5000" \
        registry:2
      echo "registry $name created (127.0.0.1:${port} on $net)"
    fi
    net_ip=$(dk inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$name" 2>/dev/null || true)
    if [ -z "$net_ip" ] || [ "$net_ip" = "<no value>" ]; then
      dk network connect "$net" "$name"
      net_ip=$(dk inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$name")
      echo "registry $name connected to $net at $net_ip"
    else
      echo "registry $name already on $net at $net_ip"
    fi
    # Catalog from the container — Mac :5001 may be Desktop's registry.
    echo -n "catalog (in-container): "
    dk exec "$name" wget -qO- http://127.0.0.1:5000/v2/_catalog
    echo
    echo "colima-registry: up ($name on $net at $net_ip, published 127.0.0.1:${port})"
    ;;
  down)
    if ! fabric_colima_require_ctx; then
      exit 1
    fi
    if dk inspect "$name" >/dev/null 2>&1; then
      dk rm -f "$name" >/dev/null
      echo "colima-registry: removed $name (cluster and fabric kept)"
    else
      echo "colima-registry: $name already absent"
    fi
    ;;
  status)
    if ! fabric_colima_require_ctx; then
      exit 1
    fi
    if ! dk inspect "$name" >/dev/null 2>&1; then
      echo "colima-registry: $name absent"
      exit 1
    fi
    dk inspect -f 'name={{.Name}} running={{.State.Running}}' "$name"
    curl -fsS --max-time 5 "http://127.0.0.1:${port}/v2/_catalog"
    echo
    ;;
  *)
    usage
    exit 2
    ;;
esac
