# aks-design

Design drafts for a large Azure Kubernetes Service (AKS) platform with strong isolation between
**internal / external** workloads and between **countries**, plus application multi-tenancy inside each isolation zone.

The platform runs **two types of clusters** – zonal **stateless** clusters in the frontend network and an
**optional** zone-redundant **stateful** cluster in the Internet-less backend network – in **dev, acc and prd**, i.e. six
clusters (nine with the stateful cluster) kept in sync from one Git repository – the stateless clusters with **FluxCD**, the stateful cluster
with **CI/CD pipelines** – with fully automated zero-downtime upgrades of applications and clusters.
Data belongs in **Azure PaaS services**; the stateful cluster is the *last option*, used only when no suitable PaaS
service exists or a special use case requires it, and it is **not built at all until the first such workload is
approved**. All admission policies are implemented with the AKS-native **Azure Policy add-on** (Gatekeeper managed by AKS).
Pictures 1–7 describe what is *inside* one cluster; pictures 8–14 describe the fleet of clusters and how traffic is
encrypted; picture 15 shows how AI agents operate the platform through pull requests within human-defined guardrails;
picture 16 shows how every cluster uses **Advanced Container Networking Services** with **eBPF host routing**, and
how applications may send traffic out of a cluster only to destinations they have declared in an **FQDN-based egress
policy**. Picture 17 shows how the platform is built and accepted in a separate **build tenant** that is not connected
to the corporate network, before the accepted version is deployed to the corporate landing zone.

> Status: **draft** for review. Country codes `fi` / `se` and all IP ranges are examples.

## Contents

- [Requirements](docs/requirements.md)
- [1. Overview](docs/01-overview.md)
- [2. Network layout](docs/02-network-layout.md)
- [3. Control plane](docs/03-control-plane.md)
- [4. Node pools](docs/04-node-pools.md)
- [5. Allowed and blocked flows](docs/05-allowed-and-blocked-flows.md)
- [6. Workload identity first, Key Vault secrets only when needed](docs/06-workload-identity-and-secrets.md)
- [7. Application multi-tenancy inside a zone](docs/07-application-multi-tenancy.md)
- [8. Cluster types: stateless and stateful](docs/08-cluster-types-stateless-and-stateful.md)
- [9. Environments (six to nine clusters)](docs/09-environments.md)
- [10. Keeping clusters in sync: Flux for stateless, pipelines for stateful](docs/10-keeping-clusters-in-sync.md)
- [11. Zero-downtime application upgrades](docs/11-zero-downtime-application-upgrades.md)
- [12. Zero-downtime cluster upgrades](docs/12-zero-downtime-cluster-upgrades.md)
- [13. Encryption in transit and TLS](docs/13-encryption-in-transit-and-tls.md)
- [14. Policy enforcement with the Azure Policy add-on](docs/14-policy-enforcement.md)
- [15. AI-driven day 2 operations](docs/15-ai-driven-day-2-operations.md)
- [16. Advanced networking: eBPF host routing and FQDN egress](docs/16-advanced-networking-and-fqdn-egress.md)
- [17. Implementation project and acceptance testing](docs/17-implementation-project-and-acceptance-testing.md)
- [Open questions](docs/open-questions.md)
- [Editing the pictures](docs/editing-the-pictures.md)
