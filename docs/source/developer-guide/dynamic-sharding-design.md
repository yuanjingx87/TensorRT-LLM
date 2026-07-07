# Design Doc: Dynamic Test Sharding for L0 CI

Status: Draft
Author: Yuanjing Xue
Last updated: 2026-07-06

## 1. Background

L0 integration tests run as parallel Jenkins stages, and each stage runs one
*shard* of a larger test list. Today the shard layout is **statically hardcoded**
in `jenkins/L0_Test.groovy`: every stage declares how many shards its test list is
split into (`split_count`) and which shard it owns (`splitId`). For example, the
A10 PyTorch tests are hardcoded to always split into two stages.

At runtime each stage asks `pytest-split` for its slice using the
`least_duration` algorithm, which greedily bin-packs tests into `split_count`
groups of roughly equal *predicted* wall-time, based on a `.test_durations` file
of per-test timings.

Two mechanisms already move toward cluster-awareness and runtime resizing:

- **Per-cluster durations.** When enabled, each stage reads and writes a
  cluster-specific durations file so the bin-packing baseline reflects the
  hardware it actually ran on, instead of a shared cross-cluster average.
- **CBTS split resize.** For narrowed-scope runs, `split_count` is already
  rewritten after the config is built but before the parallel stages launch. This
  is direct precedent that resizing shard counts programmatically is feasible.

## 2. Problem statement

Traffic for a given test stage is now **load-balanced across multiple clusters**,
and the same test runs at meaningfully different speeds on different clusters. But
`split_count` is fixed in code, while the cluster a stage lands on is not known
until scheduling time. This produces two failure modes:

- **Slow cluster → timeout / long tail.** A shard count tuned for a fast cluster
  under-shards on a slow one; each shard exceeds its time budget or drags out the
  critical path.
- **Fast cluster → waste.** A shard count tuned for the slow cluster over-shards
  on a fast one, spawning more pods/allocations than needed and adding queue and
  scheduling overhead for little wall-time benefit.

The existing `least_duration` packing cannot fix this: it decides *which* tests go
in each shard, but not *how many* shards exist. The shard count is the lever, and
it is currently static.

### Goal

Choose the shard count (and therefore the number of parallel stages) **dynamically**,
per stage, so that each shard's predicted wall-time on the cluster it actually runs
on stays near a target budget — regardless of which cluster the load balancer picks.

### Non-goals

- Changing the intra-shard packing algorithm.
- Changing how durations are collected or stored.
- Cross-stage rebalancing or moving tests between platforms.
- Re-sharding after a stage has already started.

## 3. Key constraint

The number of parallel stages is fixed when the pipeline's job map is built, which
happens **before** any node is allocated. But the concrete cluster a stage runs on
is only resolved later, at scheduling time. So a dynamic shard count must either
*predict* the target cluster up front, or defer stage generation until placement is
known. This tension drives the options below.

## 4. Design options

### Option A — Predictive resize at pipeline-build time (recommended)

Before building the parallel stages, run a planning pass (mirroring the existing
CBTS resize) that, for each sharded stage: predicts the target cluster, loads that
cluster's durations, sums the predicted runtime of the tests that will actually
run, and sets the shard count so each shard fits the target budget. The runtime
execution model is unchanged — each generated stage still runs "group *i* of *N*".

- **Pros:** reuses existing resize, test-list rendering, and runtime-estimate
  infrastructure; keeps the execution model and the static-shaped runtime map
  intact, so downstream tooling (e.g. the test-to-stage mapping) still works.
- **Cons:** accuracy depends on predicting the right cluster. A conservative
  fallback (assume the slowest candidate cluster) trades a few extra pods on fast
  clusters for timeout safety everywhere.

### Option B — Two-phase: plan, then generate stages

A lightweight first stage allocates a node on the target cluster, resolves the
real cluster, reads its durations, computes the shard count, and publishes it; a
second phase builds the parallel shard stages from that value.

- **Pros:** the cluster is known exactly, so the count is accurate.
- **Cons:** adds a serial hop (node queue + boot) to every sharded stage's
  critical path; more moving parts; harder to keep the static-shaped map that
  downstream tooling relies on.

### Option C — Fixed count, self-adjusting durations only (status quo+)

Keep the shard count fixed and rely solely on per-cluster durations to keep the
*within-shard* packing balanced. Requires no new logic, but does **not** solve the
core problem — the count is still static, so slow-cluster timeouts and fast-cluster
waste remain.

**Recommendation:** Option A. It solves the count problem, reuses existing
infrastructure and the current execution model, and preserves compatibility with
downstream tooling. Option B is a fallback if cluster prediction proves too
inaccurate in practice.

## 5. Proposed design (Option A)

Add a planning step that runs on each platform's config right before the parallel
stages are created. For each sharded stage it:

1. Resolves the predicted cluster for the stage's platform.
2. Loads that cluster's durations (falling back to the shared durations file).
3. Renders the stage's test list so it knows which tests will actually run under
   the current filters.
4. Sums predicted per-test durations to get total predicted stage time, assigning
   a configurable default to tests not yet in the durations file.
5. Sets the shard count so each shard's predicted time stays near the target
   budget, clamped to a maximum to protect the pod/quota budget.

Everything downstream stays the same: each generated stage runs its group via the
same `pytest-split` path, using the same cluster's durations.

### Tunables

- **Target per-shard time** (per-platform overridable).
- **Maximum shard count** per stage.
- **Default duration** for tests missing from the durations file.
- A **kill switch** to fall back to the fully-static layout during rollout.

### Cluster prediction

Start conservative — assume the slowest candidate cluster so each shard fits the
budget on any cluster the balancer picks, accepting a few extra shards on fast
clusters. Once load-balancer placement hints are available up front, switch to the
predicted cluster for tighter counts.

## 6. Interactions / risks

- **Downstream stage mapping.** The test-to-stage mapping tool relies on the shard
  layout. Option A keeps the same runtime shape, but stage names now vary per run;
  confirm the tool reads the resolved layout rather than the source literal.
- **Result reuse and retries.** A changed shard count must not collide with a prior
  run's cached results. Encode the shard count in the stage name (as CBTS already
  does for narrowed stages) so differing layouts stay distinct.
- **Durations bootstrap.** New tests and cold per-cluster files under-estimate;
  the default-duration and shared-file fallbacks cover this, and unknown-test
  counts should be logged.
- **Count stability.** Small duration drift shouldn't flip the shard count every
  run. Consider hysteresis (only change the count when predicted time crosses a
  band) to keep the layout and result reuse stable.
- **Budget guardrails.** The maximum-shard cap prevents a slow-cluster estimate
  from exploding the shard count.

## 7. Rollout plan

1. Land the planning step behind the kill switch, defaulted **off**, logging the
   shard count it *would* choose next to the current static count (shadow mode).
2. Compare shadow counts vs. static and observed stage wall-times for a week.
3. Enable for one low-risk platform with a conservative target budget.
4. Verify downstream mapping, result reuse, and retry accounting.
5. Expand platform-by-platform; tune the budget and cap from observed tails.

## 8. Open questions

- Is the load balancer's cluster choice knowable at pipeline-build time, or only
  at scheduling time? (Determines whether Option A can predict exactly or must stay
  conservative — or whether Option B is needed for some stages.)
- Does the test-to-stage mapping tool consume the resolved runtime layout or the
  source literal?
- What target per-shard time fits each platform? Derive from current p95 stage
  wall-times.
- How fresh are the per-cluster durations files, and how are they updated?
