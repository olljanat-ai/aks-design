# 3. Control plane

![Control plane](../images/03-control-plane.svg)

The API server uses **API Server VNet Integration**: it is projected as an internal load balancer into a
dedicated, delegated `snet-apiserver` (/28) that contains nothing else. The cluster is **private** (public
endpoint disabled). Admins (Entra ID + PIM, Azure RBAC for Kubernetes) and CI/CD reach it only through a
Private Endpoint / Private Link Service in the management VNet. Nodes talk to the ILB IP directly (no tunnel,
no DNS). The system node pool (tainted `CriticalAddonsOnly`, fixed node count) runs only platform components.

---

[Back to contents](../README.md) · Previous: [2. Network layout](02-network-layout.md) · Next: [4. Node pools](04-node-pools.md)
