# 6. Workload identity first, Key Vault secrets only when needed

![Workload identity and Key Vault](../images/06-key-vault-abac.svg)

**Rule: an application authenticates with its workload identity wherever the target supports Microsoft Entra ID;
a secret is used only when there is no other way.** No passwords, connection strings with keys, SAS tokens or
storage account keys for Azure services.

## Workload identity per application

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
| Key Vault | **No role** – applications never call Key Vault; their secrets are delivered by External Secrets Operator ([below](#delivered-only-by-external-secrets-operator)) | RBAC permission model |
| Other Azure APIs (App Configuration, Azure OpenAI, …) | Azure RBAC roles | `disableLocalAuth` where available |

  "Local auth disabled" is enforced with Azure Policy on the resources, so a key-based fallback cannot be switched
  on later. Application configuration contains only endpoints and client IDs, which are not secrets.
- **Platform components use workload identity too**: Flux (`OCIRepository` `provider: azure`), the stateful
  deployment pipeline (workload identity federation, no client secret), External Secrets Operator (secrets and
  certificates, below), the Azure Monitor agent, external-dns. Images are pulled
  with the kubelet identity, which has only `AcrPull` on the environment's ACR – no `imagePullSecrets`.

## Secrets only when needed

A secret is allowed only when the target cannot use Entra ID: third-party APIs and SaaS keys, partner systems and
legacy protocols. TLS certificates are **not** in the zone vaults; they live in the environment's platform Key Vault
([section 13](13-encryption-in-transit-and-tls.md#certificates-issued-centrally-distributed-through-the-platform-key-vault)).
Such a secret always lives in the zone's **Key Vault** – never in Git, Helm values or a Kubernetes `Secret` created by
hand.

Each zone has its **own Key Vault per environment** (`kv-<env>-<zone>`, RBAC permission model, public access
disabled), shared by all clusters of the environment, with a private endpoint in the zone's `snet-<zone>-pe` of every
cluster spoke. Inside a zone's vault, applications share the vault but are separated with
[Azure ABAC conditions](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-abac):

- The application's **secret reader identity** `id-<zone>-<app>-secrets` (see below – not the application's own
  identity) gets **Key Vault Secrets User** on the zone vault with condition
  `@Resource[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith '<app>-'`.
- Application pipelines get **Key Vault Secrets Officer** with the same prefix on
  `@Request[...secrets:name]` for `setSecret`; rotation is owned by the application team (expiry dates set, Event
  Grid `SecretNearExpiry` alerts).

Constraints to keep in mind: Key Vault ABAC is **preview**, supports **secrets only** (not keys/certificates
operations) and only **vault name + secret name** attributes, and lowercase values. Therefore the secret naming
convention `<app>-<secret>` is mandatory and must be enforced by the platform. A name condition on
`readMetadata` breaks list calls – gate `getSecret` instead. Because most applications need no secrets at all, the
vault stays small and the preview dependency affects only the few exceptions.

## Delivered only by External Secrets Operator

**Rule: no application reads Key Vault itself.** Secrets and certificates reach pods only as Kubernetes `Secret`s
written by [External Secrets Operator](https://external-secrets.io/) (ESO). The **Secrets Store CSI driver is not
used**: the AKS Key Vault secrets provider add-on (`azure-keyvault-secrets-provider`) is disabled on every cluster and
Azure Policy denies enabling it, its CRDs are not installed, and admission rejects `SecretProviderClass` objects and
`secrets-store.csi.k8s.io` volumes ([section 14](14-policy-enforcement.md)).

- **One ESO controller per isolation zone**, in the platform namespace `<zone>-secrets` (a reserved application
  name, like `<zone>-gateway`), pinned to the zone's nodes like every other workload of the zone and deployed by
  Flux (stateless) or the pipeline (stateful). Each instance has its own `controllerClass` (`<zone>`) and reconciles
  only the stores of its zone; the CRDs and the conversion webhook are installed once per cluster. Its path to Key
  Vault is the zone's own flow ⑤ (⑤b to the platform vault, [section 5](05-allowed-and-blocked-flows.md)), so a
  controller can never reach another zone's vault and a compromised controller exposes one zone at most. It may
  write `Secret`s and request ServiceAccount tokens only through RoleBindings in its own zone's namespaces, created
  with each namespace at onboarding.
- **A secret reader identity per application** (`id-<zone>-<app>-secrets`), created by IaC only for applications with
  a secret exception or a certificate. It is separate from the application's own identity and is federated (one
  credential per cluster, like above) to the ServiceAccount **`secrets-reader`** in the application's namespace. It
  is the only identity with a data-plane role on the zone vault, limited to the application's prefix by the ABAC
  condition above. Application pods may not run as `secrets-reader` (Azure Policy), and the application teams'
  Kubernetes RBAC does not include `serviceaccounts/token` – only the zone's ESO controller can obtain its token.
- **One `SecretStore` per application namespace**, generated from the onboarding by a platform preset: provider
  `azurekv`, `vaultUrl` of the own zone vault (and a second store for the platform vault where the application has
  a certificate, [section 13](13-encryption-in-transit-and-tls.md)), `authType: WorkloadIdentity` with
  `serviceAccountRef: secrets-reader`, `controller: <zone>`. Azure Policy rejects any other store configuration.
  Applications write only **`ExternalSecret`s** that reference their own namespace's store; `ClusterSecretStore`,
  `ClusterExternalSecret` and `PushSecret` are platform only. An application can therefore only ever pull with its
  own reader identity, and Key Vault ABAC still decides which secret names that is – application A's
  `ExternalSecret` for `b-…` fails with `403`.
- **No other way in.** Application identities have no Key Vault role at all; Cilium allows `*.vault.azure.net`
  only from `<zone>-secrets`, and Azure Policy rejects an application egress policy that names a vault
  ([section 16](16-advanced-networking-and-fqdn-egress.md)). In application namespaces, admission accepts
  `Secret`s only from the zone's ESO controller (plus Helm release Secrets), so a secret in Git, Helm values or
  created with `kubectl` is rejected as before. Only the environment IaC module assigns Key Vault data-plane roles;
  an acceptance test and the security agent ([section 15](15-ai-driven-day-2-operations.md)) check that no
  application identity holds one.
- **Consumption and rotation.** Applications mount the resulting `Secret` as a **volume** (preferred: the kubelet
  updates the files after a rotation; no `subPath`) or as environment variables (picked up only on the next
  rollout). `refreshInterval` is 1 hour by default, shorter where a rotation must take effect faster; the
  `SecretSynced` condition and ESO's metrics alert the platform and the application team when a sync fails.

Trade-offs of delivering secrets as Kubernetes `Secret`s instead of CSI file mounts:

- The values are **stored in etcd**, encrypted with the cluster's customer-managed KMS key
  ([section 18](18-encryption-at-rest-and-customer-managed-keys.md)), and readable by anyone with `get secrets` in
  the namespace: only the application team in its own namespaces, the platform team through PIM; the AI agents'
  `Azure Kubernetes Service RBAC Reader` role does not include `Secret`s.
- **ESO becomes a critical platform component** (one controller per zone and cluster, upgraded like Traefik). In
  return a Key Vault or Entra ID outage no longer stops pods from starting – the `Secret` is already in the
  cluster, whereas a CSI mount fails at pod start.

---

[Back to contents](../README.md) · Previous: [5. Allowed and blocked flows](05-allowed-and-blocked-flows.md) · Next: [7. Application multi-tenancy inside a zone](07-application-multi-tenancy.md)
