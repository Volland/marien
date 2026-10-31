---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# Materialize facts per call

## Context and Problem Statement

A λProlog program sees only clauses it was given. Rules must reach graph data without re-entering LadybugDB while a function call holds its transaction state.

## Considered Options

* Materialize per call
* Lazy builtins calling back into LadybugDB
* Materialization plus point-lookup callbacks

## Decision Outcome

Chosen option: "Materialize per call", because read the reached tables into ELPI facts before solving; the engine never touches the database.

Rejected: Lazy builtins calling back into LadybugDB (needs host-callback builtins and re-enters the database mid-call); Materialization plus point-lookup callbacks (keeps the re-entrancy problem for the callbacks).

### Consequences

* Good, because a run is a pure function of rules, scope, parameters and schema hash: cacheable, replayable, comparable.
* Good, because no FFI change is needed for data access.
* Bad, because memory bounds how much one run can load, which forces partitioning at scale ([[adr:0016]]).

## More Information

Recorded in the knowledge graph as [[decisions#Materialize facts per call]]. Reads happen in the calling transaction ([[adr:0021]]).
