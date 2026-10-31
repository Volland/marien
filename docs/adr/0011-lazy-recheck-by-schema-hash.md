---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# Lazy recheck by schema hash

## Context and Problem Statement

A schema change can make stored modules ill-typed, change their generated code, or change their analysis verdicts. LadybugDB offers no DDL hooks to extensions.

## Considered Options

* Lazy recheck on run by per-module hash, plus explicit `elpi_recheck`
* Eager recheck through a DDL hook
* Block DDL that breaks rules

## Decision Outcome

Chosen option: "Lazy recheck on run by per-module hash, plus explicit `elpi_recheck`", because no upstream change.

Rejected: Eager recheck through a DDL hook (needs a LadybugDB patch); Block DDL that breaks rules (needs a hook with veto).

### Consequences

* Good, because the hash covers only the tables a module reaches, so unrelated DDL invalidates nothing.
* Good, because a broken module errors and is marked `broken`; stale generated code is never used.
* Bad, because breakage is found on the next run or recheck, not at DDL time; the eager hook is proposed upstream later.

## More Information

Recorded in the knowledge graph as [[decisions#Lazy recheck by schema hash]]. Lazy regeneration happens in memory; only `elpi_recheck` persists it.
