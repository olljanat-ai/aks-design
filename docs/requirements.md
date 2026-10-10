# Requirements

| # | Requirement | How the design meets it |
|---|---|---|
| R1 | Control plane in a dedicated network | Private, VNet-integrated API server in its own delegated subnet; admin access only via Private Link from a separate management VNet ([picture 3](03-control-plane.md)) |
| R2 | Internal and external workloads isolated | Separate isolation zones `int-*` and `ext-*` |
| R3 | Workloads of different countries isolated | Separate isolation zones per country (`*-fi`, `*-se`, …) |
| R4 | Isolation = Key Vault + network + node pool per type | Every zone has its own Key Vault, subnets (NSG + route table) and nodes – a node auto provisioning `NodePool` in the stateless clusters, AKS node pools in the stateful cluster ([section 4](04-node-pools.md)); certificates are the one shared exception, kept in the per-environment platform Key Vault with a role assignment per certificate |
| R5 | Only connectivity mandatory for Kubernetes allowed between zones | Deny-by-default on three layers: NSG, Azure Firewall, Cilium network policy ([picture 5](05-allowed-and-blocked-flows.md)) |
| R6 | Applications isolated in namespaces + network policies | Namespace per application, default-deny policies ([picture 7](07-application-multi-tenancy.md)); egress out of the cluster only through the application's FQDN policy (R20) |
| R7 | Key Vault multi-tenancy with [Azure RBAC + ABAC](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-abac) | Per-application secret reader identity, usable only by External Secrets Operator, with secret-name-prefix conditions ([picture 6](06-workload-identity-and-secrets.md)) |
| R7a | Workload identities wherever possible, secrets only when needed | Per-application workload identity with Entra ID auth to all Azure services, local auth disabled by Azure Policy; Key Vault secrets only for targets without Entra ID ([section 6](06-workload-identity-and-secrets.md)) |
| R7b | Applications never read Key Vault directly; External Secrets Operator is mandatory for them | One ESO controller per zone reads Key Vault on behalf of the applications; platform components (Traefik, Flux, monitoring) may use Key Vault directly with their own workload identity and narrow roles; the Secrets Store CSI driver add-on is disabled; application identities have no Key Vault role, application pods cannot use the reader identity or reach a vault, and only ESO may write Secrets in application namespaces ([section 6](06-workload-identity-and-secrets.md#delivered-only-by-external-secrets-operator)) |
| R8 | Two cluster types: stateless and stateful | Stateless clusters in the frontend network, one optional stateful cluster in the backend network, built only when a workload requires it ([picture 8](08-cluster-types-stateless-and-stateful.md)) |
| R8a | Stateful cluster is the last option | Placement order stateless cluster → Azure PaaS → stateful cluster; the stateful cluster needs a documented exception ([where does a workload run](08-cluster-types-stateless-and-stateful.md#where-does-a-workload-run)) |
| R9 | Stateful cluster exists at most once, in the backend network with the Azure PaaS services, no Internet connectivity at all | Backend spoke with PaaS private endpoints; network isolated AKS (outbound type `none`), no public IPs, Firewall deny-all for backend prefixes |
| R9a | Stateful cluster: VNet-integrated CNI, no Gateway API implementation (and no Ingress), applications handle TLS | Azure CNI (VNet, dynamic pod IP allocation) powered by Cilium with ACNS; applications are published with internal `LoadBalancer` Services and terminate TLS themselves ([section 13](13-encryption-in-transit-and-tls.md)) |
| R9b | Stateless clusters: overlay CNI, no service mesh / mTLS / application TLS, TLS-only Gateway API (no Kubernetes Ingress) | Azure CNI Overlay powered by Cilium with ACNS and eBPF host routing, Azure Virtual Network encryption between nodes, Traefik as Gateway API implementation with Let's Encrypt certificates for internal DNS names, distributed through Key Vault, and HTTPS-only listeners ([section 13](13-encryption-in-transit-and-tls.md)) |
| R10 | Stateful cluster spread over availability zones and running AKS LTS | Fixed-size node pools per AZ 1/2/3 (no autoscaling), ZRS storage, Premium tier with Long Term Support |
| R11 | Stateless: separate cluster per availability zone (at least two), ≥ 2 copies of every application, scaled on load | `sl-az1`, `sl-az2` (+ optional `sl-az3`) behind a zone-redundant traffic layer; policy-enforced replicas ≥ 2, HPA/KEDA, [node auto provisioning](https://learn.microsoft.com/en-us/azure/aks/node-autoprovision) (NAP) |
| R12 | Fully automated zero-downtime upgrades of applications and clusters | Policy-enforced rollout guardrails, releases one cell at a time with cell affinity, pipeline-driven stateful rollout, drain-and-upgrade per stateless cluster, PDB-guarded per-AZ upgrade of the stateful cluster ([section 11](11-zero-downtime-application-upgrades.md), [section 12](12-zero-downtime-cluster-upgrades.md)) |
| R12a | Update policy: stateful cluster only when absolutely necessary, stateless clusters at two speeds | Stateful: created on the second latest GA minor (N-1), then kept on that minor with LTS until 6 months before its end of LTS support, existing nodes patched instead of replaced where possible. Stateless: `sl-az1` on the second latest minor with patches after 1 week per environment, `sl-az2` one minor behind with 1 month per environment ([update policy](12-zero-downtime-cluster-upgrades.md#update-policy)) |
| R13 | dev, acc and prd environments kept in sync | 3 × 2 = 6 clusters (3 × 3 = 9 with the stateful cluster) from the same IaC modules, all in-cluster state from one Git repository: FluxCD in the stateless clusters, CI/CD pipeline in the stateful cluster ([picture 9](09-environments.md), [picture 10](10-keeping-clusters-in-sync.md)) |
| R14 | One policy engine | Azure Policy add-on for AKS in every cluster, assigned per environment subscription; the same Azure Policy also governs the Azure resources ([section 14](14-policy-enforcement.md)) |
| R15 | Certificates distributed through Key Vault, shared by all clusters | One shared **platform Key Vault per environment** (`kv-<env>-platform`) holds all certificates of that environment; a renewal job per environment issues one certificate per zone into it, and External Secrets Operator in every cluster of the environment reads it with plain Azure RBAC scoped to the individual certificate ([section 13](13-encryption-in-transit-and-tls.md#certificates-issued-centrally-distributed-through-the-platform-key-vault)) |
| R16 | Countries can be added online | One address space per zone in every cluster VNet, taken from a per-country prefix; a new country adds address spaces, subnets and NAP `NodePool`s / node pools; existing zones only get new routes and Firewall rules ([VNets and address plan](08-cluster-types-stateless-and-stateful.md#vnets-and-address-plan)) |
| R17 | Cost-optimised compute: applications choose amd64 or arm64 and on-demand or spot nodes, the platform supports all of them | Stateless clusters: pod labels `platform/arch` (`amd64` / `arm64` / `multi`) and `platform/capacity` (`on-demand` / `spot`), turned into node selection by Azure Policy mutation; per zone an on-demand and a tainted spot NAP `NodePool` with amd64 + arm64 SKUs and fallback to on-demand; defaults amd64 on-demand; stateful cluster on-demand amd64 only ([section 4](04-node-pools.md#cpu-architecture-and-spot-chosen-by-the-application)) |
| R18 | Day 2 operations driven by AI agents, also in prd, but only through GitOps / IaC pull requests within human-defined guardrails | Agents with read-only identities per agent and environment open pull requests; a merge gate owned by humans computes a risk tier from the plan and requires checks and 0–2 human approvals; only the existing deployment identities write; runtime guardrails unchanged ([section 15](15-ai-driven-day-2-operations.md)) |
| R19 | AKS advanced networking with eBPF host routing | [Advanced Container Networking Services](https://learn.microsoft.com/en-us/azure/aks/advanced-container-networking-services-overview) (`--enable-acns`) in every cluster; eBPF host routing (`--acns-datapath-acceleration-mode BpfVeth`) on Azure Linux 3.0 nodes in every cluster from day one (the stateful cluster is created on N-1, so ≥ 1.33); no host iptables, no Static Egress Gateway ([section 16](16-advanced-networking-and-fqdn-egress.md)) |
| R20 | Applications must define an FQDN-based egress policy for any traffic exiting the cluster | Platform baseline puts every application pod in Cilium default-deny egress; the application's own `CiliumNetworkPolicy` `egress` lists every external destination with `toFQDNs` + ports and a matching DNS rule; Azure Policy rejects CIDR / entity egress, broad wildcards and custom DNS; CI checks the names against the zone's Firewall allow-list ([section 16](16-advanced-networking-and-fqdn-egress.md)) |
| R21 | Data at rest encrypted with customer-managed keys: own key for each control plane and each node pool, stored in the platform Key Vault | Keys in `kv-<env>-platform`: per cluster a KMS etcd key (control plane) and an OS-disk key (disk encryption set for all its nodes – AKS supports only one per cluster, not per node pool); in the stateful cluster also one key per isolation zone for its persistent volumes; encryption at host on every node ([section 18](18-encryption-at-rest-and-customer-managed-keys.md)) |

**Isolation zone** = one *type* = one combination of exposure × country:

| Zone | Exposure | Country | NAP `NodePool` (stateless) | Node pools (stateful) | Key Vault (one per environment) | Subnets |
|---|---|---|---|---|---|---|
| `int-fi` | internal | FI | `intfi`, `intfispot` | `intfiz1`–`z3` | `kv-<env>-int-fi` | `snet-int-fi-*` |
| `int-se` | internal | SE | `intse`, `intsespot` | `intsez1`–`z3` | `kv-<env>-int-se` | `snet-int-se-*` |
| `ext-fi` | external | FI | `extfi`, `extfispot` | `extfiz1`–`z3` | `kv-<env>-ext-fi` | `snet-ext-fi-*` |
| `ext-se` | external | SE | `extse`, `extsespot` | `extsez1`–`z3` | `kv-<env>-ext-se` | `snet-ext-se-*` |

Adding a country adds two zones (`int-xx`, `ext-xx`) following the same pattern, online ([adding a country](08-cluster-types-stateless-and-stateful.md#adding-a-country-online)).

Next to the zone vaults, every environment has exactly **one shared platform Key Vault**:

| Key Vault | Exists | Holds | Access |
|---|---|---|---|
| `kv-<env>-<zone>` | Once per zone and environment | Application secrets (`<app>-<secret>`) of that zone | Read only by the zone's External Secrets Operator, with RBAC + ABAC per application reader identity ([section 6](06-workload-identity-and-secrets.md)) |
| `kv-<env>-platform` | Once per environment (`kv-dev-platform`, `kv-acc-platform`, `kv-prd-platform`) | The environment's TLS certificates of all zones (`cert-<zone>-…`), the renewal job's ACME account key and the customer-managed keys of all clusters (`key-<cluster>-kms`, `key-<cluster>-disk`, `key-sf-pv-<zone>`) | Plain Azure RBAC, role assignments scoped to single certificates and keys ([section 13](13-encryption-in-transit-and-tls.md#certificates-issued-centrally-distributed-through-the-platform-key-vault), [section 18](18-encryption-at-rest-and-customer-managed-keys.md)) |

Colour legend in all pictures: grey = control plane / platform / PaaS, blue = internal, orange = external,
purple = hub / management, green = identity, teal = stateless cluster (cell), pink = stateful cluster,
yellow = notes / policy, red dashed = blocked.

## Cells and bulkheads

The design uses two isolation patterns at two levels, and this document uses their names:

| Term | In this design | Pattern | Limits the impact of |
|---|---|---|---|
| **Cell** | One stateless cluster (`aks-<env>-sl-az<N>`) with its own VNet, all of it in one availability zone, running a full copy of every application of every isolation zone | [Cell-based architecture](https://docs.aws.amazon.com/solutions/cell-based-architecture-for-amazon-eks/) | An availability zone outage, a cluster failure, a bad release or a bad cluster upgrade: changes reach one cell at a time |
| **Cell router** | The traffic layer: Front Door for external zones, NGINXaaS for internal zones; maps each client IP to a cell ([incoming traffic](08-cluster-types-stateless-and-stateful.md#incoming-traffic-from-outside-and-from-inside)) | Cell-based architecture | – (zone-redundant, outside the cells) |
| **Isolation zone** | One exposure × country (`int-fi`, `ext-se`, …) with its own address space, subnets, nodes, Key Vault and policies, present in every cell | [Bulkhead](https://learn.microsoft.com/en-us/azure/architecture/patterns/bulkhead) | A noisy, failing or compromised workload of one zone: it cannot use another zone's nodes, network or secrets |
| **Shared tier** | Hub (Firewall, gateways, DNS), Azure PaaS, ACR, Key Vaults, the optional stateful cluster | – | Not split into cells; zone-redundant instead, and changed with extra care |

Two differences from the classic cell-based architecture:

- **Every cell serves every user.** The cells are full replicas, aligned with availability zones (as in the AWS
  guidance for EKS, one cluster per availability zone); users are not partitioned between cells by tenant or
  customer. The cell router only pins a user's *session* to a cell ([cell affinity](08-cluster-types-stateless-and-stateful.md#incoming-traffic-from-outside-and-from-inside)).
  Partitioning by country would be possible later, because the isolation zones already are the natural partition key.
- **The data is shared.** All cells use the same PaaS services and stateful cluster, so a cell isolates compute and
  releases, not data. Data changes therefore follow the [compatibility rule](11-zero-downtime-application-upgrades.md).

In this document "zone" means an isolation zone, unless it says availability zone (AZ) or zone-redundant.

---

[Back to contents](../README.md) · Next: [1. Overview](01-overview.md)
