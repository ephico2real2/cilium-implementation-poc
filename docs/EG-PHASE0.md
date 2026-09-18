# Enhancement 007 phase 0 — the ground, measured

Issue [#54](https://github.com/ephico2real2/cilium-implementation-poc/issues/54). Plan:
[enhancements/007-envoy-gateway-lab.md](https://github.com/ephico2real2/cilium-implementation-poc/blob/enh-007-envoy-gateway-lab/enhancements/007-envoy-gateway-lab.md)
revision 1. Every command below was run through
`scripts/record.sh docs/eg-phase0-transcript.txt …` on 2026-09-18. Quoted output is
verbatim from that transcript. poc1/poc2 and CRC were not touched.

The two client paths this document uses:

1. **From the Mac** — `ping` / `route -n get`. There is no host route to `172.19.0.0/16`
   (gotcha #108 measured this for `172.18/16` only). These commands fail until the operator
   adds the route in [What the operator ran, and what the Mac measured after](#what-the-operator-ran-and-what-the-mac-measured-after-2026-09-18-2017-utc).
2. **From a container on the bridge** — `docker run --rm --network kind-eg alpine:3.20 …`
   and `docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 arping …`. Every
   later "from the Mac" measurement in this record is done this way.

## R0.1 The network

**Claim (plan §3.1, issue #54).** A second Docker bridge `kind-eg` at `172.19.0.0/16` with
Docker's allocation held to `172.19.0.0/17`; the Mac either already reaches it or needs the
same host-route shape as `kind`.

The existing `kind` network (left alone):

```
$ docker network inspect kind --format {{json .IPAM.Config}}{{"\n"}}options={{json .Options}}
[{"Subnet":"172.18.0.0/16","IPRange":"172.18.0.0/17","Gateway":"172.18.0.1"},{"Subnet":"fc00:f853:ccd:e793::/64","Gateway":"fc00:f853:ccd:e793::1"}]
options={"com.docker.network.bridge.enable_ip_masquerade":"true","com.docker.network.driver.mtu":"65535","com.docker.network.enable_ipv4":"true"}
```

`scripts/eg-net.sh` mirrors that shape onto `kind-eg`. Options that **matter**:

| Option | Why |
|---|---|
| `--subnet 172.19.0.0/16` | the LAN the address plan is written for |
| `--ip-range 172.19.0.0/17` | the reservation trick — Docker IPAM never reaches `172.19.255.0/24` |
| `--gateway 172.19.0.1` | stable `.1`, same as `kind` |
| `enable_ip_masquerade=true` | nodes pull images through the VM's NAT |
| `driver.mtu` copied from the default `bridge` | 65535 on this Docker Desktop; mismatch would fragment |
| `--ipv6` + a **unique** ULA `fc00:f853:ccd:e794::/64` | `kind` is dual-stack (`…e793::/64`); this prefix is chosen adjacent so the two bridges cannot share a subnet |

`com.docker.network.enable_ipv4=true` shows up on inspect; it is Docker's default, not passed
to `create`.

```
$ scripts/eg-net.sh
c363476fa0ca160a94aecbe8c4992e7f9d32835b226742be3bbb9a3e55d6ad8e
created: 172.19.0.0/16 fc00:f853:ccd:e794::/64
```

```
$ docker network inspect kind-eg
        "Name": "kind-eg",
        "Driver": "bridge",
        "EnableIPv4": true,
        "EnableIPv6": true,
            "Config": [
                {
                    "Subnet": "172.19.0.0/16",
                    "IPRange": "172.19.0.0/17",
                    "Gateway": "172.19.0.1"
                },
                {
                    "Subnet": "fc00:f853:ccd:e794::/64",
                    "Gateway": "fc00:f853:ccd:e794::1"
                }
            ]
        "Options": {
            "com.docker.network.bridge.enable_ip_masquerade": "true",
            "com.docker.network.driver.mtu": "65535",
            "com.docker.network.enable_ipv4": "true"
        },
```

**From the Mac — no route.** `netstat -rn -f inet` has no `172.19` and no `172.18/16` (only a
stale host ARP for `172.18.255.201` on `bridge100`). The VM gateway is `192.168.64.2` on
`bridge100` (`192.168.64.1`), matching NETWORKING_DESIGN.md:26 and SETUP 2.3b/3.5.

```
$ ping -c1 -W1 172.19.0.1
PING 172.19.0.1 (172.19.0.1): 56 data bytes

--- 172.19.0.1 ping statistics ---
1 packets transmitted, 0 packets received, 100.0% packet loss
[exit code: 2]
```

```
$ route -n get 172.19.0.1
   route to: 172.19.0.1
destination: default
       mask: default
    gateway: 192.168.86.1
  interface: en0
```

The packet went out `en0` to the home router, not to `192.168.64.2`. The command the operator
must run (not run here; no sudo):

```
sudo route -n add -net 172.19.0.0/16 192.168.64.2
```

**From a container on the bridge — the gateway answers.**

```
$ docker run --rm --network kind-eg alpine:3.20 ping -c1 -W2 172.19.0.1
PING 172.19.0.1 (172.19.0.1): 56 data bytes
64 bytes from 172.19.0.1: seq=0 ttl=64 time=0.057 ms

--- 172.19.0.1 ping statistics ---
1 packets transmitted, 1 packets received, 0% packet loss
round-trip min/avg/max = 0.057/0.057/0.057 ms
```

**Verdict — as measured.** The network exists with the reservation trick. The Mac has no
route. Clients run from a container on `kind-eg` until the operator adds the host route.

## R0.2 kind on the custom network

**Claim.** `KIND_EXPERIMENTAL_DOCKER_NETWORK=kind-eg` builds `eg1` with kindnet + kube-proxy
iptables; node IPs land in `172.19.0.0/17`; nothing in `172.19.255.0/24`. One cluster only
(eg2 is demo 50's).

`clusters/eg1.yaml` copies the **untaint** `kubeadmConfigPatches` (v1beta3 + v1beta4) from
`clusters/ci/poc1.yaml`. It does **not** copy `extraMounts` `/proc` → `/procHost` (Tetragon
demo 17 — this cluster has neither Tetragon nor Cilium). `kubeProxyMode` and
`disableDefaultCNI` are unset so kind installs kindnet and kube-proxy in its default iptables
mode. Node image is the pin in `clusters/ci/poc1.yaml` /
`kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed`
(lab-up.sh does not pass `--image`; the yaml does). `clusters/eg2.yaml` is the sibling config
(pods `10.60/16`, services `10.61/16`); the cluster was not created.

```
$ env KIND_EXPERIMENTAL_DOCKER_NETWORK=kind-eg kind create cluster --config clusters/eg1.yaml --image kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed
Creating cluster "eg1" ...
WARNING: Overriding docker network due to KIND_EXPERIMENTAL_DOCKER_NETWORK
WARNING: Here be dragons! This is not supported currently.
 ✓ Ensuring node image (kindest/node:v1.36.4)
 ✓ Preparing nodes
 ✓ Starting control-plane
 ✓ Installing CNI
 ✓ Joining worker nodes
Set kubectl context to "kind-eg1"
```

```
$ docker inspect eg1-control-plane -f {{json .NetworkSettings.Networks}}
{"kind-eg":{...,"Gateway":"172.19.0.1","IPAddress":"172.19.0.3","MacAddress":"62:d0:d4:f7:3a:89",...}}

$ docker inspect eg1-worker -f {{json .NetworkSettings.Networks}}
{"kind-eg":{...,"Gateway":"172.19.0.1","IPAddress":"172.19.0.2","MacAddress":"32:b7:64:3b:79:5b",...}}
```

```
$ docker network inspect kind-eg --format {{range .Containers}}{{printf "%-24s %s %s\n" .Name .IPv4Address .MacAddress}}{{end}}
eg1-worker               172.19.0.2/16 32:b7:64:3b:79:5b
eg1-control-plane        172.19.0.3/16 62:d0:d4:f7:3a:89
```

```
$ kubectl --context kind-eg1 -n kube-system get ds kindnet kube-proxy
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
kindnet      2         2         2       2            2           kubernetes.io/os=linux   22s
kube-proxy   2         2         2       2            2           kubernetes.io/os=linux   23s
```

```
$ bash -c kubectl --context kind-eg1 -n kube-system get cm kube-proxy -o yaml | grep mode
    mode: iptables
```

```
$ kubectl --context kind-eg1 get nodes -o wide
NAME                STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                       KERNEL-VERSION            CONTAINER-RUNTIME
eg1-control-plane   Ready    control-plane   26s   v1.36.4   172.19.0.3    <none>        Debian GNU/Linux 13 (trixie)   7.0.12-linuxkit (arm64)   containerd://2.3.4
eg1-worker          Ready    <none>          11s   v1.36.4   172.19.0.2    <none>        Debian GNU/Linux 13 (trixie)   7.0.12-linuxkit (arm64)   containerd://2.3.4
```

`kubectl get ds,deploy -A` shows only kindnet, kube-proxy, coredns, local-path-provisioner. No
Cilium objects.

**Verdict — as measured.** Node IPs `.0.2` / `.0.3` sit inside `172.19.0.0/17`. Nothing in
`172.19.255.0/24`. kindnet + kube-proxy iptables confirmed. kind still prints "Here be
dragons" for `KIND_EXPERIMENTAL_DOCKER_NETWORK`; the cluster attached to `kind-eg`.

## R0.3 The CRDs and Envoy Gateway

**Claim.** Gateway API standard-channel CRDs from the v1.6.2 release YAML (10 CRDs,
`grpcroutes` included), then Envoy Gateway v1.9.1 with `--set crds.enabled=false`.

At chart v1.9.1, `crds.enabled` skips **both** Gateway API CRDs **and** Envoy Gateway's own
CRDs (EnvoyProxy, BackendTrafficPolicy, …):

```
$ bash -c helm show values oci://docker.io/envoyproxy/gateway-helm --version v1.9.1 | grep -A6 "^crds:"
crds:
  # -- Install Envoy Gateway CRDs, Gateway API CRDs, and Gateway API safe upgrade policy resources. Set to false when these resources are managed separately.
  enabled: true
```

That matches [Install with Helm](https://gateway.envoyproxy.io/docs/install/install-helm/) —
install EG CRDs separately, then the chart with `crds.enabled=false`.

```
$ kubectl --context kind-eg1 apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml
customresourcedefinition.apiextensions.k8s.io/backendtlspolicies.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/gatewayclasses.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/gateways.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/grpcroutes.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/httproutes.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/listenersets.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/referencegrants.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/tcproutes.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/tlsroutes.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/udproutes.gateway.networking.k8s.io created
```

Ten CRDs. `grpcroutes` bundle version:

```
$ kubectl --context kind-eg1 get crd grpcroutes.gateway.networking.k8s.io -o jsonpath={.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"\n"}
v1.6.2
```

EG's own CRDs, Gateway API left off:

```
$ bash -c helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm --version v1.9.1 --set crds.gatewayAPI.enabled=false --set crds.envoyGateway.enabled=true | kubectl --context kind-eg1 apply --server-side -f -
customresourcedefinition.apiextensions.k8s.io/backends.gateway.envoyproxy.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/backendtrafficpolicies.gateway.envoyproxy.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/clienttrafficpolicies.gateway.envoyproxy.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/envoyextensionpolicies.gateway.envoyproxy.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/envoypatchpolicies.gateway.envoyproxy.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/envoyproxies.gateway.envoyproxy.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/httproutefilters.gateway.envoyproxy.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/securitypolicies.gateway.envoyproxy.io serverside-applied
```

```
$ helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.1 -n envoy-gateway-system --create-namespace --set crds.enabled=false --kube-context kind-eg1
NAME: eg
STATUS: deployed
```

```
$ kubectl --context kind-eg1 -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=180s
deployment "envoy-gateway" successfully rolled out
```

The chart does **not** create a GatewayClass:

```
$ kubectl --context kind-eg1 get gatewayclass
No resources found
```

`clusters/eg/gatewayclass.yaml` (`controllerName: gateway.envoyproxy.io/gatewayclass-controller`,
name `eg`) was applied:

```
$ kubectl --context kind-eg1 get gatewayclass
NAME   CONTROLLER                                      ACCEPTED   AGE
eg     gateway.envoyproxy.io/gatewayclass-controller   True       0s
```

**Verdict — as measured, with two additions the plan must name.** `crds.enabled=false`
skips EG's own CRDs; install them from `gateway-crds-helm`. The chart does not create
GatewayClass `eg`.

## R0.4 The two load balancers, together

**Claim (R6).** kube-vip (class `kube-vip.io/kube-vip-class`) and MetalLB (`--lb-class
metallb.io/metallb`) installed together; one Service per class with a static address; exactly
one ARP responder per address; a class-less Service claimed by neither. If that fails in a
way no flag fixes: sequential `scripts/eg-lb.sh`.

### Flags, as found

kube-vip v1.2.4 `manifest daemonset --help`:

- `--lbClassOnly` — "Enable load balancing only for services with LoadBalancerClass
  `kube-vip.io/kube-vip-class`"
- `--lbClassName` — default `kube-vip.io/kube-vip-class` (the generator omitted the env var
  because it is the default; `clusters/eg/kube-vip-ds.yaml` sets `lb_class_name` explicitly)
- `--servicesElection` → `svc_election=true` (per-Service ARP leader)
- `--taint` was **not** passed — it would pin the DS to control-plane nodes only

Exact generate command:

```
docker run --rm ghcr.io/kube-vip/kube-vip:v1.2.4 manifest daemonset \
  --interface eth0 --services --arp --inCluster --servicesElection --leaderElection \
  --lbClassOnly --lbClassName kube-vip.io/kube-vip-class
```

RBAC from the same binary: `docker run --rm ghcr.io/kube-vip/kube-vip:v1.2.4 manifest rbac`.

MetalLB helm chart 0.16.0: `loadBalancerClass` becomes `--lb-class=` on **both** controller
and speaker. Chart default `frrk8s.enabled: true`; L2-only needs `speaker.frr.enabled=false`
and `frrk8s.enabled=false`.

```
helm install metallb metallb/metallb --version 0.16.0 -n metallb-system --create-namespace --set loadBalancerClass=metallb.io/metallb --set speaker.frr.enabled=false --set frrk8s.enabled=false --kube-context kind-eg1
```

```
$ bash -c kubectl --context kind-eg1 -n metallb-system get deploy,ds -o yaml | grep -E 'lb-class|loadBalancerClass' -n | head -40
48:          - --lb-class=metallb.io/metallb
180:          - --lb-class=metallb.io/metallb
```

kube-vip cloud-provider ConfigMap `kubevip` in `kube-system`:
`range-default: 172.19.255.200-172.19.255.205`,
`range-envoy-gateway-system: 172.19.255.240-172.19.255.245`.

`kind load docker-image nginx:1.27-alpine --name eg1` failed
(`ctr: content digest sha256:62223d64…: not found` — the multi-arch index). Workaround:
`docker save nginx:1.27-alpine | docker exec -i <node> ctr -n k8s.io images import --all-platforms=false -`.
`kind load docker-image routedemo:local --name eg1` worked (single-arch).

### First measurement (cloud-provider with no class filter)

```
$ kubectl --context kind-eg1 get svc probe-kv probe-ml probe-noclass -o wide
NAME            TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)        AGE   SELECTOR
probe-kv        LoadBalancer   10.51.186.82    172.19.255.200   80:30617/TCP   9s    app=probe-nginx
probe-ml        LoadBalancer   10.51.232.119   172.19.255.206   80:30904/TCP   9s    app=probe-nginx
probe-noclass   LoadBalancer   10.51.171.149   <pending>        80:32753/TCP   9s    app=probe-nginx
```

Who wrote them:

- **probe-kv** — `kube-vip.io/vipHost: eg1-worker`; ingress `172.19.255.200`. Events: none
  (the annotation already pinned the IP).
- **probe-ml** — MetalLB events `IPAllocated Assigned IP ["172.19.255.206"]` and
  `announcing from node "eg1-worker" with protocol "layer2"`;
  `metallb.io/ip-allocated-from-pool: eg1-metallb`.
- **probe-noclass** — `status.loadBalancer` empty (`<pending>`), but kube-vip-cloud-provider
  **did claim it**: label `implementation=kube-vip`, annotation
  `kube-vip.io/loadbalancerIPs: 172.19.255.200` (the same address as probe-kv),
  `spec.loadBalancerIP: 172.19.255.200`, finalizer `service.kubernetes.io/load-balancer-cleanup`.
  MetalLB did not.

ARP from a container on `kind-eg` — **exactly one responder each**, MAC `32:b7:64:3b:79:5b`
= `eg1-worker`:

```
$ docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 arping -c 3 -I eth0 172.19.255.200
ARPING 172.19.255.200 from 172.19.0.4 eth0
Unicast reply from 172.19.255.200 [32:b7:64:3b:79:5b] 0.010ms
Unicast reply from 172.19.255.200 [32:b7:64:3b:79:5b] 0.012ms
Unicast reply from 172.19.255.200 [32:b7:64:3b:79:5b] 0.013ms
Sent 3 probe(s) (0 broadcast(s))
Received 3 response(s) (0 request(s), 0 broadcast(s))
```

```
$ docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 arping -c 3 -I eth0 172.19.255.206
ARPING 172.19.255.206 from 172.19.0.4 eth0
Unicast reply from 172.19.255.206 [32:b7:64:3b:79:5b] 0.100ms
Unicast reply from 172.19.255.206 [32:b7:64:3b:79:5b] 0.095ms
Unicast reply from 172.19.255.206 [32:b7:64:3b:79:5b] 0.095ms
Sent 3 probe(s) (0 broadcast(s))
Received 3 response(s) (0 request(s), 0 broadcast(s))
```

`wget http://172.19.255.200/` and `http://172.19.255.206/` both returned nginx's
`Welcome to nginx!`.

Node MACs (python, because `docker inspect -f '{{.NetworkSettings.Networks.kind-eg.MacAddress}}'`
trips on the hyphen in `kind-eg`):

```
/eg1-control-plane 62:d0:d4:f7:3a:89 172.19.0.3
/eg1-worker 32:b7:64:3b:79:5b 172.19.0.2
```

### The flag that stops class-less claims

kube-vip-cloud-provider README: env `KUBEVIP_ENABLE_LOADBALANCERCLASS=true` — allocate only
when `spec.loadBalancerClass: kube-vip.io/kube-vip-class`. Patched onto the Deployment,
probe-noclass deleted (its `load-balancer-cleanup` finalizer stuck until cleared by hand)
and recreated.

```
$ kubectl --context kind-eg1 get svc probe-kv probe-ml probe-noclass -o wide
NAME            TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)        AGE     SELECTOR
probe-kv        LoadBalancer   10.51.186.82    172.19.255.200   80:30617/TCP   2m19s   app=probe-nginx
probe-ml        LoadBalancer   10.51.232.119   172.19.255.206   80:30904/TCP   2m19s   app=probe-nginx
probe-noclass   LoadBalancer   10.51.36.208    <pending>        80:31112/TCP   8s      app=probe-nginx
```

Re-measured probe-noclass: no labels, no annotations, no events, `status.loadBalancer: {}`.
Claimed by **neither**.

**Verdict — as measured; coexistence is the path.** Two LBs on one cluster work when:

1. kube-vip DS: `--lbClassOnly` / `lb_class_only=true` + `lb_class_name=kube-vip.io/kube-vip-class`
2. kube-vip-cloud-provider: `KUBEVIP_ENABLE_LOADBALANCERCLASS=true`
3. MetalLB controller **and** speaker: `--lb-class=metallb.io/metallb`

`scripts/eg-lb.sh` (sequential uninstall) was **not** needed and was not written.

## R0.5 The static-address experiment (R7)

**Claim (plan §3.3).** `Gateway.spec.addresses` writes the Envoy Service's `externalIPs`;
nobody answers ARP. The LB's own field on `EnvoyProxy.envoyService` is what gets announced.

### Step 1 — `spec.addresses` only (`clusters/eg/probe-gw.yaml`)

Gateway `probe-gw`, class `eg`, HTTP `:80`, `addresses: [{type: IPAddress, value: 172.19.255.240}]`,
no EnvoyProxy.

Gateway status: `Accepted=True`, `Programmed=True`, `status.addresses: 172.19.255.240`.

Generated Service `envoy-gateway-system/envoy-default-probe-gw-fef29530`:

- `spec.externalIPs: ["172.19.255.240"]`
- `status.loadBalancer: {}` (empty)
- `kubectl get svc -o wide` still prints `EXTERNAL-IP 172.19.255.240` because that column
  shows `externalIPs`. Configured is not announced.

```
$ docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 arping -c 3 -I eth0 172.19.255.240
ARPING 172.19.255.240 from 172.19.0.4 eth0
Sent 3 probe(s) (0 broadcast(s))
Received 0 response(s) (0 request(s), 0 broadcast(s))
[exit code: 1]
```

### Step 2 — attach EnvoyProxy on the existing Gateway — fails

`clusters/eg/probe-gw-envoyproxy.yaml` adds `infrastructure.parametersRef` → EnvoyProxy with
`envoyService.loadBalancerClass: kube-vip.io/kube-vip-class` and
`kube-vip.io/loadbalancerIPs: "172.19.255.240"`. EnvoyProxy status `Accepted=True`, but the
Service did not gain a class. EG log:

```
failed to create or update service envoy-gateway-system/envoy-default-probe-gw-fef29530: ...
Service "envoy-default-probe-gw-fef29530" is invalid: spec.loadBalancerClass: Invalid value: "kube-vip.io/kube-vip-class": may not change once set
```

`loadBalancerClass` is immutable. ARP still 0 replies; `wget` → `Host is unreachable`.

### Step 2b — recreate Gateway + EnvoyProxy together

Delete `probe-gw`, apply the combined manifest.

Service then has **both** `externalIPs: [172.19.255.240]` (from `spec.addresses`) **and**
`loadBalancerClass: kube-vip.io/kube-vip-class`, annotation
`kube-vip.io/loadbalancerIPs: 172.19.255.240`, `kube-vip.io/vipHost: eg1-worker`,
`status.loadBalancer.ingress: 172.19.255.240`. Gateway stays `Accepted` /
`Programmed`; `status.addresses` is still spec.addresses (EG docs: if set, those are the
only status addresses). EG did **not** reject the combination when the IPs match.

```
$ docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 arping -c 3 -I eth0 172.19.255.240
ARPING 172.19.255.240 from 172.19.0.4 eth0
Unicast reply from 172.19.255.240 [32:b7:64:3b:79:5b] 0.010ms
Unicast reply from 172.19.255.240 [32:b7:64:3b:79:5b] 0.018ms
Unicast reply from 172.19.255.240 [32:b7:64:3b:79:5b] 0.014ms
Sent 3 probe(s) (0 broadcast(s))
Received 3 response(s) (0 request(s), 0 broadcast(s))
```

```
$ docker run --rm --network kind-eg alpine:3.20 wget -q -S -O - -T 5 http://172.19.255.240/
  HTTP/1.1 404 Not Found
wget: server returned error: HTTP/1.1 404 Not Found
```

A 404 from Envoy is the door answering (no HTTPRoute yet).

### Step 3 — MetalLB, same shape (`probe-gw-metallb`, `.246`)

Created with EnvoyProxy from the start (`loadBalancerClass: metallb.io/metallb`,
`metallb.io/loadBalancerIPs: "172.19.255.246"`, `spec.addresses: .246`). Service:
`externalIPs: [.246]`, class `metallb.io/metallb`,
`metallb.io/ip-allocated-from-pool: eg1-metallb`, ingress `.246`. Gateway Accepted.
ARP: one responder, same worker MAC. `wget` → HTTP 404.

**Verdict — as measured, with one operational constraint the plan must name.**
`spec.addresses` alone is configured and unreachable. The LB field on EnvoyProxy is what
gets announced. They **can** be combined when the Gateway is created with the EnvoyProxy
already attached and the IPs match; EG does not compare them and does not reject. Adding
`loadBalancerClass` later cannot patch the existing Service — delete and recreate the
Gateway. `kubectl get svc` EXTERNAL-IP is not proof of ARP.

## R0.6 gRPC on :80

**Claim (R10 premise).** Envoy Gateway's gRPC routing task at v1.9.1: plaintext gRPC on the
`:80` listener, `grpcurl` → `SERVING`.

`routedemo:local` was kind-loaded. `clusters/eg/probe-grpc.yaml` copies demo 09's grpc
Deployment + Service (including `appProtocol: kubernetes.io/h2c`) into namespace `probe`,
with a `GRPCRoute` on `probe-gw` hostname `grpc.eg1.poc.local` and the three method matches
from `demos/09-routes/03-routes.yaml`.

GRPCRoute status: `Accepted=True`, `ResolvedRefs=True`. Gateway listener `attachedRoutes: 1`.

```
$ docker run --rm --network kind-eg fullstorydev/grpcurl:latest -plaintext -authority grpc.eg1.poc.local 172.19.255.240:80 grpc.health.v1.Health/Check
{
  "status": "SERVING"
}
```

No BackendTrafficPolicy was required. The h2c hint is the Service's `appProtocol:
kubernetes.io/h2c`, same as demo 09.

**Verdict — as measured.** R10's `:80` premise holds at EG v1.9.1 with demo 09's Service
shape.

## R0.7 Resources

**Claim.** Record `docker stats` for eg1's two nodes and the VM total. `kubectl top` skipped
(no metrics-server).

The brief said poc1/poc2 were paused (Exited). They were **not**: both clusters were Up
and were left alone.

```
$ docker stats --no-stream --format table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}
NAME                 CPU %     MEM USAGE / LIMIT     MEM %
eg1-worker           4.75%     443.7MiB / 23.43GiB   1.85%
eg1-control-plane    8.81%     1.126GiB / 23.43GiB   4.80%
poc2-control-plane   12.95%    2.847GiB / 23.43GiB   12.15%
poc2-worker          15.51%    2.512GiB / 23.43GiB   10.72%
poc1-control-plane   40.49%    6.229GiB / 23.43GiB   26.58%
poc1-worker          21.06%    4.547GiB / 23.43GiB   19.41%
```

```
$ docker info --format MemTotal={{.MemTotal}} NCPU={{.NCPU}}
MemTotal=25159561216 NCPU=10
```

eg1 ≈ 1.57 GiB. poc1+poc2 ≈ 16.1 GiB. VM 23.43 GiB / 10 CPU. The two labs fitted side by
side on this run; D1 is still open for a second cluster (eg2) plus demo traffic.

`kubectl top nodes` was not run.

**Verdict — as measured; differs from the brief's paused-poc assumption.** eg1 is cheap
next to the Cilium lab. The pause path in D1 was not exercised.

## What the plan must change

Revision 2 of enhancement 007, from this record:

1. **Mac route.** There is no host route to `172.19.0.0/16` (and currently none to
   `172.18/16` either). Demo clients run from a container on `kind-eg` until the operator
   adds `sudo route -n add -net 172.19.0.0/16 192.168.64.2`. Gateway `192.168.64.2` on
   `bridge100` confirmed. Document both paths in every demo README.
2. **Envoy Gateway's CRDs are installed from the get-go, by the vendor's CRD chart — the installation is three
   commands, not one** (the operator, 2026-09-18: *"I want our guide to install it from the get go along the
   installation of envoy"*). Measured against the charts' values at v1.9.1: `gateway-helm` has a single switch,
   `crds.enabled` — *"Install Envoy Gateway CRDs, Gateway API CRDs, and Gateway API safe upgrade policy resources. Set
   to false when these resources are managed separately"* — all or nothing; `gateway-crds-helm` has the granular
   switches `crds.envoyGateway.enabled` and `crds.gatewayAPI.enabled` (+ `channel: standard|experimental`). So the
   guide's sequence, in `scripts/eg-up.sh` from demo 50 on: (1) the Gateway API **standard** CRDs from upstream's
   `standard-install.yaml`; (2) `helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm --set
   crds.envoyGateway.enabled=true --set crds.gatewayAPI.enabled=false | kubectl apply --server-side` — Envoy
   Gateway's eight CRDs, **the vendor's method** ([install-helm](https://gateway.envoyproxy.io/docs/install/install-helm/):
   "We're using helm template piped into kubectl apply instead of helm install due to a known Helm limitation
   ([helm/helm#12277](https://github.com/helm/helm/issues/12277)) related to large CRDs"), not a fallback — a Helm
   release of this chart is impossible at v1.9.1 (`Secret "sh.helm.release.v1.eg-crds.v1" is invalid: data: Too long:
   may not be more than 1048576 bytes`, measured both clusters); (3) `helm install eg oci://docker.io/envoyproxy/gateway-helm
   --set crds.enabled=false` — the controller, told its CRDs are managed by (1) and (2); (4) the `GatewayClass eg`.
   Alternative for a one-owner install: step (2) with `crds.gatewayAPI.enabled=true crds.gatewayAPI.channel=standard`
   replaces step (1) — the same upstream content; the guide names it as a note and keeps the YAML (that variant is
   still a `helm template` pipe: a Helm release of the CRD chart does not fit).
   Nothing of Envoy Gateway's is skipped: eg1 has all eight `gateway.envoyproxy.io` CRDs and two `EnvoyProxy` objects.
   **Standard channel only** (the operator, 2026-09-18: no experimental features in this lab; another lab later):
   measured — every `gateway.networking.k8s.io` CRD on eg1 carries `channel: standard`, `bundle-version: v1.6.2`; demo 50's
   `check.sh` asserts it on every CRD so the experimental set cannot arrive unnoticed.
   **Rendered, not inferred** (the operator asked; `helm template` at v1.9.1, 2026-09-18 21:05 UTC): `gateway-crds-helm`
   with `crds.envoyGateway.enabled=true crds.gatewayAPI.enabled=false` emits **0** `gateway.networking.k8s.io` CRDs and
   **8** `gateway.envoyproxy.io` CRDs; the same chart with `crds.gatewayAPI.enabled=true` (its default channel) emits **13
   CRDs annotated `channel: experimental`** — the ten `gateway.networking.k8s.io` kinds plus `xbackends`,
   `xbackendtrafficpolicies` and `xmeshes` of `gateway.networking.x-k8s.io` — every one at `bundle-version: v1.6.1` (not
   the v1.6.2 this lab installs), and **2 objects annotated `standard` that are not CRDs** (the `safe-upgrades`
   ValidatingAdmissionPolicy and its Binding); a `grep -c` of the channel lines reads 13/2 — the mix this lab avoids;
   `gateway-helm` with `crds.enabled=false` emits **0** CRDs of any kind. The only source of Gateway API CRDs on eg1 is
   upstream's
   `standard-install.yaml`.
3. **The chart does not create GatewayClass `eg`.** Apply it (`controllerName:
   gateway.envoyproxy.io/gatewayclass-controller`).
4. **Coexistence is the path** (not `scripts/eg-lb.sh`). Three filters, all required:
   kube-vip DS `--lbClassOnly` / `lb_class_name=kube-vip.io/kube-vip-class`;
   kube-vip-cloud-provider `KUBEVIP_ENABLE_LOADBALANCERCLASS=true`;
   MetalLB `--lb-class=metallb.io/metallb` on controller **and** speaker. Without the
   cloud-provider env, class-less Services are labelled `implementation=kube-vip` and may
   share a `loadbalancerIPs` annotation with an in-use Service while staying `<pending>`.
5. **MetalLB helm 0.16.0 defaults `frrk8s.enabled: true`.** L2-only: set
   `speaker.frr.enabled=false` and `frrk8s.enabled=false`. Chart value `loadBalancerClass`
   is the `--lb-class` flag.
6. **Do not pass kube-vip `--taint`** — ARP leaders must be able to land on workers
   (`servicesElection`).
7. **R7 / EnvoyProxy timing.** `spec.addresses` → `externalIPs`, no ARP. The LB field on
   EnvoyProxy is what is announced. Combining them works at create time with matching IPs;
   EG does not reject and `status.addresses` stays `spec.addresses`. Attaching
   `loadBalancerClass` later fails (`may not change once set`) — recreate the Gateway.
   Do not trust `kubectl get svc` EXTERNAL-IP as ARP proof.
8. **gRPC on `:80`** works with demo 09's `appProtocol: kubernetes.io/h2c` on the backend
   Service. No BackendTrafficPolicy needed at v1.9.1. R10's premise holds.
9. **Pins live in `scripts/bootstrap/versions-eg.env` for phase 0** (versions.env / lab-up.sh
   were not touched). Phase 1 can still fold them into `versions.env` as the plan says.
10. **`kind load` of a multi-arch nginx index failed** on this kind; import
    `--all-platforms=false` or let the node pull. `routedemo:local` kind-load works.
11. **D1 / memory.** This measurement ran with poc1+poc2 **Up** (~16.1 GiB) plus eg1
    (~1.57 GiB) on a 23.43 GiB / 10 CPU VM. The brief's paused-poc starting point was not
    the live state. eg2 plus demo traffic is the remaining D1 question.
12. **Helm on this Mac is v4.3.0** (lab pin is 3.21.4). OCI install of EG v1.9.1 still
    worked.
13. **IPv6 ULA for `kind-eg` is `fc00:f853:ccd:e794::/64`**, chosen unique, not a hash of
    the network name.
14. **`clusters/eg2.yaml` exists; the cluster does not.** Phase 0 is one cluster.

## What the operator ran, and what the Mac measured after (2026-09-18 20:17 UTC)

The route needs `sudo`; no script in this repository runs it. The operator ran it ("done") and the four addresses
were re-measured **from the Mac**, recorded in `docs/eg-phase0-transcript.txt`:

```text
$ netstat -rn -f inet | grep -E "^172\.19"
172.19             192.168.64.2       UGSc            bridge100
$ ping -c1 -W1 172.19.0.1
64 bytes from 172.19.0.1: icmp_seq=0 ttl=64 time=0.630 ms
$ for ip in 172.19.255.200 172.19.255.206 172.19.255.240 172.19.255.246; do … curl -m 5 http://$ip/ …
172.19.255.200 -> 200        # kube-vip's probe Service, nginx
172.19.255.206 -> 200        # MetalLB's probe Service, nginx
172.19.255.240 -> 404        # the kube-vip Envoy Gateway door — Envoy answers, no routes
172.19.255.246 -> 404        # the MetalLB Envoy Gateway door
```

So R0.1's "no route" verdict is now historical: the two paths (from the Mac with the route; from a container on the
bridge without it) both work and the demos document both. The equivalent route for the Cilium lab,
`sudo route -n add -net 172.18.0.0/16 192.168.64.2`, is also absent on this Mac today (its clusters are paused); a
rebuilt Mac needs both.

**D1, closed:** poc1 and poc2 were still Up during R0.7 because `cluster-pause.sh` had not survived kind's
`--restart=on-failure:1` (gotcha #119, fixed in this PR); they are paused now, and eg1 alone costs ~1.8 GiB
(`docker stats` at 20:20 UTC: eg1-control-plane 1.289 GiB, eg1-worker 529.8 MiB).

Derive the gateway the same way as SETUP 3.5 / NETWORKING_DESIGN §4.3 if `192.168.64.2` is
ever not the VM's address on `bridge100`. The route is not persistent across reboot or a
Docker Desktop restart.

Until that route exists, every client (`curl`, `wget`, `grpcurl`, `arping`) is:

```bash
docker run --rm --network kind-eg alpine:3.20 wget -q -O - http://172.19.255.240/
docker run --rm --network kind-eg --cap-add NET_RAW busybox:1.36 arping -c 3 -I eth0 172.19.255.240
docker run --rm --network kind-eg fullstorydev/grpcurl:latest -plaintext -authority grpc.eg1.poc.local 172.19.255.240:80 grpc.health.v1.Health/Check
```

Cleanup when demo 50 is done (not run in phase 0): `scripts/eg-down.sh` deletes `eg1`/`eg2`
and the `kind-eg` network. It does not touch poc1, poc2, CRC, or `kind`.
