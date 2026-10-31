---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# Predicate-per-property encoding

## Context and Problem Statement

The schema must become typed ELPI terms that survive schema evolution, handle nulls, multigraphs and edge properties, and let relations be passed to higher-order rules.

## Considered Options

* One predicate per property, primary-key node constructors, reified edges
* One record term per node or edge
* A generic triple store (`node`, `prop`, `edge`)

## Decision Outcome

Chosen option: "One predicate per property, primary-key node constructors, reified edges", because typed, column-oriented.

Rejected: One record term per node or edge (compact, but positional: a new column breaks every rule); A generic triple store (`node`, `prop`, `edge`) (untyped, which defeats the schema types).

### Consequences

* Good, because a null is an absent fact and a new column is a new predicate that breaks nothing.
* Good, because relations are ordinary predicates, so `transitive R` works over any of them.
* Bad, because rel tables with several FROM/TO pairs need a generated union endpoint kind, and some LadybugDB types (MAP, BLOB, ...) are skipped with a warning in v1.

## More Information

Recorded in the knowledge graph as [[decisions#Predicate-per-property encoding]]. Type mapping: LIST to `list`, STRUCT to a generated record kind, DATE and TIMESTAMP to epoch `int`.
