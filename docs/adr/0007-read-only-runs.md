---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# Read-only runs

## Context and Problem Statement

Rule runs could write inferred facts back, but writing from inside a running function re-enters the database and needs provenance to retract.

## Considered Options

* Read-only: results are rows, callers compose with Cypher `MERGE`
* The extension writes inferred facts itself
* Read-only now, a provenance-tagged `elpi_materialize` later

## Decision Outcome

Chosen option: "Read-only now, a provenance-tagged `elpi_materialize` later", because defers the write design.

Rejected: Read-only: results are rows, callers compose with Cypher `MERGE` (LadybugDB allows `CALL ... WITH ... MERGE`); The extension writes inferred facts itself (re-entrancy, duplicates and retraction).

### Consequences

* Good, because runs stay pure ([[adr:0003]]).
* Bad, because forward-chaining materialization is not available in v1.

## More Information

Recorded in the knowledge graph as [[decisions#Read-only runs]]. Grammar check: `iC_InQueryCall` is a reading clause in LadybugDB's `Cypher.g4`, so updating clauses may follow it.
