---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# Milestone order

## Context and Problem Statement

Linking a Lean runtime into LadybugDB is the likeliest failure, and nothing validates at the target scale before partitioning.

## Considered Options

* Spike, M0 LeanElpi 0.4, M1 tracer, M2 typed validation, M3 analysis and scale, M4 higher-order layer, M5 ecosystem
* Higher-order layer before scale

## Decision Outcome

Chosen option: "Spike, M0 LeanElpi 0.4, M1 tracer, M2 typed validation, M3 analysis and scale, M4 higher-order layer, M5 ecosystem".

Rejected: Higher-order layer before scale.

### Consequences

* Good, because the riskiest unknown is tested first and M4 reuses M3's analysis.
* Bad, because the headline feature (higher-order rules over the schema) arrives late.

## More Information

Recorded in the knowledge graph as [[decisions#Milestone order]].
