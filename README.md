# aks-design

Design drafts for a large Azure Kubernetes Service (AKS) platform with strong isolation between
**internal / external** workloads and between **countries**, plus application multi-tenancy inside each isolation zone.

The platform runs **two types of clusters** – zonal **stateless** clusters in the frontend network and one
zone-redundant **stateful** cluster in the Internet-less backend network – in **dev, acc and prd**, i.e. at least
nine clusters kept in sync with **FluxCD**, with fully automated zero-downtime upgrades of applications and clusters.
Pictures 1–7 describe what is *inside* one cluster; pictures 8–12 describe the fleet of clusters.

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
| R8 | Two cluster types: stateless and stateful | Stateless clusters in the frontend network, one stateful cluster in the backend network ([picture 8](#8-cluster-types-stateless-and-stateful)) |
| R9 | Stateful cluster exists once, in the backend network with the Azure PaaS services, no Internet connectivity at all | Backend spoke with PaaS private endpoints; network isolated AKS (outbound type `none`), no public IPs, Firewall deny-all for backend prefixes |
| R10 | Stateful cluster spread over availability zones and running AKS LTS | Node pools per AZ 1/2/3, ZRS storage, Premium tier with Long Term Support |
| R11 | Stateless: separate cluster per availability zone (at least two), ≥ 2 copies of every application, scaled on load | `sl-az1`, `sl-az2` (+ optional `sl-az3`) behind a zone-redundant traffic layer; policy-enforced replicas ≥ 2, HPA/KEDA, cluster autoscaler |
| R12 | Fully automated zero-downtime upgrades of applications and clusters | Policy-enforced rollout guardrails, wave-based Flux rollout, drain-and-upgrade per stateless cluster, PDB-guarded per-AZ upgrade of the stateful cluster ([section 11](#11-zero-downtime-application-upgrades), [section 12](#12-zero-downtime-cluster-upgrades)) |
| R13 | dev, acc and prd environments kept in sync | 3 × 3 = 9 clusters from the same IaC modules, all in-cluster state from one Git repository via FluxCD ([picture 9](#9-environments-nine-clusters), [picture 10](#10-keeping-clusters-in-sync-with-fluxcd)) |

**Isolation zone** = one *type* = one combination of exposure × country:

| Zone | Exposure | Country | Node pool | Key Vault | Subnets |
|---|---|---|---|---|---|
| `int-fi` | internal | FI | `intfi` | `kv-int-fi` | `snet-int-fi-*` |
| `int-se` | internal | SE | `intse` | `kv-int-se` | `snet-int-se-*` |
| `ext-fi` | external | FI | `extfi` | `kv-ext-fi` | `snet-ext-fi-*` |
| `ext-se` | external | SE | `extse` | `kv-ext-se` | `snet-ext-se-*` |

Adding a country adds two zones (`int-xx`, `ext-xx`) following the same pattern.

Colour legend in all pictures: grey = control plane / platform / PaaS, blue = internal, orange = external,
purple = hub / management, green = identity, teal = stateless cluster, pink = stateful cluster,
yellow = notes / policy, red dashed = blocked.

---

## 1. Overview

![Overview](images/01-overview.svg)

Hub-and-spoke landing zone. The **hub** holds the shared connectivity services: Azure Firewall (all egress and
east-west inspection), VPN/ExpressRoute gateway, Private DNS and Bastion. A separate **management VNet** hosts
jump hosts and CI/CD agents and is the only place the Kubernetes API can be reached from.
Each **AKS spoke** contains one cluster split into a control plane zone and four workload isolation zones.
Every cluster of the fleet – stateless or stateful – has this same inner layout; how the clusters are placed in
the frontend and backend networks is shown in [picture 8](#8-cluster-types-stateless-and-stateful).
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


## 8. Cluster types: stateless and stateful

![Cluster topology](images/08-cluster-topology.svg)

Every environment has two kinds of clusters. The split follows one rule: **a cluster that holds no data can be
taken out of traffic, upgraded or even rebuilt at any time; a cluster that holds data cannot, so it is made
zone-redundant and changed as rarely as possible.**

| | Stateless (`aks-<env>-sl-az<N>`) | Stateful (`aks-<env>-sf`) |
|---|---|---|
| Runs | Frontends, APIs, workers – anything that can be killed and recreated | Workloads that own data on disks (StatefulSets, operators) and backend services that must sit next to the data |
| Count per environment | One per availability zone: `sl-az1`, `sl-az2` mandatory, `sl-az3` optional (recommended for prd) | Exactly one |
| Availability zones | All node pools of a cluster pinned to its AZ (`--zones <N>`); the cluster is the unit of failure | Every isolation zone has one node pool per AZ (`intfiz1`, `intfiz2`, `intfiz3`, …); system pool spread over AZ 1–3 |
| Network | Frontend spoke `vnet-<env>-sl-az<N>`, peered to the hub | Backend spoke `vnet-<env>-sf`, peered to the hub, together with the PaaS private endpoints |
| Internet | Egress only via Azure Firewall FQDN allow-list (outbound type `userDefinedRouting`); ingress only via the traffic layer | **None.** [Network isolated cluster](https://learn.microsoft.com/en-us/azure/aks/concepts-network-isolated) (outbound type `none`, bootstrap artifacts from the private ACR cache), no public IPs, UDR `0.0.0.0/0` → Firewall which denies all Internet for backend prefixes |
| Kubernetes version | Standard support, latest GA minus one | [Long Term Support](https://learn.microsoft.com/en-us/azure/aks/long-term-support) (`--tier premium --k8s-support-plan AKSLongTermSupport`) |
| Tier | Standard | Premium (required for LTS) |
| Scaling | ≥ 2 replicas per app, HPA / KEDA on load, cluster autoscaler; **each cluster sized to carry 100 % of the load alone** | ≥ 3 replicas per StatefulSet, one per AZ; cluster autoscaler per AZ node pool |
| Storage | None – admission policy rejects PersistentVolumeClaims; ephemeral OS disks | Azure Disk `Premium_ZRS` / `StandardSSD_ZRS`, Azure Files ZRS; prefer PaaS for databases |
| Upgrade model | Drain from traffic, upgrade or rebuild, return ([picture 11](#stateless-clusters)) | In place, one AZ at a time, PDB-protected ([picture 12](#stateful-cluster)) |

**Isolation zones are kept in both cluster types.** Each stateless and the stateful cluster have the node pools,
subnets, Key Vaults and policies of zones `int-fi`, `int-se`, `ext-fi`, `ext-se` exactly as in pictures 2–7 – the data
in the stateful cluster is what needs the country separation most. In the stateful cluster no zone has an Internet-facing
ingress: its `ext-*` zones only accept traffic from the same `ext-*` zone of the stateless clusters.

**Traffic layer.** External zones are published through a zone-redundant Application Gateway WAF v2 (or Azure Front
Door Premium with Private Link origins); internal zones through an internal Application Gateway behind the hub Firewall.
The backend pool of every listener contains the ingress internal load balancer of *every* stateless cluster. A failed
health probe removes a cluster automatically; the upgrade pipeline removes it deliberately by setting its weight to 0.

### Address plan (example)

Each cluster gets its own spoke VNet so that a stateless cluster can be rebuilt together with its network without
touching the others. Inside each spoke the layout of [picture 2](#2-network-layout) is reused (`10.10.x.x` → `10.<n>.x.x`).

| Environment | `sl-az1` | `sl-az2` | `sl-az3` (optional) | `sf` (backend) |
|---|---|---|---|---|
| dev | 10.11.0.0/16 | 10.12.0.0/16 | 10.13.0.0/16 | 10.14.0.0/16 |
| acc | 10.21.0.0/16 | 10.22.0.0/16 | 10.23.0.0/16 | 10.24.0.0/16 |
| prd | 10.31.0.0/16 | 10.32.0.0/16 | 10.33.0.0/16 | 10.34.0.0/16 |

In the backend spoke each isolation zone's `snet-<zone>-pe` also holds the private endpoints of that zone's PaaS
services (SQL, Storage, Service Bus, …); a shared `snet-shared-pe` holds the ACR private endpoint used by all clusters
of the environment. Pod subnets of stateless clusters are sized for the full load of the environment (N+1).

### Flows between frontend and backend

| Source | Destination | Port | Rule |
|---|---|---|---|
| Stateless zone *X* pods | Stateful zone *X* internal ingress ILB | TCP 443 | Same isolation zone only (`int-fi` → `int-fi`), via Firewall |
| Stateless zone *X* pods | Zone *X* PaaS private endpoints | TCP 443, 1433, 5432, 5671 | Same isolation zone only, via Firewall |
| All nodes of the environment | ACR private endpoint | TCP 443 | Images, Helm charts, Flux OCI artifacts |
| Stateful cluster | Frontend networks | – | **Blocked** – the backend never initiates connections to the frontend |
| Stateful cluster | Internet | – | **Blocked** – no route, no outbound IP, Firewall deny-all |
| Stateful nodes / pods | Microsoft Entra ID (`AzureActiveDirectory` service tag) | TCP 443 | Only exception, needed for workload identity token exchange because Entra ID has no Private Link for sign-in – see open questions |

Azure Monitor is reached through an Azure Monitor Private Link Scope. AKS add-ons that need public Azure endpoints
(e.g. the Azure Policy add-on) are not enabled in the stateful cluster; the same policies are delivered by Flux as
Kyverno / Gatekeeper policies.

## 9. Environments (nine clusters)

![Environments](images/09-environments.svg)

| Environment | Subscription | Stateless | Stateful | Clusters |
|---|---|---|---|---|
| dev | `sub-aks-dev` | `aks-dev-sl-az1`, `aks-dev-sl-az2` | `aks-dev-sf` | 3 |
| acc | `sub-aks-acc` | `aks-acc-sl-az1`, `aks-acc-sl-az2` | `aks-acc-sf` | 3 |
| prd | `sub-aks-prd` | `aks-prd-sl-az1`, `aks-prd-sl-az2` (+ `aks-prd-sl-az3`) | `aks-prd-sf` | 3 (4) |

**Minimum 9 clusters**, 10 with a third stateless cluster in prd, 12 with three everywhere. dev and acc must have the
*same topology* as prd (at least two stateless clusters and a three-AZ stateful cluster), otherwise the upgrade
procedures cannot be rehearsed there; they can use smaller VM sizes and lower autoscaler limits.

- **Clusters are cattle, built by IaC.** Two IaC modules (stateless, stateful) with `env` and `az` as parameters
  create the VNet, cluster, node pools, identities, Key Vaults and the Flux bootstrap. The IaC also writes a
  `cluster-vars` ConfigMap (`ENV`, `CLUSTER_TYPE`, `AZ`, `CLUSTER_NAME`) that Flux uses for substitutions.
- **Everything inside a cluster comes from Git via Flux** – no manual `kubectl apply`; human write access in acc
  and prd is read-only Kubernetes RBAC plus break-glass via PIM.
- **Every environment has its own ACR** (in its backend spoke); the promotion pipeline imports the exact image
  digests from the previous environment's ACR (`az acr import`), so prd never pulls from the Internet.

## 10. Keeping clusters in sync with FluxCD

![GitOps with Flux](images/10-gitops-flux.svg)

One **fleet repository** describes all nine clusters. Shared content lives once in `base`; cluster type and
environment differences are Kustomize overlays:

```text
fleet/
├── clusters/                      # entry point of each cluster (Flux Kustomizations only)
│   ├── dev/{sl-az1,sl-az2,sf}/
│   ├── acc/{sl-az1,sl-az2,sf}/
│   └── prd/{sl-az1,sl-az2,sl-az3,sf}/
├── infrastructure/
│   ├── base/                      # Cilium policies, Kyverno/Gatekeeper policies, CSI, monitoring, ingress
│   ├── stateless/                 # PVC deny policy, HPA/KEDA, ingress for the traffic layer
│   └── stateful/                  # storage classes (ZRS), operators, internal ingress
└── apps/
    └── <app>/
        ├── base/
        ├── stateless/{dev,acc,prd}/   # image digests + replicas/HPA per environment
        └── stateful/{dev,acc,prd}/
```

- **Flux installation**: by IaC as the AKS GitOps extension (`microsoft.flux`) or upstream Flux via Helm – same
  version on all clusters, upgraded like any other platform component (dev first).
- **Source = OCI artifact in the environment's ACR, not Git.** The stateful cluster cannot reach a Git server on the
  Internet, and using the same mechanism everywhere keeps all clusters identical. On merge to `main`, CI validates
  (`kustomize build`, kubeconform, policy tests), runs `flux push artifact oci://<acr>.azurecr.io/fleet:<git-sha>`,
  signs it with cosign and tags it. Flux's `OCIRepository` pulls it through the ACR private endpoint with workload
  identity (`provider: azure`) and verifies the signature.
- **Order inside a cluster**: Kustomization `dependsOn` chain `infra-controllers` → `infra-configs` (policies, CRDs)
  → `apps`, each with `wait: true` and health checks, `prune: true` to remove anything deleted from Git.
- **Waves inside an environment**: `sl-az1` follows tag `<env>-wave1`; `sl-az2`, `sl-az3` and `sf` follow
  `<env>-wave2`. CI moves `wave2` only after all wave 1 Kustomizations are `Ready` and the error-rate / latency checks
  pass, so a bad change never reaches every stateless cluster at once. Rollback = move the tag back.
- **Promotion between environments** is a pull request that copies the tested image digests and configuration from
  the `dev` overlay to `acc`, then to `prd` (generated by the pipeline, approved by humans for prd).
- **Drift** is corrected on every reconcile (interval 10 min, alerts to the platform channel through Flux
  notification-controller).

## 11. Zero-downtime application upgrades

The same rules apply in every cluster and are **enforced by admission policy** (delivered by Flux), so no
application can be deployed in a way that breaks a zero-downtime rollout or a node drain:

| Guardrail | Stateless | Stateful |
|---|---|---|
| Replicas | `replicas` / HPA `minReplicas` ≥ 2 | ≥ 3, one per AZ |
| Spread | `topologySpreadConstraints` over nodes | `topologySpreadConstraints` over `topology.kubernetes.io/zone` |
| PodDisruptionBudget | Mandatory, `maxUnavailable: 1` (or ≤ 50 %) | Mandatory, `maxUnavailable: 1` |
| Rollout strategy | `RollingUpdate`, `maxUnavailable: 0`, `maxSurge: 25%` | `RollingUpdate` (optionally `partition` for canary) or operator-managed |
| Probes | readiness + liveness (+ startup) required | readiness gated on replication / quorum |
| Graceful shutdown | `preStop` delay + `terminationGracePeriodSeconds` longer than the ingress drain time | same, plus clean leader hand-over |
| Resources | requests required (HPA and autoscaler depend on them) | requests = limits for memory |
| Images | by digest, from the environment's ACR only | same |

- **Scaling on load**: HPA on CPU/memory or KEDA on queue length / request rate; the cluster autoscaler adds nodes.
  In stateless clusters `maxReplicas` and autoscaler limits are sized so that one cluster can take the full load.
- **Compatibility rule**: during a wave rollout two versions run at the same time (different clusters), so API and
  message changes must be backwards compatible and database changes follow *expand → migrate → contract* over
  separate releases.
- **Progressive delivery (optional)**: Flagger with the ingress controller for canary releases with automatic
  rollback inside a stateless cluster.

## 12. Zero-downtime cluster upgrades

Cluster upgrades are triggered by pipelines (or Azure Kubernetes Fleet Manager update runs) in a fixed order:
**dev → acc → prd**, each with a soak period, and within an environment as below. Nothing is upgraded by hand.

### Stateless clusters

![Stateless upgrade](images/11-stateless-upgrade.svg)

One zonal cluster at a time is **taken out of traffic, upgraded and returned** – users never hit a cluster that is
being changed:

1. pre-scale the remaining cluster(s) to full-load capacity;
2. set the cluster's weight to 0 in the traffic layer and wait for connection draining;
3. upgrade control plane and node pools – or, for large changes (new VNet, CNI, OS SKU), **create a fresh cluster**
   from IaC and let Flux bootstrap it (blue/green at cluster level);
4. wait until all Flux Kustomizations are `Ready`, run smoke and synthetic tests against the cluster's own ingress;
5. return traffic gradually (10 % → 50 % → 100 %) while watching error-rate and latency SLOs; on breach set the
   weight back to 0 and stop;
6. repeat for the next zonal cluster.

Node image / OS security updates use the same procedure or – because every app has ≥ 2 replicas and a PDB – the AKS
node OS auto-upgrade channel in maintenance windows staggered per cluster (`sl-az1` and `sl-az2` never on the same day).
Prerequisite for all of this is **N+1 capacity**: autoscaler limits, vCPU quota and pod subnet size must allow one
cluster to carry the whole environment.

### Stateful cluster

![Stateful upgrade](images/12-stateful-upgrade.svg)

There is only one stateful cluster, so it is upgraded **in place** and protected by zone redundancy:

- **Version policy**: LTS minor version; auto-upgrade channel `patch` and node OS channel `NodeImage`, each inside a
  planned maintenance window (`aksManagedAutoUpgradeSchedule`, `aksManagedNodeOSUpgradeSchedule`) staggered so that
  dev is upgraded a week before acc and two weeks before prd.
- **Control plane**: zone-redundant (Premium tier); upgrading it does not restart workloads.
- **Node pools**: one pool per isolation zone *and* AZ, so a pool upgrade touches only one AZ. Surge settings
  `maxSurge: 1`, `maxUnavailable: 0`, a drain timeout and node soak time; drains respect the PDBs, so at most one
  replica of each StatefulSet is down at any moment. The surge node is created in the same AZ, so zonal disks
  re-attach; ZRS disks additionally allow a pod to move to another AZ.
- **LTS minor upgrades** (rare, once per LTS cycle): the same procedure, rehearsed in dev and acc first. Alternative
  for risky jumps: add new node pools on the new version, cordon and drain the old pools AZ by AZ, delete them.

---

## Open questions

- Single cluster with zones vs. one cluster per zone (or per country) – trade-off between operational cost and
  blast radius / hard network boundary.
- Is CoreDNS on the shared system pool acceptable, or should each zone run its own DNS (e.g. NodeLocal DNS)?
- Should external zones share one Application Gateway for Containers or keep one WAF per zone (current draft)?
- Key Vault ABAC is preview – acceptable for production, or fall back to vault per application until GA?
- Two or three stateless clusters per environment? Two is the minimum, but then each must carry 100 % of the load and
  an AZ outage *during* an upgrade leaves no redundancy; three needs only 50 % headroom per cluster.
- "No Internet" for the stateful cluster: is the Entra ID (`AzureActiveDirectory` service tag) exception for workload
  identity acceptable, or must stateful workloads avoid Entra-authenticated access?
- Which workloads really need the stateful cluster? Every database or broker that can be an Azure PaaS service in the
  backend network reduces the size and upgrade risk of the stateful cluster.
- Traffic layer: Application Gateway per environment, or Azure Front Door Premium for external zones (also enables a
  second region later)?
- Flux as AKS GitOps extension (Microsoft-managed upgrades) or upstream Flux (newer features, own lifecycle)?

## Editing the pictures

Sources are Mermaid files in [`diagrams/`](diagrams); rendered SVGs live in [`images/`](images).
After editing a source, regenerate with:

```sh
scripts/render.sh
```
