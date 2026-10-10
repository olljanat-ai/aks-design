# 5. Allowed and blocked flows

![Allowed flows](../images/05-allowed-flows.svg)

Only the flows Kubernetes needs to function are allowed between a workload zone and the rest of the platform:

| # | Source | Destination | Port | Purpose |
|---|---|---|---|---|
| ① | Zone nodes | `snet-apiserver` | TCP 443, 4443 | kubelet / pods → API server |
| ② | `snet-apiserver` | Zone nodes | TCP 10250 | logs, exec, port-forward |
| ③ | Zone pods | CoreDNS (system pods) | UDP/TCP 53 | name resolution |
| ④ | metrics-server (system pods) | Zone nodes | TCP 10250 | resource metrics |
| ⑤ | The zone's External Secrets Operator (`<zone>-secrets` pods) | Own zone Key Vault PE | TCP 443 | application secrets; application pods never reach a Key Vault ([section 6](06-workload-identity-and-secrets.md#delivered-only-by-external-secrets-operator)) |
| ⑤b | The zone's External Secrets Operator (`<zone>-secrets` pods) | Platform Key Vault PE in `snet-platform-pe` | TCP 443 | certificates for Traefik and TLS-terminating apps; Cilium policy allows only these pods, RBAC only their zone's certificates |
| ⑥ | Zone nodes + pods | Azure Firewall | per FQDN | AKS required FQDNs, MCR, Entra ID (workload identity token exchange), Azure Monitor; pods only to the FQDNs of their application's egress policy |
| ⑦ | Zone nodes | All nodes | TCP 4240, ICMP | Cilium health (optional) |
| – | AzureLoadBalancer | `snet-apiserver` | TCP 9988 | API server health probe |
| – | `snet-apiserver` | Platform Key Vault private endpoint created by AKS for KMS | TCP 443 | etcd encryption with the cluster's KMS key ([section 18](18-encryption-at-rest-and-customer-managed-keys.md)) |

**Everything else between zones is blocked** – pod-to-pod, pod-to-other-zone Key Vault and direct Internet –
enforced three times: NSG (L3/L4), Azure Firewall (L3–L7, logged), Cilium cluster-wide policy (pod identity).

Inside the allowed flows, a pod reaches a destination outside the cluster only if its application has declared that
destination by **FQDN** in its own Cilium egress policy ([section 16](16-advanced-networking-and-fqdn-egress.md)): the
Firewall decides what a *zone* may reach, the FQDN policy what an *application* may reach.

---

[Back to contents](../README.md) · Previous: [4. Node pools](04-node-pools.md) · Next: [6. Workload identity first, Key Vault secrets only when needed](06-workload-identity-and-secrets.md)
