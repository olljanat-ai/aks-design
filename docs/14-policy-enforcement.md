# 14. Policy enforcement with the Azure Policy add-on

**The AKS-native [Azure Policy add-on](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/policy-for-kubernetes)
is the single policy engine**, enabled by the cluster IaC in every cluster. It runs Gatekeeper, but AKS installs and
upgrades it, and the policies are ordinary Azure Policy definitions and assignments – the same tool that governs the
Azure resources (cluster settings, allowed VM sizes, VNet encryption, local auth disabled, private endpoints only).
No Gatekeeper is installed by Flux.

- **Assignments per environment subscription** (`sub-aks-dev`, `sub-aks-acc`, `sub-aks-prd`), so a new or rebuilt
  cluster gets every policy automatically. Compliance of all clusters is visible in one place (Azure Policy, Defender
  for Cloud).
- **Built-in definitions first**: the Kubernetes pod security *restricted* initiative, allowed images, required
  probes and resource requests, and [deployment safeguards](https://learn.microsoft.com/en-us/azure/aks/deployment-safeguards).
- **Custom definitions** (`Microsoft.Kubernetes.Data` mode) for the platform's own rules, with the constraint or
  mutation template embedded as Base64 in the definition. Templates are kept in the IaC repository and tested in CI
  with `gator verify`; CEL-based definitions (generated as Kubernetes `ValidatingAdmissionPolicy`, evaluated
  in-process) are preferred for new validations where they can express the rule.
- **Rollout dev → acc → prd**: definitions are versioned; a new or changed definition is assigned with effect `audit`
  in dev, then `deny`, then promoted to acc and prd with the rest of the platform change.
- **Platform namespaces**: `kube-system` and `gatekeeper-system` are excluded by the add-on; `flux-system` and other
  platform namespaces are excluded from application rules through the definitions' namespace exclusion parameters.
  `<zone>-gateway` is excluded only from the rules that Traefik itself must break (its `LoadBalancer` Service) – zone
  pinning and the External Secrets Operator rules still apply to it. `<zone>-secrets` (External Secrets Operator) is a platform namespace pinned to its
  zone in the same way.

Limits of the add-on and how the design handles them:

| Limit | Consequence in this design |
|---|---|
| Needs `data.policy.core.windows.net`, `store.policy.core.windows.net`, `dc.services.visualstudio.com` (+ Entra ID); no Private Link | Firewall application rules for these FQDNs, also from the stateful cluster (exception to "no Internet", see [flows](08-cluster-types-stateless-and-stateful.md#flows-between-frontend-and-backend)) |
| Custom definitions cannot use Gatekeeper data replication (no lookups of other objects) | Zone rules match the namespace name prefix `<zone>-*`; "PDB exists for every Deployment / StatefulSet" is checked in CI on the rendered manifests, because Flux and the stateful pipeline only apply validated artifacts |
| Policies are synced from Azure every 15 minutes | The stateless cluster bootstrap keeps the Flux `apps` Kustomization suspended until all assigned constraint templates and constraints are present in the cluster; the stateful pipeline checks the same before every run |
| Gatekeeper config cannot be changed | No custom Gatekeeper settings; defaults are fine for this design |
| Max 10 000 pods per cluster | Well above the expected size; monitored |

| Policy | All clusters | Stateless | Stateful |
|---|---|---|---|
| Namespace `<zone>-*` has label `platform/zone=<zone>`; pod nodeSelector / toleration match the prefix (mutation + validation) | ✔ | | |
| `platform/arch` / `platform/capacity` labels: inject the architecture `nodeSelector` and the spot toleration + preferred affinity (mutation); reject unknown values, own `kubernetes.io/arch` / `karpenter.sh/capacity-type` selectors and spot tolerations without the label ([section 4](04-node-pools.md#cpu-architecture-and-spot-chosen-by-the-application)) | ✔ | all values | defaults only (`amd64`, `on-demand`) |
| Images by digest from the environment's ACR only | ✔ | | |
| ServiceAccount used by application pods carries the workload identity client ID and is not `secrets-reader`; no `imagePullSecrets` | ✔ | | |
| Secrets only through External Secrets Operator ([section 6](06-workload-identity-and-secrets.md#delivered-only-by-external-secrets-operator)): in application namespaces and `<zone>-gateway`, `Secret`s may be created or changed only by the zone's ESO controller ServiceAccount (`system:serviceaccount:<zone>-secrets:external-secrets`, checked on the admission request's user) – Helm release Secrets excepted; no `SecretProviderClass` and no `secrets-store.csi.k8s.io` volumes anywhere (platform namespaces included) | ✔ | | |
| ESO objects in application namespaces and `<zone>-gateway`: `SecretStore` only `azurekv` with the own zone vault or `kv-<env>-platform`, `authType: WorkloadIdentity`, `serviceAccountRef: secrets-reader`, `controller: <zone>`; `ExternalSecret` only against a `SecretStore` (not `ClusterSecretStore`), `remoteRef.key` / `dataFrom` names with the application's prefix or its `cert-<zone>-…`; `ClusterSecretStore`, `ClusterExternalSecret`, `PushSecret` platform only | ✔ | | |
| Requests set, probes set, no privileged / hostNetwork / hostPath for applications | ✔ | | |
| Egress out of the cluster only by FQDN: application `CiliumNetworkPolicy` egress limited to `toEndpoints`, in-cluster `toServices` and `toFQDNs` with ports (no `toCIDR`/`toCIDRSet`/`toEntities`); no bare or too broad wildcards; DNS rules only for declared names; no `NetworkPolicy` egress `ipBlock`; `CiliumClusterwideNetworkPolicy` and Cilium CIDR / egress gateway objects platform only; `dnsPolicy: ClusterFirst` ([section 16](16-advanced-networking-and-fqdn-egress.md)) | ✔ | | |
| Cluster: Cilium dataplane, ACNS enabled, Azure Linux 3.0 on all node pools / `AKSNodeClass` `imageFamily: AzureLinux`; eBPF host routing (`BpfVeth`); Key Vault secrets provider (Secrets Store CSI) add-on disabled | ✔ | | |
| Replica and rollout guardrails (PDB existence: CI check) of [section 11](11-zero-downtime-application-upgrades.md) | ✔ | ≥ 2 replicas | ≥ 3 replicas, zone spread |
| Reject `PersistentVolumeClaim` | | ✔ | |
| NAP `NodePool` / `AKSNodeClass`: subnet, `platform/zone` label, taint and AZ of its zone; only allowed VNet-encryption-capable VM sizes (amd64 and arm64); a spot `NodePool` must carry the `platform/capacity=spot:NoSchedule` taint | | ✔ | |
| Reject `Ingress`; only HTTPS `Gateway` listeners; `HTTPRoute` only to the zone's HTTPS listener and zone domain | | ✔ | |
| Reject `LoadBalancer` / `NodePort` Services outside `<zone>-gateway` | | ✔ | |
| Reject `Ingress`, `Gateway`, `HTTPRoute`; `LoadBalancer` only internal, in the zone's ILB subnet, `externalTrafficPolicy: Local`; no `NodePort` | | | ✔ |
| Namespace has `platform/stateful-exception` | | | ✔ |

---

[Back to contents](../README.md) · Previous: [13. Encryption in transit and TLS](13-encryption-in-transit-and-tls.md) · Next: [15. AI-driven day 2 operations](15-ai-driven-day-2-operations.md)
