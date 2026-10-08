# aks-design

Design drafts for a large Azure Kubernetes Service (AKS) platform with strong isolation between
**internal / external** workloads and between **countries**, plus application multi-tenancy inside each isolation zone.

> Status: **draft** for review. Country codes `fi` / `se` and all IP ranges are examples.

## Requirements

| # | Requirement | How the design meets it |
|---|---|---|
| R1 | Control plane in a dedicated network | Private, VNet-integrated API server in its own delegated subnet; admin access only via Private Link from a separate management VNet ([picture 3](#3-control-plane)) |
| R2 | Internal and external workloads isolated | Separate isolation zones `int-*` and `ext-*` |
| R3 | Workloads of different countries isolated | Separate isolation zones per country (`*-fi`, `*-se`, …) |
| R4 | Isolation = Key Vault + network + node pool per type | Every zone has its own Key Vault, subnets (NSG + route table) and node pool |
| R5 | Only connectivity mandatory for Kubernetes allowed between zones | Deny-by-default on three layers: NSG, Azure Firewall, Cilium network policy ([picture 5](#5-allowed-and-blocked-flows)) |
| R6 | Applications isolated in namespaces + network policies | Namespace per application, default-deny policies ([picture 7](#7-application-multi-tenancy-inside-a-zone)) |
| R7 | Key Vault multi-tenancy with [Azure RBAC + ABAC](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-abac) | Per-application workload identity with secret-name-prefix conditions ([picture 6](#6-key-vault-per-zone-with-abac-multi-tenancy)) |

**Isolation zone** = one *type* = one combination of exposure × country:

| Zone | Exposure | Country | Node pool | Key Vault | Subnets |
|---|---|---|---|---|---|
| `int-fi` | internal | FI | `intfi` | `kv-int-fi` | `snet-int-fi-*` |
| `int-se` | internal | SE | `intse` | `kv-int-se` | `snet-int-se-*` |
| `ext-fi` | external | FI | `extfi` | `kv-ext-fi` | `snet-ext-fi-*` |
| `ext-se` | external | SE | `extse` | `kv-ext-se` | `snet-ext-se-*` |

Adding a country adds two zones (`int-xx`, `ext-xx`) following the same pattern.

Colour legend in all pictures: grey = control plane / platform, blue = internal, orange = external,
purple = hub / management, green = identity, red dashed = blocked.

---

## 1. Overview

![Overview](images/01-overview.svg)

Hub-and-spoke landing zone. The **hub** holds the shared connectivity services: Azure Firewall (all egress and
east-west inspection), VPN/ExpressRoute gateway, Private DNS and Bastion. A separate **management VNet** hosts
jump hosts and CI/CD agents and is the only place the Kubernetes API can be reached from.
The **AKS spoke** contains a single cluster split into a control plane zone and four workload isolation zones.
External zones receive Internet traffic through their own Application Gateway WAF; internal zones are reached
only from the corporate network through the firewall.

## 2. Network layout

![Network subnets](images/02-network-subnets.svg)

Each zone owns a `/20` in the spoke with dedicated subnets for nodes, pods (Azure CNI with dynamic pod IP
allocation, so pod IPs are routable and subject to NSGs/firewall), ingress and private endpoints.
Every subnet has its own **NSG** (deny VNet-to-VNet by default) and each zone its own **route table** sending
`0.0.0.0/0` *and the other zones' prefixes* to Azure Firewall, so any cross-zone packet that the NSG would allow
is still inspected and denied by the firewall.

> **Why subnets and not separate VNets?** AKS requires all node pool subnets and the API server subnet of one
> cluster to be in the same VNet. Within one cluster, "network per type" is therefore implemented as
> *subnets per type + NSG + UDR via firewall*. If a hard VNet boundary per country is required (e.g. regulatory),
> switch to **one cluster per zone** – the pictures stay the same except that each zone becomes its own spoke.

## 3. Control plane

![Control plane](images/03-control-plane.svg)

The API server uses **API Server VNet Integration**: it is projected as an internal load balancer into a
dedicated, delegated `snet-apiserver` (/28) that contains nothing else. The cluster is **private** (public
endpoint disabled). Admins (Entra ID + PIM, Azure RBAC for Kubernetes) and CI/CD reach it only through a
Private Endpoint / Private Link Service in the management VNet. Nodes talk to the ILB IP directly (no tunnel,
no DNS). The system node pool (tainted `CriticalAddonsOnly`) runs only platform components.

## 4. Node pools

![Node pools](images/04-node-pools.svg)

One node pool per zone, placed in that zone's subnets and tainted `platform/zone=<zone>:NoSchedule`.
Every namespace carries a `platform/zone` label; an admission policy injects the matching `nodeSelector` and
toleration into every pod and **rejects** pods that try to select or tolerate another zone. Only platform
DaemonSets (Cilium, CSI drivers, monitoring) run on all pools.

Note: the kubelet identity is cluster-wide in AKS, so it is **never** granted access to Key Vaults – workloads
use workload identity only (picture 6).

## 5. Allowed and blocked flows

![Allowed flows](images/05-allowed-flows.svg)

Only the flows Kubernetes needs to function are allowed between a workload zone and the rest of the platform:

| # | Source | Destination | Port | Purpose |
|---|---|---|---|---|
| ① | Zone nodes | `snet-apiserver` | TCP 443, 4443 | kubelet / pods → API server |
| ② | `snet-apiserver` | Zone nodes | TCP 10250 | logs, exec, port-forward |
| ③ | Zone pods | CoreDNS (system pods) | UDP/TCP 53 | name resolution |
| ④ | metrics-server (system pods) | Zone nodes | TCP 10250 | resource metrics |
| ⑤ | Zone pods | Own zone Key Vault PE | TCP 443 | secrets |
| ⑥ | Zone nodes + pods | Azure Firewall | per FQDN | AKS required FQDNs, MCR, Entra ID, Azure Monitor |
| ⑦ | Zone nodes | All nodes | TCP 4240, ICMP | Cilium health (optional) |
| – | AzureLoadBalancer | `snet-apiserver` | TCP 9988 | API server health probe |

**Everything else between zones is blocked** – pod-to-pod, pod-to-other-zone Key Vault and direct Internet –
enforced three times: NSG (L3/L4), Azure Firewall (L3–L7, logged), Cilium cluster-wide policy (pod identity).

## 6. Key Vault per zone with ABAC multi-tenancy

![Key Vault ABAC](images/06-key-vault-abac.svg)

Each zone has its **own Key Vault** (RBAC permission model, public access disabled, private endpoint only in the
zone's `snet-*-pe`). Inside a zone's vault, applications share the vault but are separated with
[Azure ABAC conditions](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-abac):

- Each application namespace has a Kubernetes ServiceAccount federated (workload identity) to its own
  user-assigned managed identity.
- That identity gets **Key Vault Secrets User** on the zone vault with condition
  `@Resource[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith '<app>-'`.
- Application pipelines get **Key Vault Secrets Officer** with the same prefix on
  `@Request[...secrets:name]` for `setSecret`.
- Secrets are mounted with the Secrets Store CSI driver.

Constraints to keep in mind: Key Vault ABAC is **preview**, supports **secrets only** (not keys/certificates
operations) and only **vault name + secret name** attributes, and lowercase values. Therefore the secret naming
convention `<app>-<secret>` is mandatory and must be enforced by the platform. A name condition on
`readMetadata` breaks list calls – gate `getSecret` instead.

## 7. Application multi-tenancy inside a zone

![Namespace tenancy](images/07-namespace-tenancy.svg)

Each application gets its own namespace(s) inside a zone, with a baseline policy set applied automatically:

1. default deny ingress and egress;
2. allow DNS to CoreDNS in `kube-system`;
3. allow ingress only from the zone's ingress controller namespace;
4. allow traffic within the namespace;
5. allow egress only to the zone Key Vault private endpoint and approved FQDNs (via firewall).

Applications in the same zone therefore cannot talk to each other unless an explicit policy pair is agreed.
Kubernetes RBAC is namespace-scoped (Entra ID groups per application team), plus ResourceQuota/LimitRange per
namespace.

---

## Open questions

- Single cluster with zones vs. one cluster per zone (or per country) – trade-off between operational cost and
  blast radius / hard network boundary.
- Is CoreDNS on the shared system pool acceptable, or should each zone run its own DNS (e.g. NodeLocal DNS)?
- Should external zones share one Application Gateway for Containers or keep one WAF per zone (current draft)?
- Key Vault ABAC is preview – acceptable for production, or fall back to vault per application until GA?

## Editing the pictures

Sources are Mermaid files in [`diagrams/`](diagrams); rendered SVGs live in [`images/`](images).
After editing a source, regenerate with:

```sh
scripts/render.sh
```
