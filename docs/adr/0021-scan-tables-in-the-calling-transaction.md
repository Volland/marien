---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# Scan tables in the calling transaction

## Context and Problem Statement

Materialization, partition neighbourhoods and structural facts all read the database during a function call, which must not issue nested Cypher.

## Considered Options

* Scan through LadybugDB's storage and graph API in the calling transaction, as the algo extension does
* Run nested Cypher queries from the function
* Precompute facts in separate statements

## Decision Outcome

Chosen option: "Scan through LadybugDB's storage and graph API in the calling transaction, as the algo extension does".

Rejected: Run nested Cypher queries from the function (re-entrancy); Precompute facts in separate statements (can be stale).

### Consequences

* Good, because every run sees one consistent snapshot, and SCC and WCC facts are never stale.
* Bad, because the shim depends on internal storage APIs that change between LadybugDB versions ([[adr:0017]]).

## More Information

Recorded in the knowledge graph as [[decisions#Scan tables in the calling transaction]].
