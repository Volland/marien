---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# Differential testing with an oracle

## Context and Problem Statement

Every correctness guarantee rests on a static analysis that can be wrong.

## Considered Options

* Example tests
* Example tests plus differential property tests of the guarantees
* Both plus an independent oracle (Soufflé over the first-order stratified fragment)

## Decision Outcome

Chosen option: "Both plus an independent oracle (Soufflé over the first-order stratified fragment)".

Rejected: Example tests; Example tests plus differential property tests of the guarantees.

### Consequences

* Good, because partition equivalence, narrowing subset and rejection counterexamples test the analyses directly.
* Bad, because generators for schemas, graphs and modules are real work.

## More Information

Recorded in the knowledge graph as [[decisions#Differential testing with an oracle]].
