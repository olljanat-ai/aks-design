# 5. Allowed and blocked flows

![Allowed flows](../images/05-allowed-flows.svg)

Only the flows Kubernetes needs to function are allowed between a workload zone and the rest of the platform:

| # | Source | Destination | Port | Purpose |
|---|---|---|---|---|
| ① | Zone nodes | `snet-apiserver` | TCP 443, 4443 | kubelet / pods → API server |
| ② | `snet-apiserver` | Zone nodes | TCP 10250 | logs, exec, port-forward |
| ③ | Zone pods | CoreDNS (system pods) | UDP/TCP 53 | name resolution |
| ④ | metrics-server (system pods) | Zone nodes | TCP 10250 | resource metrics |
| ⑤ | Zone pods | Own zone Key Vault PE | TCP 443 | secrets (only applications that need one) |
| ⑤b | Zone pods that need a certificate (Traefik, TLS-terminating apps) | Platform Key Vault PE in `snet-platform-pe` | TCP 443 | certificates; Cilium policy allows only these pods, RBAC only their zone's certificates |
| ⑥ | Zone nodes + pods | Azure Firewall | per FQDN | AKS required FQDNs, MCR, Entra ID (workload identity token exchange), Azure Monitor |
| ⑦ | Zone nodes | All nodes | TCP 4240, ICMP | Cilium health (optional) |
| – | AzureLoadBalancer | `snet-apiserver` | TCP 9988 | API server health probe |

**Everything else between zones is blocked** – pod-to-pod, pod-to-other-zone Key Vault and direct Internet –
enforced three times: NSG (L3/L4), Azure Firewall (L3–L7, logged), Cilium cluster-wide policy (pod identity).

---

[Back to contents](../README.md) · Previous: [4. Node pools](04-node-pools.md) · Next: [6. Workload identity first, Key Vault secrets only when needed](06-workload-identity-and-secrets.md)
