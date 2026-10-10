# 8. Cluster types: stateless and stateful

![Cluster topology](../images/08-cluster-topology.svg)

Every environment has two kinds of clusters. The split follows one rule: **a cluster that holds no data can be
taken out of traffic, upgraded or even rebuilt at any time; a cluster that holds data cannot, so it is made
zone-redundant and changed as rarely as possible.**

## Where does a workload run

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
the platform team, and the stateful cluster itself is only built when the first exception is approved
([optional](09-environments.md)); the exception is the label `platform/stateful-exception=<ticket>` on its namespace, required by a
policy. The exceptions are reviewed when new PaaS services become available. The fewer workloads the
stateful cluster runs, the smaller its blast radius and upgrade risk.

## Comparison

| | Stateless (`aks-<env>-sl-az<N>`) | Stateful (`aks-<env>-sf`) |
|---|---|---|
| Runs | Frontends, APIs, workers – anything that can be killed and recreated; state in Azure PaaS | Only approved exceptions: workloads that own data on disks (StatefulSets, operators) for which no PaaS service fits |
| Count per environment | One per availability zone: `sl-az1`, `sl-az2` mandatory, `sl-az3` optional (recommended for prd) | Zero or one – built only when the first approved workload needs it |
| Availability zones | All nodes of a cluster in its AZ (system pool `--zones <N>`, NAP `NodePool`s by zone requirement); the cluster is the unit of failure | Every isolation zone has one node pool per AZ (`intfiz1`, `intfiz2`, `intfiz3`, …); system pool spread over AZ 1–3 |
| Nodes | [Node auto provisioning](https://learn.microsoft.com/en-us/azure/aks/node-autoprovision): one Karpenter `NodePool` per isolation zone, VM size chosen per workload ([section 4](04-node-pools.md)) | Classic AKS node pools with a fixed VM size and node count |
| Network | Frontend spoke `vnet-<env>-sl-az<N>`, peered to the hub | Backend spoke `vnet-<env>-sf`, peered to the hub, together with the PaaS private endpoints |
| Internet | Egress only via Azure Firewall FQDN allow-list (outbound type `userDefinedRouting`); inbound only via the traffic layer | **None.** [Network isolated cluster](https://learn.microsoft.com/en-us/azure/aks/concepts-network-isolated) (outbound type `none`, bootstrap artifacts from the private ACR cache), no public IPs, UDR `0.0.0.0/0` → Firewall which denies all Internet for backend prefixes |
| CNI | [Azure CNI Overlay](https://learn.microsoft.com/en-us/azure/aks/concepts-network-azure-cni-overlay) powered by Cilium | Azure CNI (VNet-integrated, dynamic pod IP allocation) powered by Cilium |
| Advanced networking | ACNS with eBPF host routing and FQDN egress policies ([section 16](16-advanced-networking-and-fqdn-egress.md)) | Same |
| Incoming HTTP(S) | [Gateway API](https://gateway-api.sigs.k8s.io/) with Traefik as the implementation, one `Gateway` per isolation zone, HTTPS only; the Kubernetes Ingress API is not used | **No Gateway API implementation and no Ingress.** Applications are published with internal `LoadBalancer` Services (L4) |
| TLS | Terminated by Traefik with Let's Encrypt certificates for internal DNS names; applications serve plain HTTP inside the cluster | **Terminated by the application itself** – a hard onboarding requirement |
| Node-to-node encryption | [Azure Virtual Network encryption](https://learn.microsoft.com/en-us/azure/virtual-network/virtual-network-encryption-overview) – no service mesh, no mTLS | Application TLS (VNet encryption may be enabled as defence in depth but is not relied on) |
| Kubernetes version | Standard support, two speeds: `sl-az1` on the second latest GA minor (N-1), `sl-az2` (and `sl-az3`) one minor behind (N-2) ([update policy](12-zero-downtime-cluster-upgrades.md#update-policy)) | [Long Term Support](https://learn.microsoft.com/en-us/azure/aks/long-term-support) (`--tier premium --k8s-support-plan AKSLongTermSupport`): created on the second latest GA minor (N-1), then kept on that minor until 6 months before its LTS ends |
| Tier | Standard | Premium (required for LTS) |
| Scaling | ≥ 2 replicas per app, HPA / KEDA on load, NAP adds and removes nodes; **each cluster sized to carry 100 % of the load alone** (NAP `NodePool` limits) | ≥ 3 replicas per StatefulSet, one per AZ; **no autoscaling** – fixed node count per pool, sized when an exception is onboarded and changed as a planned IaC change |
| Storage | None – admission policy rejects PersistentVolumeClaims; ephemeral OS disks | Azure Disk `Premium_ZRS` / `StandardSSD_ZRS`, Azure Files ZRS, through per-zone StorageClasses encrypted with the zone's own key ([section 18](18-encryption-at-rest-and-customer-managed-keys.md)); prefer PaaS for databases |
| Upgrade model | Drain from traffic, upgrade or rebuild, return ([picture 11](12-zero-downtime-cluster-upgrades.md#stateless-clusters)) | In place, one AZ at a time, PDB-protected ([picture 12](12-zero-downtime-cluster-upgrades.md#stateful-cluster)) |

**Isolation zones are kept in both cluster types.** Each stateless and the stateful cluster have the nodes,
subnets, Key Vaults and policies of zones `int-fi`, `int-se`, `ext-fi`, `ext-se` exactly as in pictures 2–7 – the data
in the stateful cluster is what needs the country separation most. The stateful cluster has no Gateway API (and no Ingress) at all: each
zone's applications are reachable only on their own internal load balancer IPs, and only from the same zone of the
stateless clusters.

## Incoming traffic: from outside and from inside

Clients never connect to a pod or node directly, and the stateful cluster is never reached from outside the
platform. The two kinds of zones use the cells differently, because their availability requirements differ:

- **External zones (`ext-*`): every application runs in every cell, active-active.** A **traffic layer** (Azure
  Front Door, the cell router) outside the cells pins each client to one cell by its IP address and moves the
  clients of a failed or drained cell to another cell automatically.
- **Internal zones (`int-*`): every application runs in one cell, its home cell.** The application team chooses the
  cell; its DNS name points straight to the Traefik gateway of that cell, maintained by ExternalDNS. A **migration
  workflow** moves an application to another cell without downtime – on request, around cluster upgrades, and after
  a cell failure. A cell failure therefore costs the internal applications of that cell a short outage until they
  are migrated (recovery time target *TBD*, minutes) – accepted because internal applications have lower
  availability requirements than external ones. There is no WAF and no load balancer in front of internal zones.

| Source | Entry point | Path to the cells |
|---|---|---|
| Internet (external zones `ext-*`) | **Azure Front Door Premium** with a WAF policy per zone; public DNS name of the application → Front Door endpoint | Private Link origins: a Private Link Service on the Traefik internal load balancer of the zone in **every** cell. No public IP in any spoke |
| Corporate network (internal zones `int-*`) | **The zone's Traefik gateway in the application's home cell**: `<app>.int-fi.prd.example.com` resolves in the hub Private DNS to the Traefik internal load balancer IP of zone `int-fi` in that cell | On-premises → ExpressRoute/VPN → hub Firewall → Traefik internal load balancer of the zone in the home cell |
| Other Azure workloads (other spokes) | Same as the corporate network | Same as above; a Firewall rule per source |
| Applications in the same zone and cell | Kubernetes Service (`<app>.<zone>-<app>.svc`) | Stays inside the cell and its availability zone; never goes through the traffic layer or to another cell |
| Applications in the same internal zone, other cell | The application's DNS name, like any internal client | Hub Firewall → Traefik of the zone in the other cell (one Firewall rule per zone: zone prefix → zone prefix) |
| Applications in another zone | Not allowed (R5). If a business flow needs it, the caller is treated like any other client: it goes through the target zone's entry point and needs an explicit Firewall rule | – |

No component in front of a cell keeps state about the client: sessions and caches belong in Azure PaaS (e.g. Azure
Cache for Redis) or in the token, so a client can be moved to another cell at any time without losing anything.
What the cell choice controls is **which application version** a client sees while a release moves through the cells
one by one ([releases cell by cell](11-zero-downtime-application-upgrades.md#releases-cell-by-cell)).

### External zones: active-active with client-IP affinity

**The client's TLS session ends at Front Door**, not in a cell. Front Door terminates the client's TLS, runs the
WAF, opens its own TLS connection to the Traefik gateways and chooses the cell **per HTTP request**. All cells carry
external traffic all the time, and every client is mapped to one cell **by its IP address**, so it keeps using the
same cell across requests, TLS sessions and reconnects – also clients that do not support cookies (API clients,
mobile apps, other systems):

- **The affinity exists for consistent versions, not for state.** It makes sure that a client sees **one
  application version at a time** during a release.
- **Why not cookies:** cookie affinity (the only affinity Front Door offers built in) works only for clients that
  keep cookies, and some clients will not.
- **A failed or drained cell moves its clients** to another cell, and they come back when it returns. The mapping is
  deterministic, so every request of a client lands on the same cell again.
- **All cells always prove that they work.** A cluster that only receives traffic in a failure is a cold standby
  with cold caches and untested capacity. With active-active, a cell failure only affects the clients of that cell
  (half or a third).
- **Long-lived connections** (WebSockets, Server-Sent Events, gRPC streaming) stay on one cell for the life of the
  connection. Applications that use them must reconnect with back-off, because draining a cell closes them after the
  drain timeout.

How Front Door maps the client IP to a cell:

| | Front Door (external zones) |
|---|---|
| Mapping | Rule set per zone: the IPv4 and IPv6 address space is split into blocks (e.g. 16 per family), and each block is assigned to a cell with a rule *socket address in &lt;blocks&gt; → route configuration override: origin group of that cell*. Blocks are assigned by measured traffic so that the cells get similar load |
| Client IP used | *Socket address* (the address that connected to Front Door), not `X-Forwarded-For`, which a client could forge |
| Origins | One origin group per cell and zone: the cell's own origin at priority 1, the other cells at priorities 2 and 3 in the fixed order `az1` → `az2` → `az3`, so the clients of a failed cell all move to the same cell |
| Health probe | HTTPS `GET` to the zone's Traefik health route, which answers only when Traefik and its routes are ready |
| Take a cell out | Disable the cell's origin: its clients go to the next cell of their origin group |
| Return a cell | Enable the origin; in steps if wanted, by re-mapping the cell's blocks back a quarter at a time |

Limits of client-IP affinity, accepted in this design:

- **NAT**: all users behind one address (a carrier-grade NAT, a partner's proxy) land on the same cell, so the load
  is less even than with cookies. The cells are sized N+1 anyway; the block assignment is rebalanced from the access
  logs when needed (outside releases, because it moves clients).
- **Changing addresses**: a mobile client that switches networks may change cells. During a release it can then see
  the other version, which the [compatibility rule](11-zero-downtime-application-upgrades.md) covers.

**Real client IP**: the cells see Front Door's addresses; the client IP is in `X-Forwarded-For`, which Traefik
accepts only from the Private Link Service's NAT IPs (`forwardedHeaders.trustedIPs`).

Every external zone's Traefik gateway also answers to a **per-cell test host name** (e.g.
`*.sl-az1.ext-fi.prd.example.com`): a Front Door route to the cell's origin group whose WAF policy admits only the
pipeline's egress IPs. The release and upgrade pipelines run their smoke and synthetic tests through the real WAF and
TLS path before the cell gets user traffic ([releases](11-zero-downtime-application-upgrades.md#releases-cell-by-cell), [section 12](12-zero-downtime-cluster-upgrades.md#stateless-clusters)).

Front Door is a global service that reaches the cells through Private Link: the Traefik `Service` in `<zone>-gateway`
creates the Private Link Service itself (`service.beta.kubernetes.io/azure-pls-create: "true"`), and the NSG of
`snet-ext-<country>-ilb` allows TCP 443 only from the Private Link Service's NAT IPs. This traffic does not pass the hub
Firewall; the Front Door WAF and Traefik are its controls.

### Internal zones: one home cell per application, moved by migration

**Placement.** Every internal application has exactly one **home cell** per environment, chosen by its team in Git
(`apps/<app>/stateless/<env>/placement.yaml`, e.g. `cell: sl-az2`); the default is the slow-speed cell `sl-az2`,
which runs the more proven Kubernetes version ([update policy](12-zero-downtime-cluster-upgrades.md#update-policy)).
Placement is environment state, not part of the release train: CI renders it into a separate signed artifact
`placement:<git-sha>`, which every cell follows through its own Flux Kustomization (tag `<env>-placement`,
interval 1 min). It creates the application's Flux Kustomization only in its home cell – and during a migration also
in the target cell; the application's manifests themselves still come from the cell's fleet tag.

**DNS by ExternalDNS.** Each internal zone has a Private DNS zone in the hub (`int-fi.prd.example.com`, linked to the
hub VNet and resolved from on-premises through the DNS forwarders). Every cell runs **ExternalDNS** in the platform
namespace `infra-dns`, with:

- provider `azure-private-dns`, a workload identity with *Private DNS Zone Contributor* on the internal zones'
  Private DNS zones only, and `management.azure.com` on the Firewall allow-list;
- source `gateway-httproute`: the A record of each hostname of an `HTTPRoute` points to the address of the zone's
  Traefik `Gateway` in that cell – a **static IP** per zone and cell, set on the Traefik internal load balancer
  (`service.beta.kubernetes.io/azure-load-balancer-ipv4`) and kept in `cluster-vars`;
- annotation filter `platform/dns-publish=true`: only the cell that serves the application publishes it. The
  placement artifact sets the annotation (through Flux variable substitution), so exactly one cell publishes each
  name, and Azure Policy rejects the annotation in application manifests;
- one shared `txt-owner-id` per environment and policy `upsert-only`, so the target cell of a migration can take
  over a record from the source cell – also when the source cell is gone – and no cell ever deletes a record
  another cell has just written. Records of removed applications are deleted by the decommissioning pipeline;
- record TTL 60 s, sync interval 1 min.

**Migration workflow** – a pipeline in the runbooks repository; the same steps serve every reason to move:

1. **Deploy to the target**: the placement adds the target cell without `platform/dns-publish`; Flux deploys the
   application there (NAP adds nodes if needed). Wait until its Kustomization is `Ready`.
2. **Test**: smoke tests against the target cell's Traefik IP with the application's real host name
   (`curl --resolve`), over the real TLS path.
3. **Switch DNS**: the placement moves `platform/dns-publish` to the target cell. Its ExternalDNS overwrites the A
   record within a minute.
4. **Drain the source**: wait for the TTL and until the source cell's Traefik sees no more requests for the
   application (or a maximum, e.g. 15 min, for clients that cache DNS too long); long-lived connections are closed
   and reconnect to the target.
5. **Remove from the source**: the placement drops the source cell; Flux prunes the application there.

Until step 5, the migration is rolled back by moving `platform/dns-publish` back. Planned migrations are
zero-downtime. Teams start one by a pull request that changes their `placement.yaml`.

**Cell failure.** An alert on the cell's health (Traefik health routes probed by synthetic monitoring, AKS and VM
health) dispatches the **failover**: the migration workflow for all internal applications of the failed cell, with
step 4 skipped and step 5 deferred until the cell is back (a safe action,
[section 15](15-ai-driven-day-2-operations.md#safe-actions-without-a-pull-request)). Their recovery time is alert +
Flux reconcile + node provisioning and pod start in the target + ExternalDNS sync + TTL. The failed-over
applications stay in their new cell; the team or the platform moves them back by a planned migration.

**Consequences:**

- **TLS ends at Traefik.** Internal clients connect to the Traefik gateway directly with the zone's certificate
  ([section 13](13-encryption-in-transit-and-tls.md)); there is no WAF in front of internal zones.
- **Real client IP**: Traefik sees it directly, because its `Service` uses `externalTrafficPolicy: Local` and the hub
  Firewall allows the flow with network rules (no SNAT to private destinations).
- **One version at a time.** An internal application runs in one cell, so its clients see one version, apart from
  the few minutes of a rolling update, which the [compatibility rule](11-zero-downtime-application-upgrades.md)
  covers anyway.
- **Capacity**: every cell must still be able to take all internal applications of the other cell(s) – for upgrades
  and failures – so the N+1 sizing does not change. The NAP `NodePool` limits are the same in every cell.
- **Firewall**: corporate network and the pipeline agents → `snet-int-<country>-ilb` of every cell on TCP 443, with
  zone prefixes, so a migration never needs a Firewall change.

## VNets and address plan

**Recommendation: one spoke VNet per cluster, with one address space per isolation zone.** The prefixes are
planned **per zone, not per cluster**, so that one prefix still describes a whole zone across all clusters of an
environment.

Why not one common VNet?

| | One VNet per cluster (recommended) | One VNet per environment | One frontend VNet for all stateless clusters + backend VNet |
|---|---|---|---|
| Frontend/backend separation (R9) | Separate VNets, only reachable through the hub Firewall | Lost – the Internet-less backend shares a VNet with the frontend, separated only by NSG/UDR | Kept |
| Change one cluster at a time (R12) | Yes – a VNet change (address space, DNS servers, VNet encryption, peering) affects one cluster, and a stateless cluster can be rebuilt with a fresh VNet | No – every VNet change hits all clusters at once | No for the stateless clusters – a VNet change hits all of them at once |
| VNet settings per cluster type | VNet encryption on the stateless VNets only, other DNS/egress settings for the backend | One setting for all | Yes |
| One prefix per zone | Yes – from the address plan below | Yes | Yes |
| Extra cost | 3–4 hub peerings per environment; the address space of a new zone is added in each cluster VNet (an IaC loop) | – | – |

The usual reason to share a VNet – one summarisable prefix per zone – is achieved by the address plan instead, so
the separate VNets cost almost nothing. The only real cost is that each new zone is added to 3–4 VNets instead of 1.

**Address plan (example).** Every environment gets a `/12`, every country a `/16` of it, and every isolation zone
a `/17` (internal first half, external second half). Inside a zone's `/17` the frontend (stateless clusters) uses the first `/18` and the stateful cluster the second `/18`, one `/20` each. That `/20` is added as an address space
to the cluster's VNet, and inside it the subnet layout of [picture 2](02-network-layout.md) is reused. The platform
`/16` holds the control plane zone of every cluster in the same way.

| Prefix | dev `10.16.0.0/12` | acc `10.32.0.0/12` | prd `10.48.0.0/12` |
|---|---|---|---|
| Platform (control plane zones) | `10.16.0.0/16` | `10.32.0.0/16` | `10.48.0.0/16` |
| Country `fi` | `10.17.0.0/16` | `10.33.0.0/16` | `10.49.0.0/16` |
| Country `se` | `10.18.0.0/16` | `10.34.0.0/16` | `10.50.0.0/16` |
| Next country | `10.19.0.0/16` | `10.35.0.0/16` | `10.51.0.0/16` |

Layout of one zone, prd `int-fi` `10.49.0.0/17` (`ext-fi` is the same from `10.49.128.0/17`):

| `/20` | Use | Address space of VNet |
|---|---|---|
| `10.49.0.0/20` | `int-fi` in `sl-az1` | `vnet-prd-sl-az1` |
| `10.49.16.0/20` | `int-fi` in `sl-az2` | `vnet-prd-sl-az2` |
| `10.49.32.0/20` | `int-fi` in `sl-az3` (optional) | `vnet-prd-sl-az3` |
| `10.49.48.0/20` | Reserve (e.g. a fourth cell or a side-by-side rebuild) | – |
| `10.49.64.0/20` | `int-fi` in the stateful cluster | `vnet-prd-sf` |
| `10.49.80.0/20` – `10.49.112.0/20` | Reserve: more pod IPs for the stateful cluster (added as another address space) | `vnet-prd-sf` |

A stateless cluster that is rebuilt with a fresh VNet reuses its own `/20`s: it is drained first, so the old cluster
and VNet are deleted before the new ones are created (the other clusters carry the load, N+1). In dev and acc, which
have no `sl-az3`, that slot can host a side-by-side rebuild instead.

So `vnet-prd-sl-az1` has the address spaces `10.48.0.0/20` (control plane), `10.49.0.0/20` (`int-fi`),
`10.49.128.0/20` (`ext-fi`), `10.50.0.0/20` (`int-se`) and `10.50.128.0/20` (`ext-se`). The prefixes summarise in
the way the rules are written:

| Rule scope | prd prefix |
|---|---|
| Everything in the environment | `10.48.0.0/12` |
| Country `fi` (both zones) | `10.49.0.0/16` |
| Zone `int-fi`, all clusters | `10.49.0.0/17` |
| Zone `int-fi`, frontend (cells) | `10.49.0.0/18` |
| Zone `int-fi`, stateful cluster (backend) | `10.49.64.0/18` |

The rule "stateless zone *X* → stateful zone *X*" is therefore one Firewall rule per zone (`10.49.0.0/18 →
10.49.64.0/18`), and it does not change when a stateless cluster is added or rebuilt. The stateful `/18` is reserved even
while an environment has no stateful cluster. The `/20` per zone and
cluster is generous for the stateless clusters (nodes only); it is sized for the stateful cluster's pod subnets.
If the corporate network cannot spare three `/12`s, the same structure works one level smaller (`/17` per
country). The AKS service CIDR and the overlay pod CIDR of the stateless clusters must stay outside all of these
prefixes and outside the on-premises ranges.

## Adding a country online

A new country is two new zones. It is added cluster by cluster in the order
dev → acc → prd, and the existing zones only get new routes and Firewall rules:

1. **Allocate** the country's next `/16` per environment from the address plan (kept in IaC, or in an Azure
   Virtual Network Manager IP address pool).
2. **Address spaces:** add the zones' `/20`s to each cluster VNet and sync the hub peering
   (`az network vnet peering sync`). Both are online operations; the new prefixes are then advertised to
   on-premises through the hub gateway automatically.
3. **Subnets, NSGs, route tables** for the new zones; add a route for each new address space to the existing zones'
   route tables (and the reverse). Give the cluster identity *Network Contributor* on the new subnets.
4. **Firewall and on-premises:** new rules for the new zone prefixes (IP groups); the existing rules do not change.
5. **Environment module:** zone Key Vaults, private endpoints, managed identities, certificate in the platform Key Vault;
   in the stateful cluster also the zones' persistent volume keys, disk encryption sets, storage accounts and
   StorageClasses ([section 18](18-encryption-at-rest-and-customer-managed-keys.md)).
6. **Nodes:** in the stateless clusters, NAP `NodePool`s and `AKSNodeClass`es `intxx` / `extxx` for the new subnets
   (Flux, with the new subnet IDs in `cluster-vars`); in the stateful cluster, node pools `intxxz1`–`z3` /
   `extxxz1`–`z3` (`--vnet-subnet-id`, `--pod-subnet-id`, fixed node count). Neither restarts existing nodes.
7. **Policies and Git:** the zone's Azure Policy mutation and validation, Traefik gateway and namespaces through
   Flux and the stateful pipeline.
8. **Entry points:** the internal zone's Private DNS zone in the hub (with ExternalDNS's role on it) and a static
   Traefik IP per cell in `cluster-vars`; the external zone's WAF policy, origin groups, Private Link origins and IP-block rule set in Front Door; approve the Private Link connections. Existing zones' entry
   points do not change.

In the backend spoke each isolation zone's `snet-<zone>-pe` also holds the private endpoints of that zone's PaaS
services (SQL, Storage, Service Bus, …); a shared `snet-shared-pe` holds the ACR private endpoint used by all clusters
of the environment. With the overlay CNI the stateless spokes have no pod subnets; their node subnets are sized for
the full load of the environment (N+1). Only the stateful spoke has pod subnets.

## Flows between frontend and backend

| Source | Destination | Port | Rule |
|---|---|---|---|
| Stateless zone *X* nodes (pod traffic SNATed by the overlay) | Stateful zone *X* application internal LBs | Application TLS port (e.g. TCP 443) | Same isolation zone only (`int-fi` → `int-fi`), via Firewall; TLS terminated by the application |
| Stateless zone *X* nodes (pod traffic SNATed by the overlay) | Zone *X* PaaS private endpoints | TCP 443, 1433, 5432, 5671 | Same isolation zone only, via Firewall; TLS enforced by the PaaS service |
| All nodes of the environment | ACR private endpoint | TCP 443 | Images, Helm charts, Flux OCI artifacts |
| Stateful cluster | Frontend networks | – | **Blocked** – the backend never initiates connections to the frontend |
| Stateful cluster | Internet | – | **Blocked** – no route, no outbound IP, Firewall deny-all |
| Management VNet pipeline agents | Stateful API server (Private Link) | TCP 443 | Deployments to the stateful cluster ([section 10](10-keeping-clusters-in-sync.md)) |
| Stateful nodes / pods | Microsoft Entra ID (`AzureActiveDirectory` service tag) | TCP 443 | Exception, needed for workload identity token exchange because Entra ID has no Private Link for sign-in – see open questions |
| Stateful nodes (Azure Policy add-on) | `data.policy.core.windows.net`, `store.policy.core.windows.net`, `dc.services.visualstudio.com` | TCP 443 | Exception, Firewall application rules for these FQDNs only; the add-on has no Private Link ([section 14](14-policy-enforcement.md)) |

Azure Monitor is reached through an Azure Monitor Private Link Scope. Other AKS add-ons that need public Azure
endpoints are not enabled in the stateful cluster; the Azure Policy add-on is the one accepted exception ([section 14](14-policy-enforcement.md)).

---

[Back to contents](../README.md) · Previous: [7. Application multi-tenancy inside a zone](07-application-multi-tenancy.md) · Next: [9. Environments (six to nine clusters)](09-environments.md)
