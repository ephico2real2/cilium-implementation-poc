#!/usr/bin/env bash
# network-plan.sh — print the whole addressing plan from LIVE state: the docker network, the nodes
# on it, the LB IPAM pools carved out of it, who is announcing each address, and how this host
# reaches it. Nothing here is hardcoded; run it before any conversation with the network team.
#
# Usage:  scripts/network-plan.sh
set -uo pipefail
CTX="${CTX:-kind-poc1}"; NET="${NET:-kind}"
k() { kubectl --context "$CTX" "$@"; }

echo "================================================================================"
echo " 1. THE 'PHYSICAL' NETWORK — docker bridge '$NET' (the switch + the LAN)"
echo "================================================================================"
docker network inspect "$NET" --format '{{range .IPAM.Config}}  subnet  {{.Subnet}}   gateway {{.Gateway}}{{"\n"}}{{end}}' 2>/dev/null
printf '  bridge interface (inside the Docker VM / on a Linux host): br-%s\n' "$(docker network inspect "$NET" -f '{{.Id}}' 2>/dev/null | cut -c1-12)"
echo
echo "================================================================================"
echo " 2. THE 'SERVERS' — kind nodes attached to that bridge (addresses from docker IPAM)"
echo "================================================================================"
docker network inspect "$NET" --format '{{range $k,$v := .Containers}}  {{printf "%-32s" $v.Name}} {{$v.IPv4Address}}{{"\n"}}{{end}}' 2>/dev/null | sort -t. -k4 -n
echo
echo "================================================================================"
echo " 3. RESERVED SERVICE RANGES — LB IPAM pools carved from the SAME subnet"
echo "================================================================================"
k get ciliumloadbalancerippool -o custom-columns='  POOL:.metadata.name,START:.spec.blocks[0].start,STOP:.spec.blocks[0].stop,SELECTOR:.spec.serviceSelector.matchExpressions[0].key,OP:.spec.serviceSelector.matchExpressions[0].operator,CONFLICT:.status.conditions[?(@.type=="cilium.io/PoolConflict")].status,AVAIL:.status.conditions[?(@.type=="cilium.io/IPsAvailable")].message' 2>/dev/null
echo
echo "================================================================================"
echo " 4. WHO HOLDS WHICH ADDRESS — and which pool it came from"
echo "================================================================================"
k get svc -A --field-selector spec.type=LoadBalancer -o custom-columns='  NS:.metadata.namespace,SERVICE:.metadata.name,ADDRESS:.status.loadBalancer.ingress[0].ip,PINNED:.metadata.annotations.lbipam\.cilium\.io/ips,GATEWAY-OWNED:.metadata.labels.io\.cilium\.gateway/owning-gateway' 2>/dev/null
echo
echo "================================================================================"
echo " 5. WHO ANSWERS ARP FOR EACH ADDRESS — L2 announcement leases (moves if a node dies)"
echo "================================================================================"
k -n kube-system get lease -o custom-columns='  LEASE:.metadata.name,ANNOUNCING-NODE:.spec.holderIdentity' 2>/dev/null | grep -E 'LEASE|l2announce'
echo
echo "================================================================================"
echo " 6. HOW THIS HOST REACHES IT"
echo "================================================================================"
case "$(uname -s)" in
  Darwin)
    echo "  macOS: containers live in a VM; the host needs ONE static route via the VM."
    printf '  host bridge to the VM : '; ifconfig 2>/dev/null | awk '/^bridge[0-9]+:/{b=$1} /member: vmenet/{print b; exit}' | tr -d ':' || echo "(none — kernelForUDP off?)"
    printf '  route to the subnet   : '; netstat -rn -f inet 2>/dev/null | awk '/^172\.18/{print $1" via "$2" dev "$4}' | head -1 || echo "(none — see SETUP 3.5)"
    ;;
  Linux)
    echo "  Linux: the host IS on the bridge — no route needed. The bridge holds the gateway address:"
    ip -4 addr show "br-$(docker network inspect "$NET" -f '{{.Id}}' | cut -c1-12)" 2>/dev/null | awk '/inet /{print "  "$2" on "$NF}'
    ;;
esac
