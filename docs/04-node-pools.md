# 4. Node pools

![Node pools](../images/04-node-pools.svg)

Every isolation zone has its own nodes in that zone's subnets, labelled `platform/zone=<zone>` and tainted
`platform/zone=<zone>:NoSchedule`. How the nodes are created differs per cluster type, because the two cluster types
run different kinds of workloads:

| | Stateless clusters | Stateful cluster |
|---|---|---|
| Zone nodes | [Node auto provisioning](https://learn.microsoft.com/en-us/azure/aks/node-autoprovision) (NAP, AKS-managed Karpenter): two Karpenter `NodePool`s per zone – on-demand (`intfi`, `extfi`, …) and spot (`intfispot`, `extfispot`, …) – sharing one `AKSNodeClass`; no classic node pools for workloads | Classic AKS node pools (VM scale sets), one per zone *and* AZ (`intfiz1`, `intfiz2`, `intfiz3`, …) |
| Subnet | `AKSNodeClass` `vnetSubnetID` = the zone's `snet-<zone>-nodes` | `--vnet-subnet-id` `snet-<zone>-nodes`, `--pod-subnet-id` `snet-<zone>-pods` |
| Availability zone | `NodePool` requirement `topology.kubernetes.io/zone In [<region>-<N>]` – the cell's AZ | `--zones 1` / `2` / `3`, one pool per AZ |
| VM sizes | Chosen by NAP for the pending pods from an allow-list of several VNet-encryption-capable SKU families in the `NodePool` requirements, **amd64 and arm64** | One fixed size per pool, chosen when the workload's exception is onboarded; amd64 |
| Capacity type | On-demand and **spot**, chosen per application ([below](#cpu-architecture-and-spot-chosen-by-the-application)) | On-demand only |
| Scaling | Nodes are created for pending pods and removed or consolidated when they are empty or under-used; the `NodePool` `limits` (CPU, memory) are the upper bound, sized for N+1 | **No autoscaling.** Fixed node count per pool, set in IaC; capacity changes are planned changes |
| Node replacement | Drift (new node image or Kubernetes version), consolidation and `expireAfter`, limited by the `NodePool` disruption budgets; PDBs are respected | Surge upgrade per pool, one AZ at a time ([section 12](12-zero-downtime-cluster-upgrades.md#stateful-cluster)) |
| Defined by | Flux, in `infrastructure/stateless` (subnet IDs and AZ from the `cluster-vars` ConfigMap), applied before anything that runs on zone nodes | Cluster IaC |
| Disk encryption | Cluster's disk encryption set (`key-<cluster>-disk`) on the ephemeral OS disks; `security.encryptionAtHost: true` in every `AKSNodeClass` | Cluster's disk encryption set on the OS disks, `--enable-encryption-at-host`; persistent volumes with the zone's own key ([section 18](18-encryption-at-rest-and-customer-managed-keys.md)) |
| System pool | Classic node pool `system`, fixed node count, pinned to the cell's AZ | Classic node pool `system`, fixed node count, spread over AZ 1–3 |

**Why two models.** Stateless workloads scale on load all day and can be moved at any time, so NAP fits them: it
picks the VM size from what the pending pods need, packs them tightly and gives unused nodes back, and the platform
does not maintain a node pool per zone × VM size or plan the capacity of a freshly built cell. The stateful cluster
runs a few approved StatefulSets and operators that are sized when they are onboarded and do not scale on load;
every node change moves a replica and re-attaches its disks. Fixed-size node pools keep its capacity predictable,
and its nodes change only in planned upgrades – never because an autoscaler decided to consolidate.

NAP details in the stateless clusters:

- NAP is enabled with `--node-provisioning-mode Auto`; the AKS-created default `NodePool`s are disabled
  (`--node-provisioning-default-pools None`), so every NAP node belongs to a zone's `NodePool`. NAP requires Azure CNI
  Overlay powered by Cilium, which the stateless clusters use anyway. The cluster autoscaler is not used anywhere.
- All nodes run **Azure Linux 3.0** (`AKSNodeClass` `imageFamily: AzureLinux`, system pool `--os-sku AzureLinux`),
  which eBPF host routing requires on every node of the cluster ([section 16](16-advanced-networking-and-fqdn-egress.md)).
- Several SKU families in each allow-list lower the risk that the cell's single AZ runs out of capacity for one VM size
  when a cell is pre-scaled to carry the full load ([section 12](12-zero-downtime-cluster-upgrades.md#stateless-clusters)).
- Disruption budgets keep consolidation slow (e.g. at most 10 % of a zone's nodes at a time) and block it while a cell
  is being changed; all applications have ≥ 2 replicas and a PDB, so consolidation never takes an application down.
- Only the platform manages `NodePool` and `AKSNodeClass` objects (Kubernetes RBAC), and Azure Policy rejects any whose
  subnet, label, taint or VM sizes do not match its zone ([section 14](14-policy-enforcement.md)).

## CPU architecture and spot, chosen by the application

To lower cost, the stateless clusters offer **amd64 and arm64** nodes and **on-demand and spot** nodes in every
zone. The platform supports all four combinations; the team that builds an application decides what the application
supports and declares it with two labels in the pod template. Without labels an application gets the safe default,
amd64 on on-demand nodes, so nothing changes for applications that do not opt in.

| Pod label | Values | Effect (injected by Azure Policy mutation) |
|---|---|---|
| `platform/arch` | `amd64` (default) | `nodeSelector` `kubernetes.io/arch: amd64` |
| | `arm64` | `nodeSelector` `kubernetes.io/arch: arm64` |
| | `multi` | no architecture constraint: NAP picks the cheapest fitting VM size of either architecture (usually arm64) and the scheduler may use any free node |
| `platform/capacity` | `on-demand` (default) | nothing – the pod cannot tolerate the spot taint, so it runs only on on-demand nodes |
| | `spot` | toleration `platform/capacity=spot:NoSchedule` and a *preferred* node affinity for `karpenter.sh/capacity-type: spot`: the pod runs on spot nodes when there are any, and on on-demand nodes when spot capacity is not available |

How the platform handles them:

- **Two `NodePool`s per zone**, both allowing `kubernetes.io/arch In [amd64, arm64]`:
  - `<zone>` – `karpenter.sh/capacity-type In [on-demand]`, no extra taint;
  - `<zone>spot` – `karpenter.sh/capacity-type In [spot]`, taint `platform/capacity=spot:NoSchedule`, and a higher
    `weight`, so NAP tries spot first for pods that tolerate it and falls back to the on-demand `NodePool` when Azure
    has no spot capacity for the allowed SKUs in the cell's AZ.

  Both share the zone's `AKSNodeClass` (subnet, image), label and zone taint; the spot taint is what keeps every
  application that did not choose spot away from spot nodes, also from spot nodes that already exist and have room.
- **Allow-lists per architecture**: the SKU allow-list holds amd64 families (e.g. Dsv5/Dsv6, Esv5/Esv6) and arm64
  families (e.g. Dpsv6/Epsv6, Cobalt 100) – only those that support VNet encryption, because it is the only encryption
  between nodes ([section 13](13-encryption-in-transit-and-tls.md)), and encryption at host, which every node has
  ([section 18](18-encryption-at-rest-and-customer-managed-keys.md)). The spot `NodePool` uses the same allow-list:
  several families per architecture also give spot more places to find capacity.
- **Capacity and N+1**: the on-demand `NodePool` limits alone are sized for N+1 (one cell carrying the whole
  environment), because spot capacity can disappear exactly when a cell is pre-scaled. The spot `NodePool` limits cap
  how much of a zone can run on spot.
- **Spot evictions** come with about 30 seconds' notice and do **not** respect PDBs; Azure can evict many spot nodes
  at once. NAP replaces evicted capacity – with spot if it is available, otherwise on-demand. An application may
  choose `spot` only if it tolerates losing replicas suddenly: graceful shutdown within 30 seconds, no long-running
  requests that cannot be retried, and work that is safe to repeat (queue consumers, batch jobs, stateless APIs with
  enough replicas). Latency-critical entry points and singletons-by-design stay on-demand.
- **Images**: `arm64` needs an arm64 image, `multi` a multi-architecture image (OCI image index with `linux/amd64`
  and `linux/arm64`). Admission cannot inspect images, so the build pipeline checks the platforms of the image index
  in ACR against the labels in the rendered manifests before an image is promoted, and the application's tests run on
  every architecture it declares. All platform DaemonSets (Cilium, CSI drivers, monitoring agent) are
  multi-architecture.
- **Validation**: applications set only the labels; Azure Policy rejects unknown label values, pods that set
  `kubernetes.io/arch` or `karpenter.sh/capacity-type` in their own `nodeSelector` / affinity, and pods that tolerate
  `platform/capacity` without the `spot` label ([section 14](14-policy-enforcement.md)).
- **System pool and stateful cluster**: the system pool stays amd64 on-demand. The stateful cluster runs only
  on-demand nodes – a spot eviction would move a replica and re-attach its disks without a PDB – and only amd64 pools;
  in the stateful cluster any label value other than the defaults is rejected. An arm64 pool set (one per zone and
  AZ) can be added when an onboarded workload needs it.

Choosing is a trade-off the application team owns: `multi` + `spot` is the cheapest, `amd64` + `on-demand` the most
predictable. The choice can be changed in any release, because it is only a label in the pod template.

## Zone pinning

Application namespaces are named `<zone>-<app>` and carry the matching `platform/zone` label. The Azure Policy
add-on injects the zone's `nodeSelector` and toleration into every pod (one mutation definition per zone, matched by
the namespace prefix `<zone>-*`) and **rejects** pods that try to select or tolerate another zone. The checks use
the namespace *name*, not a lookup of the namespace's labels, because custom Azure Policy definitions cannot use
Gatekeeper data replication; a separate policy makes sure the label of a namespace matches its name prefix. Only platform
DaemonSets (Cilium, CSI drivers, monitoring) run on all nodes.

Note: the kubelet identity is cluster-wide in AKS, so it is **never** granted access to Key Vaults – workloads
use workload identity only (picture 6).

---

[Back to contents](../README.md) · Previous: [3. Control plane](03-control-plane.md) · Next: [5. Allowed and blocked flows](05-allowed-and-blocked-flows.md)
