# Demo 51 — exercises

Run from the repo root after `demos/51-eg-kube-vip/apply.sh`. poc1 and poc2
are paused — do not resume them. No sudo.

## Exercise 1 — create a class-less LoadBalancer and watch it stay pending

`probe-noclass` is already in `shop` (apply.sh keeps it as the D11
exhibit). Look at it, then create a second one:

```bash
kubectl --context kind-eg1 -n shop get svc probe-noclass -o wide
# EXTERNAL-IP <pending>, no loadBalancerClass

kubectl --context kind-eg1 -n shop apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata: {name: my-noclass, namespace: shop}
spec:
  type: LoadBalancer
  ports: [{port: 80, targetPort: 80}]
EOF

sleep 20
kubectl --context kind-eg1 -n shop get svc my-noclass probe-noclass -o wide
kubectl --context kind-eg1 -n shop get svc my-noclass -o yaml | grep -E 'loadBalancerClass|ingress|implementation'
kubectl --context kind-eg1 -n shop delete svc my-noclass
```

*Expect:* both Services stay `<pending>`. No `implementation=kube-vip`
label, no `kube-vip.io/loadbalancerIPs` annotation, `status.loadBalancer`
empty. Phase 0 measured that without
`KUBEVIP_ENABLE_LOADBALANCERCLASS=true` the cloud-provider *does* claim
a class-less Service (labels it, may share an address with an in-use
Service) while still printing `<pending>`. The env is why this one is
honestly nobody's.

## Exercise 2 — move the VIP and watch `arping`

```bash
scripts/eg-vip-move.sh --status
docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
  arping -c 3 -I eth0 172.19.255.16

scripts/eg-vip-move.sh kube-vip eg2
docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 \
  arping -c 3 -I eth0 172.19.255.16

scripts/eg-vip-move.sh kube-vip eg1
```

*Expect:* `--status` says eg1; 3 of 3 replies from `eg1-worker`
(`6e:8c:28:fa:31:1f`). After the move to eg2, 3 of 3 from an eg2 node
(this run: `eg2-control-plane` `1e:c6:bf:d8:18:97`) and
`X-Served-By: eg2` on `https://api.eg.poc.local/healthz`. Put it back
on eg1 when you are done — `check.sh` assumes the VIP is on eg1 after
apply. The script deletes the other cluster first; two announcers for
`.16` is the failure it exists to prevent.

## Exercise 3 — call gRPC with the wrong authority

```bash
# right authority — SERVING
docker run --rm --network kind-eg fullstorydev/grpcurl:latest \
  -plaintext -authority grpc.eg1.poc.local \
  172.19.255.240:80 grpc.health.v1.Health/Check

# wrong authority — the :80 listener has no hostname, but the GRPCRoute
# matches grpc.eg1.poc.local. A different :authority does not hit that route.
docker run --rm --network kind-eg fullstorydev/grpcurl:latest \
  -plaintext -authority grpc.eg2.poc.local \
  172.19.255.240:80 grpc.health.v1.Health/Check || true
```

*Expect:* the first call prints `{"status": "SERVING"}`. The second
fails (no matching GRPCRoute on eg1's door for `grpc.eg2.poc.local`).
That is the same hostname rule demo 53 measured on Cilium: the
`:authority` has to intersect the route's `hostnames`.

## Cleanup

`demos/51-eg-kube-vip/cleanup.sh` — eg1/eg2 stay; kube-vip and the
doors go. Demo 50's clusters, controller and root stay.
