# 9. Environments (six to nine clusters)

![Environments](../images/09-environments.svg)

| Environment | Subscription | Stateless | Stateful | Clusters |
|---|---|---|---|---|
| dev | `sub-aks-dev` | `aks-dev-sl-az1`, `aks-dev-sl-az2` | (`aks-dev-sf`) | 2 (3) |
| acc | `sub-aks-acc` | `aks-acc-sl-az1`, `aks-acc-sl-az2` | (`aks-acc-sf`) | 2 (3) |
| prd | `sub-aks-prd` | `aks-prd-sl-az1`, `aks-prd-sl-az2` (+ `aks-prd-sl-az3`) | (`aks-prd-sf`) | 2–3 (3–4) |

**Minimum 6 clusters**, 9 with the stateful cluster; one more per environment that gets a third stateless cluster.
dev and acc must have the *same topology* as prd (at least two stateless clusters, and a three-AZ stateful cluster if
prd has one), otherwise the upgrade procedures cannot be rehearsed there; they can use lower NAP `NodePool` limits and
smaller stateful node pools.

> **The stateful cluster is optional.** It is not built until the first workload has an approved stateful-cluster
> exception ([where does a workload run](08-cluster-types-stateless-and-stateful.md#where-does-a-workload-run)); until then every environment runs only the stateless
> clusters and Azure PaaS. The backend network itself exists from day one, because it holds the PaaS private endpoints
> and the ACR. Everything the stateful cluster needs later is already prepared, so adding it is an ordinary IaC change
> with no impact on the running platform: its `/18` per zone is reserved in the address plan, the stateful cluster
> module and pipeline are kept in the repository, and the Firewall rules for "stateless zone *X* → stateful zone *X*"
> are only created with it. The same exception review also lets the platform team remove the stateful cluster again
> when its last workload moves to a PaaS service.

- **Clusters are cattle, built by IaC.** An environment module creates what all clusters of an environment share
  and what must survive a cluster rebuild: the Key Vaults per zone (with the application secrets), the platform Key
  Vault (with the environment's certificates and their role assignments), the application managed identities, the
  ACR and the Azure Policy assignments. Two cluster modules (stateless, stateful) with `env` and `az` as parameters
  create the VNet, cluster, system pool (and, in the stateful cluster, the zone node pools), private endpoints to the shared zone and platform Key Vaults, the federated
  credentials and – in stateless clusters – the Flux bootstrap. The IaC also writes a
  `cluster-vars` ConfigMap (`ENV`, `CLUSTER_TYPE`, `AZ`, `CLUSTER_NAME`, the zones' node subnet IDs) that Flux uses for substitutions (the
  stateful pipeline sets the same variables itself).
- **Versions are the one intended difference.** Environments and cells run the same configuration but not always the
  same Kubernetes version or node image: patches move through dev → acc → prd with a delay, and `sl-az1` and `sl-az2`
  run different minors by design ([update policy](12-zero-downtime-cluster-upgrades.md#update-policy)).
- **Everything inside a cluster comes from Git** – via Flux in the stateless clusters and via the deployment pipeline
  in the stateful cluster; no manual `kubectl apply`. Human access in acc and prd is read-only Kubernetes RBAC plus
  break-glass via PIM.
- **Every environment has its own ACR** (in its backend spoke); the promotion pipeline imports the exact image
  digests from the previous environment's ACR (`az acr import`), so prd never pulls from the Internet.

---

[Back to contents](../README.md) · Previous: [8. Cluster types: stateless and stateful](08-cluster-types-stateless-and-stateful.md) · Next: [10. Keeping clusters in sync: Flux for stateless, pipelines for stateful](10-keeping-clusters-in-sync.md)
