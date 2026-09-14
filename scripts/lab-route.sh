#!/usr/bin/env bash
# lab-route.sh [<kube-context>] — make the lab's LoadBalancer addresses reachable from THIS host, then prove it.
#
# Each cluster's pools (cilium/lb-ippool-<cluster>.yaml) hand out its own /26 of 172.18.255.0/24, inside the `kind`
# docker network's subnet, and its L2 announcement policy answers ARP for them on its nodes' eth0 (SETUP Step 8,
# NETWORKING_DESIGN §0). One route covers every block. Whether the host can reach
# them depends on where the host sits:
#   Linux (a GitHub runner, a Linux laptop): the docker network is a bridge ON this host, with a connected route for
#     the whole subnet — the pool addresses are on-link, and an ARP from the host reaches the nodes. Nothing to add;
#     this script verifies the route exists and measures the reachability. If Docker's route is missing (a firewall
#     tool removed it), it is put back on the bridge.
#   macOS (Docker Desktop): containers live in a VM the host has no route to. SETUP Step 3.5: a route for the
#     docker subnet via the VM's host-bridge address (needs `kernelForUDP`, Docker Desktop ≥ 4.26) — derived here as
#     Step 3.5.3 derives it, and run when sudo can run non-interactively, printed otherwise.
# Then the demo hostnames (*.poc.local) go into /etc/hosts from LIVE state (scripts/hosts-entries.sh — it never
# guesses an address), and the Gateway and the Hubble UI are called by name, end to end.
#   scripts/lab-route.sh kind-poc1
set -uo pipefail; cd "$(dirname "$0")/.." || exit 1
CTX="${1:-kind-poc1}"
SUDO=""; [ "$(id -u)" = "0" ] || SUDO="sudo -n"
say() { printf '\n== %s\n' "$1"; }

subnet=$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -m1 '\.')
say "the kind docker network: $subnet"
case "$(uname -s)" in
  Linux)
    bridge="br-$(docker network inspect kind --format '{{.Id}}' | cut -c1-12)"
    if ip route show "$subnet" | grep -q "dev $bridge"; then
      echo "route: $subnet dev $bridge (Docker's connected route — the pool is on-link for this host)"
    else
      echo "route for $subnet via $bridge missing; adding it"; $SUDO ip route replace "$subnet" dev "$bridge" || echo "::warning::could not add the route (no non-interactive sudo?)"
    fi
    ;;
  Darwin)
    vm_ip=$(docker run --rm --net=host --privileged busybox sh -c "ip -4 addr show eth1 | grep -o 'inet [0-9.]*'" 2>/dev/null | awk '{print $2}')
    if netstat -rn -f inet | grep -q "^${subnet%%/*}"; then echo "route: $(netstat -rn -f inet | grep "^${subnet%%/*}" | head -1) (SETUP Step 3.5, present)"
    elif [ -n "$vm_ip" ]; then echo "SETUP Step 3.5: sudo route -n add -net $subnet $vm_ip"; $SUDO route -n add -net "$subnet" "$vm_ip" 2>/dev/null || echo "::warning::run it in a Terminal: sudo route -n add -net $subnet $vm_ip (sudo cannot prompt here — SETUP Step 3.5.4)"
    else echo "::warning::no eth1 in the Docker VM: enable kernelForUDP (SETUP Step 2.3b) before the route can exist"; fi
    ;;
esac

say "the addresses the cluster is serving right now (Gateways, LoadBalancer Services)"
kubectl --context "$CTX" get gateway -A -o custom-columns='NS:.metadata.namespace,GATEWAY:.metadata.name,ADDRESS:.status.addresses[0].value,PROGRAMMED:.status.conditions[?(@.type=="Programmed")].status' --no-headers 2>/dev/null
# (no f-string here: a backslash-escaped quote inside an f-string expression is a SyntaxError on the runner's
#  python — "unexpected character after line continuation character", run 34794243096)
kubectl --context "$CTX" get svc -A -o json | python3 -c '
import json, sys
for s in json.load(sys.stdin)["items"]:
    ing = (s["status"].get("loadBalancer") or {}).get("ingress") or []
    if s["spec"].get("type") == "LoadBalancer":
        print("  %s/%s  %s" % (s["metadata"]["namespace"], s["metadata"]["name"], ing[0]["ip"] if ing else "<pending>"))'

say "/etc/hosts from live state (scripts/hosts-entries.sh)"
block=$(CTX="$CTX" scripts/hosts-entries.sh 2>/dev/null)
if [ -n "$block" ]; then
  if grep -q 'cilium-kind-poc' /etc/hosts 2>/dev/null; then
    $SUDO python3 - "$block" <<'PY' || echo "::warning::could not rewrite /etc/hosts"
import re, sys
new = sys.argv[1]; s = open("/etc/hosts").read()
s = re.sub(r"# ---- cilium-kind-poc.*?# ---- end cilium-kind-poc ----\n?", "", s, flags=re.S)
open("/etc/hosts", "w").write(s.rstrip("\n") + "\n" + new + "\n")
PY
  else
    printf '%s\n' "$block" | $SUDO tee -a /etc/hosts >/dev/null || echo "::warning::could not append to /etc/hosts"
  fi
  printf '%s\n' "$block" | grep -v '^#'
fi

say "reachability from this host, measured — TCP to each address (that is what makes the host ARP for it), then the neighbour it learned"
# Not ping: an L2-announced address is answered on ARP and served on its Service ports; nothing owns it as an interface
# address, so ICMP to it has no owner to reply — "ARP/ping 172.18.255.241: no answer" beside a working Gateway (run
# 34794243096). A TCP connect is the probe that both resolves ARP and proves the service; the neighbour table then
# shows the MAC the L2 lease holder answered with (Linux — on macOS the host never ARPs for it: the route's next hop is
# the VM, SETUP Step 3.5, and HTTP is the proof).
probe() { # <address> <what>
  local code mac=""
  code=$(curl -s -o /dev/null -m 6 --connect-timeout 3 -w '%{http_code}' "http://$1/" 2>/dev/null || true)
  case "$(uname -s)" in
    Linux)  mac=$(ip neigh show to "$1" 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "lladdr") print $(i+1)}' | head -1)
            printf '  %-16s %-30s L2 %-38s HTTP %s\n' "$1" "$2" "${mac:+ARP answered by $mac}${mac:-NOT answered (SETUP Step 8: the L2 policy, or the route)}" "${code:-000}";;
    *)      printf '  %-16s %-30s via the VM (SETUP 3.5)%-16s HTTP %s\n' "$1" "$2" "" "${code:-000}";;
  esac
}
while read -r ns name addr; do [ -n "$addr" ] && probe "$addr" "gateway $ns/$name"; done < <(kubectl --context "$CTX" get gateway -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name} {.status.addresses[0].value}{"\n"}{end}' 2>/dev/null)
while read -r ns name addr; do [ -n "$addr" ] && probe "$addr" "service $ns/$name"; done < <(kubectl --context "$CTX" get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace} {.metadata.name} {.status.loadBalancer.ingress[0].ip}{"\n"}{end}' 2>/dev/null)
for name in $(printf '%s\n' "${block:-}" | grep -v '^#' | awk '{for(i=2;i<=NF;i++) print $i}'); do
  code=$(curl -sk -o /dev/null -m 8 -w '%{http_code}' "https://$name/" 2>/dev/null || true); [ "$code" = "000" ] && code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://$name/" 2>/dev/null || true)
  printf '  %-28s HTTP %s\n' "$name" "${code:-000}"
done
