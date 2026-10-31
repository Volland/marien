---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# Rules stored in system tables

## Context and Problem Statement

λProlog modules must persist, travel with the database, share transactions with schema changes, and be queryable.

## Considered Options

* System tables in the database, source text authoritative
* Files on disk
* Clause-level graph storage

## Decision Outcome

Chosen option: "System tables in the database, source text authoritative", because `_elpi_module` rows and `_elpi_accumulates` edges.

Rejected: Files on disk (diffable, but drift from the database and cannot share a transaction); Clause-level graph storage (queryable, but loses comments and clause order (which cut depends on)).

### Consequences

* Good, because backups and transactions cover rules, and Cypher can answer which modules depend on which.
* Good, because derived metadata (defined and used predicates, schema hash, generated code) is stored beside the source.
* Bad, because writes go through `rewriteFunc` and the source must be escaped into generated Cypher with a tested byte-exact round trip.

## More Information

Recorded in the knowledge graph as [[decisions#Rules stored in system tables]]. Compiled handles are cached in memory by module version and schema hash and never stored. `_elpi_*` tables are excluded from the generated signature.
