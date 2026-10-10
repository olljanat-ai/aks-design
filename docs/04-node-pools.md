# 4. Node pools

![Node pools](../images/04-node-pools.svg)

Every isolation zone has its own nodes in that zone's subnets, labelled `platform/zone=<zone>` and tainted
`platform/zone=<zone>:NoSchedule`. How the nodes are created differs per cluster type, because the two cluster types
run different kinds of workloads:

| | Stateless clusters | Stateful cluster |
|---|---|---|
| Zone nodes | [Node auto provisioning](https://learn.microsoft.com/en-us/azure/aks/node-autoprovision) (NAP, AKS-managed Karpenter): one Karpenter `NodePool` + `AKSNodeClass` per zone (`intfi`, `extfi`, …); no classic node pools for workloads | Classic AKS node pools (VM scale sets), one per zone *and* AZ (`intfiz1`, `intfiz2`, `intfiz3`, …) |
| Subnet | `AKSNodeClass` `vnetSubnetID` = the zone's `snet-<zone>-nodes` | `--vnet-subnet-id` `snet-<zone>-nodes`, `--pod-subnet-id` `snet-<zone>-pods` |
| Availability zone | `NodePool` requirement `topology.kubernetes.io/zone In [<region>-<N>]` – the cell's AZ | `--zones 1` / `2` / `3`, one pool per AZ |
| VM sizes | Chosen by NAP for the pending pods from an allow-list of several VNet-encryption-capable SKU families in the `NodePool` requirements | One fixed size per pool, chosen when the workload's exception is onboarded |
| Scaling | Nodes are created for pending pods and removed or consolidated when they are empty or under-used; the `NodePool` `limits` (CPU, memory) are the upper bound, sized for N+1 | **No autoscaling.** Fixed node count per pool, set in IaC; capacity changes are planned changes |
| Node replacement | Drift (new node image or Kubernetes version), consolidation and `expireAfter`, limited by the `NodePool` disruption budgets; PDBs are respected | Surge upgrade per pool, one AZ at a time ([section 12](12-zero-downtime-cluster-upgrades.md#stateful-cluster)) |
| Defined by | Flux, in `infrastructure/stateless` (subnet IDs and AZ from the `cluster-vars` ConfigMap), applied before anything that runs on zone nodes | Cluster IaC |
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
- Several SKU families in each allow-list lower the risk that the cell's single AZ runs out of capacity for one VM size
  when a cell is pre-scaled to carry the full load ([section 12](12-zero-downtime-cluster-upgrades.md#stateless-clusters)).
- Disruption budgets keep consolidation slow (e.g. at most 10 % of a zone's nodes at a time) and block it while a cell
  is being changed; all applications have ≥ 2 replicas and a PDB, so consolidation never takes an application down.
- Only the platform manages `NodePool` and `AKSNodeClass` objects (Kubernetes RBAC), and Azure Policy rejects any whose
  subnet, label, taint or VM sizes do not match its zone ([section 14](14-policy-enforcement.md)).

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
