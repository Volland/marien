---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# Proofs where practical

## Context and Problem Statement

Marien is written in Lean, and several of its properties are total statements over inductive data: codec round-trips, name injectivity, exclusion of system tables, hash determinism, partition coverage.

## Considered Options

* Tests only
* Prove properties where the proof is small and the statement total; test operational behaviour
* Prove everything

## Decision Outcome

Chosen option: "Prove properties where the proof is small and the statement total; test operational behaviour".

Rejected: Tests only; Prove everything (impractical for engine behaviour).

### Consequences

* Good, because the properties most likely to rot silently are pinned by theorems that break the build.
* Bad, because designs must say for each key property whether it is proved or tested, and why.

## More Information

Recorded in the knowledge graph as [[decisions#Proofs where practical]]. Soundness of the monotonicity and locality checks over an abstract semantics is a stretch goal, guarded by property tests until proved.
