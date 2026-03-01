# ADR-002: PDB Uses maxUnavailable, Not minAvailable

## Status
Accepted

## Context
PodDisruptionBudgets can use either `minAvailable` or `maxUnavailable`. With HPA scaling between 2–10 replicas, `minAvailable: 1` allows up to N-1 simultaneous evictions during node drains (e.g., 9 of 10 pods evicted at once), causing traffic spikes on the single remaining pod.

## Decision
Use `maxUnavailable: 1` to cap disruption to exactly one pod regardless of current replica count. During cluster maintenance or node drains, at most one pod is evicted at a time.

## Consequences
- Node drains take longer (pods evicted sequentially, not in parallel)
- Traffic distribution remains stable during maintenance windows
- Engineers must not switch to `minAvailable` without understanding the N-1 eviction risk at high replica counts
