# Open questions

- Single cluster with zones vs. one cluster per zone (or per country) – trade-off between operational cost and
  blast radius / hard network boundary.
- Can the corporate IP plan reserve a `/12` per environment for the platform (or a `/17` per country if not), and
  is the platform the owner of these prefixes in the central IPAM?
- Is CoreDNS on the shared system pool acceptable, or should each zone run its own DNS (e.g. NodeLocal DNS)?
- One Front Door profile per environment with a WAF policy per external zone (current draft), or a profile per zone?
- Release cadence: is one fleet release train per environment and day (or a few) fast enough, given that each cell
  costs a drain, rollout, tests and a return ramp? Which applications need a faster path?
- Client-IP affinity: how much traffic comes from large NATs (corporate proxies, carrier-grade NAT) or from clients
  that change addresses? This decides how even the load is and how many clients can meet both versions in a release.
- Internal entry point: is F5 NGINXaaS (an Azure partner service) acceptable, and is NGINX App Protect WAF generally
  available for it in our region? Alternatives: self-managed NGINX/Envoy with consistent hashing on VM scale sets, or
  Application Gateway with cookie affinity, accepting that cookie-less internal clients see both versions.
- Node auto provisioning in the stateless clusters: confirm that NAP with custom subnets per `NodePool` is supported
  (and generally available) in our region together with a private cluster, API Server VNet Integration, outbound type
  `userDefinedRouting` and the Azure Policy add-on. Fallback: classic node pools per zone with the cluster autoscaler.
- arm64 and spot in the stateless clusters: confirm that NAP offers spot and arm64 SKUs together with custom subnets
  per `NodePool`, which arm64 families (Dpsv6/Epsv6, Cobalt 100) support Azure Virtual Network encryption in our
  region, and that the Azure Policy mutations can match on pod labels (`platform/arch`, `platform/capacity`). If an
  architecture has no VNet-encryption-capable SKU, it cannot be offered. How large a share of a zone may run on spot
  (spot `NodePool` limits), and is spot allowed in prd for all zones?
- In-place OS patching of the stateful cluster (node OS channel `Unmanaged`) needs the OS package repositories, but
  the cluster is network isolated: is a private package mirror in the backend network acceptable, and is the channel
  supported for network isolated clusters? If not, the fallback is node OS channel `SecurityPatch` (security-only node
  images, which replaces nodes) inside the maintenance window.
- Update speeds: does `sl-az2` running the oldest supported minor leave enough time for its 1-month steps in every
  AKS release cycle, and should `sl-az3` follow the slow speed (current draft) or the fast one? With NAP, confirm that
  nodes created during scale-out use the pinned node image, not the newest one.
- Key Vault ABAC is preview – acceptable for production, or fall back to vault per application until GA? (Affects only
  applications with a secret exception.)
- Which application stacks lack Entra ID support in their drivers/SDKs, and are they upgraded or given a secret
  exception?
- Two or three stateless clusters per environment? Two is the minimum, but then each must carry 100 % of the load and
  an AZ outage *during* an upgrade leaves no redundancy; three needs only 50 % headroom per cluster.
- "No Internet" for the stateful cluster: is the Entra ID (`AzureActiveDirectory` service tag) exception for workload
  identity acceptable, or must stateful workloads avoid Entra-authenticated access?
- Which workloads are expected to get a stateful-cluster exception, and when? The stateful cluster is built only when
  the first one is approved; is it then built in all three environments at once (recommended, to keep the topology
  identical)?
- Is one wildcard certificate per zone and environment acceptable, or do some applications need their own
  certificate (own key)?
- One platform Key Vault per environment shared by all zones (current draft), or one certificate vault per zone and
  environment if a separate vault per country is a hard requirement for keys too?
- DNS naming for the internal Let's Encrypt names (`<zone>.<env>.example.com`) and who owns the public
  validation zone.
- "No Internet" for the stateful cluster: are the Azure Policy add-on FQDNs acceptable as a second exception next to
  Entra ID?

---

[Back to contents](../README.md) · Previous: [14. Policy enforcement with the Azure Policy add-on](14-policy-enforcement.md) · Next: [Editing the pictures](editing-the-pictures.md)
