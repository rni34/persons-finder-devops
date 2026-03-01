# ADR-001: No CPU Limits for JVM Workloads

## Status
Accepted

## Context
Kubernetes best practice guides often recommend setting both CPU requests and limits. However, CPU limits enforce CFS (Completely Fair Scheduler) quota, which throttles a container even when the node has spare CPU. JVM workloads (Spring Boot 2.7 on JDK 11) have bursty CPU patterns during JIT compilation, class loading, and garbage collection pauses that trigger CFS throttling, causing latency spikes visible as increased p99 response times.

## Decision
Set CPU requests (250m) for scheduling but omit CPU limits. Memory limits (1Gi) are retained — OOM protection is critical. A LimitRange enforces a minimum CPU request (50m) to prevent BestEffort pods.

## Consequences
- JVM can burst above 250m during GC/JIT without throttling
- Node-level resource contention is managed by the scheduler via requests
- Engineers must not add `resources.limits.cpu` without load testing to confirm no latency regression
- Monitor `container_cpu_cfs_throttled_periods_total` — if this metric appears, a CPU limit was accidentally added
