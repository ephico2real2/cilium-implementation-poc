#!/usr/bin/env bash
# egress-test.sh — the cell's egress boundary, probed from a developer's debug pod in the bank namespace (poc1).
# The pod has NO rendered policy of its own (it declared nothing), so: open ingress, the platform's egress rules.
# Service ports are the SERVICE ports (80 → targetPort 8080): a ClusterIP on a port that is not a Service
# frontend is not translated and Cilium sees an unknown IP — identity `world` — which the cell denies.
set -u; C="${1:-poc1}"; NS=bank; POD=egress-test
kubectl --context kind-$C -n $NS get pod $POD >/dev/null 2>&1 || { kubectl --context kind-$C -n $NS run $POD --image=alpine:3.20 --restart=Never --labels=app=$POD --command -- sleep 3600 >/dev/null; kubectl --context kind-$C -n $NS wait --for=condition=Ready pod/$POD --timeout=90s >/dev/null; }
kubectl --context kind-$C -n $NS exec $POD -- sh -c '
t() { printf "  %-58s " "$1"; shift; timeout 8 "$@" >/dev/null 2>&1; rc=$?; [ $rc -eq 0 ] && echo ALLOWED || echo "DENIED (rc=$rc)"; }
t "in-cell: api.bank:80/healthz (Service port)"              wget -qO- http://api.bank.svc.cluster.local/healthz
t "in-cell, other cluster: accounts.bank:80/healthz"          wget -qO- http://accounts.bank.svc.cluster.local/healthz
t "in-cell: redis.bank:6379 (tcp)"                            nc -zv -w 3 redis.bank.svc.cluster.local 6379
t "DNS: nslookup example.com"                                 nslookup example.com
t "FQDN allowlist: api.stripe.com:443"                        nc -zv -w 5 api.stripe.com 443
t "FQDN allowlisted name, port NOT listed: api.stripe.com:80" nc -zv -w 5 api.stripe.com 80
t "world by name, not listed: example.com:443"                nc -zv -w 5 example.com 443
t "world by IP: 1.1.1.1:443"                                  nc -zv -w 5 1.1.1.1 443
t "kube-apiserver (egressDeny): kubernetes.default:443"       nc -zv -w 5 kubernetes.default.svc.cluster.local 443
t "another namespace: echo.routes:80"                         wget -qO- http://echo.routes.svc.cluster.local/
t "a Service IP on a port that is not a Service port: api.bank:8080" wget -qO- http://api.bank.svc.cluster.local:8080/healthz
'
