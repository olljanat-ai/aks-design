# 11. Zero-downtime application upgrades

The same rules apply in every cluster and are **enforced by admission policy** (Azure Policy add-on), so no
application can be deployed in a way that breaks a zero-downtime rollout or a node drain:

| Guardrail | Stateless | Stateful |
|---|---|---|
| Replicas | `replicas` / HPA `minReplicas` ≥ 2 | ≥ 3, one per AZ |
| Spread | `topologySpreadConstraints` over nodes | `topologySpreadConstraints` over `topology.kubernetes.io/zone` |
| PodDisruptionBudget | Mandatory, `maxUnavailable: 1` (or ≤ 50 %) | Mandatory, `maxUnavailable: 1` |
| Rollout strategy | `RollingUpdate`, `maxUnavailable: 0`, `maxSurge: 25%` | `RollingUpdate` (optionally `partition` for canary) or operator-managed |
| Probes | readiness + liveness (+ startup) required | readiness gated on replication / quorum |
| Graceful shutdown | `preStop` delay + `terminationGracePeriodSeconds` longer than the gateway / traffic layer drain time | same, plus clean leader hand-over |
| Resources | requests required (HPA and NAP depend on them) | requests = limits for memory |
| Images | by digest, from the environment's ACR only | same |

- **Scaling on load** (stateless): HPA on CPU/memory or KEDA on queue length / request rate; NAP adds nodes for
  pods that do not fit and consolidates them away again. `maxReplicas` and the NAP `NodePool` limits are sized so that
  one cluster can take the full load.
- **No scaling on load in the stateful cluster**: replica counts and node pool sizes are fixed and changed as planned
  changes through the pipeline and IaC.
- **Compatibility rule**: during a release two versions run at the same time (in different cells, and for a few
  minutes inside a cell during the rolling update), so API and message changes must be backwards compatible and
  database changes follow *expand → migrate → contract* over separate releases. Client-IP affinity (external zones)
  and the single active cell (internal zones) reduce what *clients* see of this, but clients that change addresses,
  rollbacks and the data shared by all cells still meet both versions.

## Releases cell by cell

A release – a new signed fleet artifact `fleet:<git-sha>` with any number of application changes – moves through the
cells of an environment **one cell at a time**, with the same *drain → change → test → return* procedure as a
cluster upgrade ([section 12](12-zero-downtime-cluster-upgrades.md#stateless-clusters)). External zones use cell
affinity, internal zones one active cell ([incoming traffic](08-cluster-types-stateless-and-stateful.md#incoming-traffic-from-outside-and-from-inside));
with both, every interactive user switches from the old to the new version **exactly once and never back**.

The release always **starts with the internal standby cell**, so that the cell serving internal users is never
changed in place:

1. **Stateful stage first** (only if the environment has a stateful cluster): providers before consumers
   ([section 10](10-keeping-clusters-in-sync.md)).
2. **Drain cell 1** (the internal standby cell): take it out of Front Door. Its external users move to the other
   cells, which still run the old version, so nobody sees a change yet. It serves no internal users anyway.
3. **Deploy**: the pipeline moves the cell's tag (`<env>-sl-az1`) to the new artifact; Flux rolls it out and the
   pipeline waits until all Kustomizations are `Ready`. No user traffic reaches the cell during the rolling update.
4. **Test** through the per-cell test host names: smoke and synthetic tests over the real WAF and TLS path, for
   external and internal zones.
5. **Return** the cell to Front Door: its external clients come back in steps, a quarter of its IP blocks at a time,
   and this is the moment they switch to the new version. The pipeline watches error-rate and latency SLOs per cell;
   on a breach it drains the cell again – its clients fall back to the old version in the other cells – and moves the
   tag back.
6. **Switch internal zones**: after the soak, the planned switch makes cell 1 the internal active cell. All internal
   users move to the new version at once; on an SLO breach the pipeline switches back to the previous cell, which
   still runs the old version.
7. **Repeat for the next cell** (now the internal standby): drain, deploy, test, return. After the last cell all
   clients are on the new version.

An external client only moves when its own cell is drained or returned. While its cell is drained it uses another
cell, which runs either the old version or – if that cell was already released – the new one; when its cell returns,
it gets the new version. An internal client moves only with the switch in step 6. So every client switches from the
old to the new version **once and never back**:

| Client | What it sees during a release |
|---|---|
| Internal client (corporate network, other Azure workloads) | One version at a time; switches once, old → new, at the internal switch |
| External client with a stable IP address (browser, mobile app, API client, other system) | One version at a time; switches once, old → new |
| External client whose IP address changes (e.g. a phone moving between networks) | May change cells with its address and meet the other version – covered by the compatibility rule |
| Long-lived connection (WebSocket, SSE) | Reconnects when its cell is drained, returned or switched, then follows the rules above |

Consequences:

- **Releases are trains.** Each cell costs one drain time plus rollout, tests and the return, so many changes
  ride in one fleet artifact instead of one artifact per application change. An urgent fix takes the same path with
  a shorter soak.
- **N+1 capacity** is needed for releases too: while one cell is drained, the others carry its load, and the
  internal active cell carries all internal load (the same sizing as for cluster upgrades).
- **The first cell is the canary** – for external users when it returns, for internal users at the switch.
  In-cell progressive delivery (Flagger with `HTTPRoute` weights on the Traefik gateway) is not used for
  interactive applications: it splits requests inside the cell, so their clients would jump between versions again. It stays an option for back-end APIs that are strictly backwards compatible.

---

[Back to contents](../README.md) · Previous: [10. Keeping clusters in sync: Flux for stateless, pipelines for stateful](10-keeping-clusters-in-sync.md) · Next: [12. Zero-downtime cluster upgrades](12-zero-downtime-cluster-upgrades.md)
