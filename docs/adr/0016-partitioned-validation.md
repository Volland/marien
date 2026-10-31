---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# Partitioned validation

## Context and Problem Statement

Validation rules reach tables of 1M to 100M facts, and full-scope materialization does not fit one LeanElpi store.

## Considered Options

* Anchor partitions with a static locality check only
* Anchor partitions, key partitions and precomputed structural facts
* A user-supplied partition query without a check

## Decision Outcome

Chosen option: "Anchor partitions, key partitions and precomputed structural facts".

Rejected: Anchor partitions with a static locality check only; A user-supplied partition query without a check (silently wrong).

### Consequences

* Good, because answers equal full-scope answers for every module the checks accept, and each batch gets a fresh store.
* Good, because structural properties (cycles, components) come from SCC and WCC computed in the calling transaction, so they are never stale.
* Bad, because `dynamic` entry points and rules failing the checks cannot be partitioned.

## More Information

Recorded in the knowledge graph as [[decisions#Partitioned validation]]. Each violation's subject must be the anchor, so overlapping neighbourhoods never double-count.
