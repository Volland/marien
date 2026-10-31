---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# Staged rule generation over a reflected schema

## Context and Problem Statement

Rules that quantify over the schema need relations as values, but LeanElpi checks clauses with rigid type variables, so one polymorphic `schema.rel` cannot typecheck; clauses created during a run escape the static checks.

## Considered Options

* Combinators only (`graph.std`)
* Combinators plus schema reflection
* Reflection plus staged generation: meta-rules over a monomorphic schema description emit clause text, checked like hand-written code; run-time generation inferred `dynamic`

## Decision Outcome

Chosen option: "Reflection plus staged generation: meta-rules over a monomorphic schema description emit clause text, checked like hand-written code; run-time generation inferred `dynamic`", because both.

Rejected: Combinators only (`graph.std`) (no schema reflection); Combinators plus schema reflection (still needs a typed bridge from names to predicates).

### Consequences

* Good, because generated code names concrete predicates, typechecks, passes the analysis, and depends only on the schema hash.
* Good, because generated code is stored and inspectable.
* Bad, because `dynamic` entry points (which add database-predicate clauses with `=>` at run time) run at full scope only and are never partitioned.

## More Information

Recorded in the knowledge graph as [[decisions#Staged rule generation over a reflected schema]]. Annotations live in `_elpi_annotation(table, key, value)`.
