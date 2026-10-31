---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# CALL functions first

## Context and Problem Statement

Users need to save, run, validate and recheck rules. LadybugDB supports both table functions and custom statements through its extension pipeline.

## Considered Options

* Table functions only
* Custom statements
* Table functions now, statements later as syntax over them

## Decision Outcome

Chosen option: "Table functions now, statements later as syntax over them", because both.

Rejected: Table functions only (stable API; writes through `rewriteFunc`); Custom statements (reads well, but tied to parser internals).

### Consequences

* Good, because the functions are the single semantics and statements are sugar.
* Bad, because module source is embedded into generated Cypher, so escaping is a correctness concern.

## More Information

Recorded in the knowledge graph as [[decisions#CALL functions first]]. Functions: `elpi_save`, `elpi_run`, `elpi_query`, `elpi_validate`, `elpi_recheck`, `elpi_annotate`, `elpi_signature`, `elpi_drop`, `elpi_export`, `elpi_import`.
