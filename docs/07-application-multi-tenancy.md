# 7. Application multi-tenancy inside a zone

![Namespace tenancy](../images/07-namespace-tenancy.svg)

Each application gets its own namespace(s) inside a zone, with a baseline policy set applied automatically:

1. default deny for inbound and outbound traffic;
2. allow DNS to CoreDNS in `kube-system`;
3. allow inbound traffic only from the zone's Traefik gateway namespace (stateless clusters) or, in the stateful cluster,
   only from the node subnets of the same zone in the stateless clusters (Cilium CIDR policy; the applications'
   `LoadBalancer` Services use `externalTrafficPolicy: Local` so the client IP is preserved);
4. allow traffic within the namespace;
5. allow egress only to the zone Key Vault private endpoint, the platform Key Vault private endpoint (only pods that
   need a certificate) and approved FQDNs (via firewall).

Applications in the same zone therefore cannot talk to each other unless an explicit policy pair is agreed.
Kubernetes RBAC is namespace-scoped (Entra ID groups per application team), plus ResourceQuota/LimitRange per
namespace.

---

[Back to contents](../README.md) · Previous: [6. Workload identity first, Key Vault secrets only when needed](06-workload-identity-and-secrets.md) · Next: [8. Cluster types: stateless and stateful](08-cluster-types-stateless-and-stateful.md)
