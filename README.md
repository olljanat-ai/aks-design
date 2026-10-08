# aks-design

Design drafts for a large Azure Kubernetes Service (AKS) platform with strong isolation between
**internal / external** workloads and between **countries**, plus application multi-tenancy inside each isolation zone.

The platform runs **two types of clusters** – zonal **stateless** clusters in the frontend network and one
zone-redundant **stateful** cluster in the Internet-less backend network – in **dev, acc and prd**, i.e. at least
nine clusters kept in sync with **FluxCD**, with fully automated zero-downtime upgrades of applications and clusters.
Data belongs in **Azure PaaS services**; the stateful cluster is the *last option*, used only when no suitable PaaS
service exists or a special use case requires it. All admission policies are implemented with **OPA Gatekeeper**.
Pictures 1–7 describe what is *inside* one cluster; pictures 8–13 describe the fleet of clusters and how traffic is
encrypted.

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
| R7 | Key Vault multi-tenancy with [Azure RBAC + ABAC](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-abac) | Per-application workload identity with secret-name-prefix conditions ([picture 6](#6-workload-identity-first-key-vault-secrets-only-when-needed)) |
| R7a | Workload identities wherever possible, secrets only when needed | Per-application workload identity with Entra ID auth to all Azure services, local auth disabled by Azure Policy; Key Vault secrets only for targets without Entra ID ([section 6](#6-workload-identity-first-key-vault-secrets-only-when-needed)) |
| R8 | Two cluster types: stateless and stateful | Stateless clusters in the frontend network, one stateful cluster in the backend network ([picture 8](#8-cluster-types-stateless-and-stateful)) |
| R8a | Stateful cluster is the last option | Placement order stateless cluster → Azure PaaS → stateful cluster; the stateful cluster needs a documented exception ([where does a workload run](#where-does-a-workload-run)) |
| R9 | Stateful cluster exists once, in the backend network with the Azure PaaS services, no Internet connectivity at all | Backend spoke with PaaS private endpoints; network isolated AKS (outbound type `none`), no public IPs, Firewall deny-all for backend prefixes |
| R9a | Stateful cluster: VNet-integrated CNI, no ingress controller / Gateway API, applications handle TLS | Azure CNI (VNet, dynamic pod IP allocation) powered by Cilium; applications are published with internal `LoadBalancer` Services and terminate TLS themselves ([section 13](#13-encryption-in-transit-and-tls)) |
| R9b | Stateless clusters: overlay CNI, no service mesh / mTLS / application TLS, TLS-only Gateway API | Azure CNI Overlay powered by Cilium, Azure Virtual Network encryption between nodes, Traefik as Gateway API implementation with Let's Encrypt certificates for internal DNS names and HTTPS-only listeners ([section 13](#13-encryption-in-transit-and-tls)) |
| R10 | Stateful cluster spread over availability zones and running AKS LTS | Node pools per AZ 1/2/3, ZRS storage, Premium tier with Long Term Support |
| R11 | Stateless: separate cluster per availability zone (at least two), ≥ 2 copies of every application, scaled on load | `sl-az1`, `sl-az2` (+ optional `sl-az3`) behind a zone-redundant traffic layer; policy-enforced replicas ≥ 2, HPA/KEDA, cluster autoscaler |
| R12 | Fully automated zero-downtime upgrades of applications and clusters | Policy-enforced rollout guardrails, wave-based Flux rollout, drain-and-upgrade per stateless cluster, PDB-guarded per-AZ upgrade of the stateful cluster ([section 11](#11-zero-downtime-application-upgrades), [section 12](#12-zero-downtime-cluster-upgrades)) |
| R13 | dev, acc and prd environments kept in sync | 3 × 3 = 9 clusters from the same IaC modules, all in-cluster state from one Git repository via FluxCD ([picture 9](#9-environments-nine-clusters), [picture 10](#10-keeping-clusters-in-sync-with-fluxcd)) |
| R14 | One policy engine | OPA Gatekeeper (upstream, delivered by Flux) in every cluster; Azure Policy only for Azure resources ([section 14](#14-policy-enforcement-with-gatekeeper)) |

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
only from the corporate network through the firewall. In both cases the traffic ends at the zone's Traefik gateway
in a stateless cluster – the stateful cluster is never reached from outside the platform.

## 2. Network layout

![Network subnets](images/02-network-subnets.svg)

Each zone owns a `/20` in the spoke with dedicated subnets for nodes, internal load balancers and private
endpoints. Whether the zone also has a pod subnet depends on the cluster type's CNI:

| | Stateful cluster | Stateless clusters |
|---|---|---|
| CNI | Azure CNI, VNet-integrated with dynamic pod IP allocation, powered by Cilium | Azure CNI Overlay, powered by Cilium |
| Pod IPs | From `snet-<zone>-pods` – routable in the VNet, visible to NSGs and the firewall | From a private overlay CIDR outside the VNet (the same CIDR can be reused in every stateless cluster) |
| Pod traffic leaving the cluster | Keeps the pod IP | SNAT to the node IP, so NSGs and the firewall see the zone's `snet-<zone>-nodes` |
| `snet-<zone>-pods` | Yes | Not needed |
| `snet-<zone>-ilb` | Internal load balancers of the applications' `LoadBalancer` Services | Internal load balancer of the zone's Traefik gateway |

Zone isolation works the same with both CNIs because every zone has its own node pool in its own node subnet: a
packet from a stateless zone always carries an address of that zone's subnets.
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
Every namespace carries a `platform/zone` label; Gatekeeper injects the matching `nodeSelector` and
toleration into every pod (one `Assign` mutation per zone, matched by `namespaceSelector`) and **rejects** pods that
try to select or tolerate another zone (constraint comparing the pod with its namespace's label; namespaces are
synced into the Gatekeeper cache). Only platform
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
| ⑤ | Zone pods | Own zone Key Vault PE | TCP 443 | secrets (only applications that need one) |
| ⑥ | Zone nodes + pods | Azure Firewall | per FQDN | AKS required FQDNs, MCR, Entra ID (workload identity token exchange), Azure Monitor |
| ⑦ | Zone nodes | All nodes | TCP 4240, ICMP | Cilium health (optional) |
| – | AzureLoadBalancer | `snet-apiserver` | TCP 9988 | API server health probe |

**Everything else between zones is blocked** – pod-to-pod, pod-to-other-zone Key Vault and direct Internet –
enforced three times: NSG (L3/L4), Azure Firewall (L3–L7, logged), Cilium cluster-wide policy (pod identity).

## 6. Workload identity first, Key Vault secrets only when needed

![Workload identity and Key Vault](images/06-key-vault-abac.svg)

**Rule: an application authenticates with its workload identity wherever the target supports Microsoft Entra ID;
a secret is used only when there is no other way.** No passwords, connection strings with keys, SAS tokens or
storage account keys for Azure services.

### Workload identity per application

- Each application has, per isolation zone and environment, its own user-assigned managed identity
  (`id-<zone>-<app>`), created by IaC together with the namespace. Its Kubernetes ServiceAccount carries the
  `azure.workload.identity/client-id` annotation; pods get a short-lived projected token that is exchanged for an
  Entra ID token – nothing long-lived is stored anywhere.
- **Federated credentials per cluster**: every cluster has its own OIDC issuer, so the identity has one federated
  credential per cluster of the environment (`sl-az1`, `sl-az2`, (`sl-az3`), `sf`) for subject
  `system:serviceaccount:<namespace>:<app>`. A rebuilt stateless cluster gets a new issuer; the IaC that creates the
  cluster also updates the federated credentials (a managed identity allows at most 20).
- The identity gets **data-plane roles directly on the Azure resources of its zone**, never on other zones:

| Target | How the application authenticates | Local auth disabled with |
|---|---|---|
| Azure SQL Database | Entra token (`Active Directory Default` in the driver), contained database user for the identity | Entra-only authentication |
| Azure Database for PostgreSQL | Entra token as password, role mapped to the identity | Entra-only authentication |
| Storage (Blob, Queue, Table, Files REST) | `Storage Blob Data …` roles | `allowSharedKeyAccess: false` |
| Service Bus, Event Hubs | `… Data Sender / Receiver` roles | `disableLocalAuth: true` |
| Cosmos DB | Cosmos DB data-plane RBAC | `disableLocalAuth: true` |
| Azure Cache for Redis | Entra authentication, access policy for the identity | access keys disabled |
| Key Vault (only for the secrets below) | `Key Vault Secrets User` with ABAC condition | RBAC permission model |
| Other Azure APIs (App Configuration, Azure OpenAI, …) | Azure RBAC roles | `disableLocalAuth` where available |

  "Local auth disabled" is enforced with Azure Policy on the resources, so a key-based fallback cannot be switched
  on later. Application configuration contains only endpoints and client IDs, which are not secrets.
- **Platform components use workload identity too**: Flux (`OCIRepository` `provider: azure`), cert-manager (DNS-01),
  the Secrets Store CSI driver (per application identity), the Azure Monitor agent, external-dns. Images are pulled
  with the kubelet identity, which has only `AcrPull` on the environment's ACR – no `imagePullSecrets`.

### Secrets only when needed

A secret is allowed only when the target cannot use Entra ID: third-party APIs and SaaS keys, partner systems, legacy
protocols, and the TLS certificates of the stateful applications ([section 13](#13-encryption-in-transit-and-tls)).
Such a secret always lives in the zone's **Key Vault** – never in Git, Helm values or a Kubernetes `Secret` created by
hand.

Each zone has its **own Key Vault** (RBAC permission model, public access disabled, private endpoint only in the
zone's `snet-*-pe`). Inside a zone's vault, applications share the vault but are separated with
[Azure ABAC conditions](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-abac):

- The application's workload identity gets **Key Vault Secrets User** on the zone vault with condition
  `@Resource[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith '<app>-'`.
- Application pipelines get **Key Vault Secrets Officer** with the same prefix on
  `@Request[...secrets:name]` for `setSecret`; rotation is owned by the application team (expiry dates set, Event
  Grid `SecretNearExpiry` alerts).
- Secrets are mounted as **files** with the Secrets Store CSI driver; syncing them into Kubernetes `Secret` objects
  (`secretObjects`) is rejected by Gatekeeper, as are hand-made `Opaque` Secrets in application namespaces
  ([section 14](#14-policy-enforcement-with-gatekeeper)).

Constraints to keep in mind: Key Vault ABAC is **preview**, supports **secrets only** (not keys/certificates
operations) and only **vault name + secret name** attributes, and lowercase values. Therefore the secret naming
convention `<app>-<secret>` is mandatory and must be enforced by the platform. A name condition on
`readMetadata` breaks list calls – gate `getSecret` instead. Because most applications need no secrets at all, the
vault stays small and the preview dependency affects only the few exceptions.

## 7. Application multi-tenancy inside a zone

![Namespace tenancy](images/07-namespace-tenancy.svg)

Each application gets its own namespace(s) inside a zone, with a baseline policy set applied automatically:

1. default deny ingress and egress;
2. allow DNS to CoreDNS in `kube-system`;
3. allow ingress only from the zone's Traefik gateway namespace (stateless clusters) or, in the stateful cluster,
   only from the node subnets of the same zone in the stateless clusters (Cilium CIDR policy; the applications'
   `LoadBalancer` Services use `externalTrafficPolicy: Local` so the client IP is preserved);
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

### Where does a workload run

Data does not belong in Kubernetes by default. Every workload is placed by going down this list and stopping at the
first option that fits:

1. **Stateless cluster** – all application code. Its state lives in the options below.
2. **Azure PaaS service in the backend network** (Azure SQL / PostgreSQL, Storage, Service Bus, Event Hubs, Cosmos DB,
   Cache for Redis, …) reached through private endpoints from the stateless clusters. Zone redundancy, backups,
   patching and upgrades are Microsoft's job.
3. **Stateful cluster – last option**, only when
   - no Azure PaaS service provides the capability (e.g. a product that is only shipped as a container or operator), or
   - a special use case requires it (e.g. a licence, a latency requirement to data that only the cluster can meet,
     a protocol the PaaS service does not offer).

A workload in the stateful cluster needs a documented exception (why 1 and 2 do not fit, owner, exit plan) approved by
the platform team; the exception is the label `platform/stateful-exception=<ticket>` on its namespace, required by a
Gatekeeper constraint. The exceptions are reviewed when new PaaS services become available. The fewer workloads the
stateful cluster runs, the smaller its blast radius and upgrade risk.

### Comparison

| | Stateless (`aks-<env>-sl-az<N>`) | Stateful (`aks-<env>-sf`) |
|---|---|---|
| Runs | Frontends, APIs, workers – anything that can be killed and recreated; state in Azure PaaS | Only approved exceptions: workloads that own data on disks (StatefulSets, operators) for which no PaaS service fits |
| Count per environment | One per availability zone: `sl-az1`, `sl-az2` mandatory, `sl-az3` optional (recommended for prd) | Exactly one |
| Availability zones | All node pools of a cluster pinned to its AZ (`--zones <N>`); the cluster is the unit of failure | Every isolation zone has one node pool per AZ (`intfiz1`, `intfiz2`, `intfiz3`, …); system pool spread over AZ 1–3 |
| Network | Frontend spoke `vnet-<env>-sl-az<N>`, peered to the hub | Backend spoke `vnet-<env>-sf`, peered to the hub, together with the PaaS private endpoints |
| Internet | Egress only via Azure Firewall FQDN allow-list (outbound type `userDefinedRouting`); ingress only via the traffic layer | **None.** [Network isolated cluster](https://learn.microsoft.com/en-us/azure/aks/concepts-network-isolated) (outbound type `none`, bootstrap artifacts from the private ACR cache), no public IPs, UDR `0.0.0.0/0` → Firewall which denies all Internet for backend prefixes |
| CNI | [Azure CNI Overlay](https://learn.microsoft.com/en-us/azure/aks/concepts-network-azure-cni-overlay) powered by Cilium | Azure CNI (VNet-integrated, dynamic pod IP allocation) powered by Cilium |
| Ingress | Traefik as [Gateway API](https://gateway-api.sigs.k8s.io/) implementation, one gateway per isolation zone, HTTPS only | **No ingress controller and no Gateway API.** Applications are published with internal `LoadBalancer` Services (L4) |
| TLS | Terminated by Traefik with Let's Encrypt certificates for internal DNS names; applications serve plain HTTP inside the cluster | **Terminated by the application itself** – a hard onboarding requirement |
| Node-to-node encryption | [Azure Virtual Network encryption](https://learn.microsoft.com/en-us/azure/virtual-network/virtual-network-encryption-overview) – no service mesh, no mTLS | Application TLS (VNet encryption may be enabled as defence in depth but is not relied on) |
| Kubernetes version | Standard support, latest GA minus one | [Long Term Support](https://learn.microsoft.com/en-us/azure/aks/long-term-support) (`--tier premium --k8s-support-plan AKSLongTermSupport`) |
| Tier | Standard | Premium (required for LTS) |
| Scaling | ≥ 2 replicas per app, HPA / KEDA on load, cluster autoscaler; **each cluster sized to carry 100 % of the load alone** | ≥ 3 replicas per StatefulSet, one per AZ; cluster autoscaler per AZ node pool |
| Storage | None – admission policy rejects PersistentVolumeClaims; ephemeral OS disks | Azure Disk `Premium_ZRS` / `StandardSSD_ZRS`, Azure Files ZRS; prefer PaaS for databases |
| Upgrade model | Drain from traffic, upgrade or rebuild, return ([picture 11](#stateless-clusters)) | In place, one AZ at a time, PDB-protected ([picture 12](#stateful-cluster)) |

**Isolation zones are kept in both cluster types.** Each stateless and the stateful cluster have the node pools,
subnets, Key Vaults and policies of zones `int-fi`, `int-se`, `ext-fi`, `ext-se` exactly as in pictures 2–7 – the data
in the stateful cluster is what needs the country separation most. The stateful cluster has no ingress at all: each
zone's applications are reachable only on their own internal load balancer IPs, and only from the same zone of the
stateless clusters.

**Traffic layer.** External zones are published through a zone-redundant Application Gateway WAF v2 (or Azure Front
Door Premium with Private Link origins); internal zones through an internal Application Gateway behind the hub Firewall.
The backend pool of every listener contains the Traefik internal load balancer of the zone in *every* stateless
cluster, always over HTTPS (port 443 only). A failed health probe removes a cluster automatically; the upgrade pipeline
removes it deliberately by setting its weight to 0.

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
of the environment. With the overlay CNI the stateless spokes have no pod subnets; their node subnets are sized for
the full load of the environment (N+1). Only the stateful spoke has pod subnets.

### Flows between frontend and backend

| Source | Destination | Port | Rule |
|---|---|---|---|
| Stateless zone *X* nodes (pod traffic SNATed by the overlay) | Stateful zone *X* application internal LBs | Application TLS port (e.g. TCP 443) | Same isolation zone only (`int-fi` → `int-fi`), via Firewall; TLS terminated by the application |
| Stateless zone *X* nodes (pod traffic SNATed by the overlay) | Zone *X* PaaS private endpoints | TCP 443, 1433, 5432, 5671 | Same isolation zone only, via Firewall; TLS enforced by the PaaS service |
| All nodes of the environment | ACR private endpoint | TCP 443 | Images, Helm charts, Flux OCI artifacts |
| Stateful cluster | Frontend networks | – | **Blocked** – the backend never initiates connections to the frontend |
| Stateful cluster | Internet | – | **Blocked** – no route, no outbound IP, Firewall deny-all |
| Stateful nodes / pods | Microsoft Entra ID (`AzureActiveDirectory` service tag) | TCP 443 | Only exception, needed for workload identity token exchange because Entra ID has no Private Link for sign-in – see open questions |

Azure Monitor is reached through an Azure Monitor Private Link Scope. AKS add-ons that need public Azure endpoints
(e.g. the Azure Policy add-on) are not enabled; policies are delivered by Flux as Gatekeeper constraints in every
cluster ([section 14](#14-policy-enforcement-with-gatekeeper)).

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
│   ├── base/                      # Gatekeeper + common constraints, Cilium policies, CSI, monitoring
│   ├── stateless/                 # Traefik + Gateways per zone, cert-manager, stateless constraints, HPA/KEDA
│   └── stateful/                  # storage classes (ZRS), operators, stateful constraints (no ingress)
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
- **Progressive delivery (optional)**: Flagger with Gateway API (`HTTPRoute` weights on the Traefik gateway) for
  canary releases with automatic rollback inside a stateless cluster.

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
4. wait until all Flux Kustomizations are `Ready`, run smoke and synthetic tests against the cluster's own Traefik gateways;
5. return traffic gradually (10 % → 50 % → 100 %) while watching error-rate and latency SLOs; on breach set the
   weight back to 0 and stop;
6. repeat for the next zonal cluster.

Node image / OS security updates use the same procedure or – because every app has ≥ 2 replicas and a PDB – the AKS
node OS auto-upgrade channel in maintenance windows staggered per cluster (`sl-az1` and `sl-az2` never on the same day).
Prerequisite for all of this is **N+1 capacity**: autoscaler limits, vCPU quota and node subnet size must allow one
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

## 13. Encryption in transit and TLS

![Encryption in transit](images/13-tls-encryption.svg)

Every hop is encrypted, but each cluster type does it in the way that costs the applications least.

### Stateless clusters: VNet encryption + TLS-only Traefik gateway

- **No service mesh, no mTLS, no TLS configuration in the applications.** Applications listen on plain HTTP inside the
  cluster. Traffic between pods on the same node never leaves the host; traffic between nodes is encrypted by
  **Azure Virtual Network encryption**, enabled on every stateless spoke VNet (and the hub peering).
  - Requires node VM sizes that support VNet encryption (accelerated networking); because the only enforcement mode is
    `AllowUnencrypted`, an unsupported VM size would silently send clear text. The allowed VM sizes are therefore
    enforced with Azure Policy on the node pools, and VNet encryption on the VNets.
  - VNet encryption covers VM-to-VM traffic in the VNet and peered VNets. Everything that leaves the stateless cluster
    (to Azure Firewall, the stateful cluster, PaaS, Internet) is TLS anyway – see below.
- **Traefik is the Gateway API implementation**, one instance per isolation zone in `<zone>-ingress` on the zone's node
  pool, behind an internal load balancer in `snet-<zone>-ilb`. Platform-owned `Gateway` per zone; application teams
  own only `HTTPRoute`s in their namespaces. `allowedRoutes` selects namespaces with `platform/zone=<zone>`, so a route
  can never attach to another zone's gateway.
- **Internal DNS names with Let's Encrypt certificates.** Each zone has its own DNS name space, e.g.
  `*.ext-fi.prd.apps.example.com`, resolved only by the Private DNS zone in the hub (split horizon: the name has no
  public A record). cert-manager obtains a **wildcard certificate per zone** from Let's Encrypt with the **DNS-01**
  challenge, writing only the `_acme-challenge` TXT record into a public Azure DNS zone with workload identity
  (optionally delegated via CNAME to a dedicated validation zone so cert-manager cannot change anything else). Because
  the certificate is publicly trusted, Application Gateway / Front Door validate the backend without uploading custom
  root certificates, and clients inside the corporate network need no private CA.
  - The parent domain must be a **registered public domain** – suffixes like `.internal`, `.local` or `.corp` cannot
    get Let's Encrypt certificates.
  - Certificates appear in public Certificate Transparency logs; the per-zone wildcard keeps application names out
    of them.
  - Egress `acme-v02.api.letsencrypt.org` is on the Firewall allow-list of the stateless spokes only.
- **No non-TLS traffic.** Traefik has only the `websecure` entry point on 443; port 80 is not exposed at all (no
  HTTP→HTTPS redirect listener either), the internal load balancer has only port 443, and the NSG on `snet-<zone>-ilb`
  allows only TCP 443. Gatekeeper rejects `Gateway` listeners with protocol `HTTP`, `HTTPRoute`s that do not attach to
  the HTTPS listener, hostnames outside the zone's domain, `Ingress` objects, and `LoadBalancer` / `NodePort` Services
  outside `<zone>-ingress`. Traefik adds HSTS to every response. The traffic layer listens on HTTPS only and
  re-encrypts to Traefik (end-to-end TLS).

### Stateful cluster: the application terminates TLS

- **No ingress controller and no Gateway API** – the CRDs are not installed and Gatekeeper rejects `Ingress`,
  `Gateway` and `HTTPRoute` objects. Fewer moving parts in the cluster that is hardest to upgrade.
- **Azure CNI (VNet-integrated)**: pod IPs are routable in the backend spoke, so NSGs, the Firewall and Cilium
  policies see real addresses.
- Each application is published with a `LoadBalancer` Service that must be internal
  (`service.beta.kubernetes.io/azure-load-balancer-internal: "true"`), placed in its zone's
  `snet-<zone>-ilb` (`…-internal-subnet` annotation) and use `externalTrafficPolicy: Local`; `NodePort` and public
  load balancers are rejected by Gatekeeper.
- **The application handles TLS itself** (TLS 1.2+), which is an onboarding requirement for the stateful cluster: it
  terminates TLS on its listener and reloads the certificate on rotation. Most products that end up here (databases,
  brokers, search engines) support this natively.
- The cluster cannot reach Let's Encrypt, so certificates are issued outside it – by the platform's certificate
  pipeline in the management network (same Let's Encrypt DNS-01 process, names like
  `<app>.int-fi.prd.data.example.com`) or by the enterprise CA – and stored in the zone's Key Vault as `<app>-tls`.
  The application reads it through the Secrets Store CSI driver, so the ABAC secret-name prefix of
  [picture 6](#6-workload-identity-first-key-vault-secrets-only-when-needed) also covers certificates.
- Clients in the stateless clusters connect with TLS and verify the name; plain-text ports are not allowed by the
  Firewall rules between frontend and backend.

## 14. Policy enforcement with Gatekeeper

**OPA Gatekeeper is the single policy engine.** It is installed by Flux from the environment's ACR (upstream Helm
chart, same version in every cluster, ≥ 3 replicas with a PDB so the webhook survives node drains), because the stateful
cluster cannot use the Azure Policy add-on and having one engine everywhere keeps the rules identical. The Azure Policy
add-on is not enabled in any cluster (it would install a second Gatekeeper). Azure Policy is still used for the Azure
resources themselves (cluster settings, allowed VM sizes, VNet encryption, private endpoints only).

- `ConstraintTemplate`s (Rego) and constraints live in `infrastructure/base` and the cluster-type folders and are
  tested in CI with `gator verify` before the Flux artifact is published.
- New constraints start with `enforcementAction: dryrun` (audit only) in dev, then become `deny` dev → acc → prd.
- Mutations (`Assign`, `AssignMetadata`) set defaults; constraints validate the result.

| Constraint | All clusters | Stateless | Stateful |
|---|---|---|---|
| Namespace has `platform/zone`; pod nodeSelector / toleration match it (mutation + validation) | ✔ | | |
| Images by digest from the environment's ACR only | ✔ | | |
| ServiceAccount used by application pods carries the workload identity client ID; no `imagePullSecrets` | ✔ | | |
| No `Opaque` / basic-auth / docker-config `Secret`s in application namespaces (Helm release and cert-manager TLS secrets allowed); no `secretObjects` in `SecretProviderClass` | ✔ | | |
| Requests set, probes set, no privileged / hostNetwork / hostPath for applications | ✔ | | |
| PDB required, replica and rollout guardrails of [section 11](#11-zero-downtime-application-upgrades) | ✔ | ≥ 2 replicas | ≥ 3 replicas, zone spread |
| Reject `PersistentVolumeClaim` | | ✔ | |
| Reject `Ingress`; only HTTPS `Gateway` listeners; `HTTPRoute` only to the zone's HTTPS listener and zone domain | | ✔ | |
| Reject `LoadBalancer` / `NodePort` Services outside `<zone>-ingress` | | ✔ | |
| Reject `Ingress`, `Gateway`, `HTTPRoute`; `LoadBalancer` only internal, in the zone's ILB subnet, `externalTrafficPolicy: Local`; no `NodePort` | | | ✔ |
| Namespace has `platform/stateful-exception` | | | ✔ |

---

## Open questions

- Single cluster with zones vs. one cluster per zone (or per country) – trade-off between operational cost and
  blast radius / hard network boundary.
- Is CoreDNS on the shared system pool acceptable, or should each zone run its own DNS (e.g. NodeLocal DNS)?
- Should external zones share one Application Gateway for Containers or keep one WAF per zone (current draft)?
- Key Vault ABAC is preview – acceptable for production, or fall back to vault per application until GA? (Affects only
  applications with a secret exception.)
- Which application stacks lack Entra ID support in their drivers/SDKs, and are they upgraded or given a secret
  exception?
- Two or three stateless clusters per environment? Two is the minimum, but then each must carry 100 % of the load and
  an AZ outage *during* an upgrade leaves no redundancy; three needs only 50 % headroom per cluster.
- "No Internet" for the stateful cluster: is the Entra ID (`AzureActiveDirectory` service tag) exception for workload
  identity acceptable, or must stateful workloads avoid Entra-authenticated access?
- Which workloads are expected to get a stateful-cluster exception? If none remain after the PaaS review, the
  stateful cluster could be left out of an environment entirely.
- Certificates for the stateful applications: Let's Encrypt via the central pipeline, or the enterprise CA (no CT
  log exposure, but clients must trust the private root)?
- DNS naming for the internal Let's Encrypt names (`<zone>.<env>.apps.example.com`) and who owns the public
  validation zone.
- Traffic layer: Application Gateway per environment, or Azure Front Door Premium for external zones (also enables a
  second region later)?
- Flux as AKS GitOps extension (Microsoft-managed upgrades) or upstream Flux (newer features, own lifecycle)?

## Editing the pictures

Sources are Mermaid files in [`diagrams/`](diagrams); rendered SVGs live in [`images/`](images).
After editing a source, regenerate with:

```sh
scripts/render.sh
```
