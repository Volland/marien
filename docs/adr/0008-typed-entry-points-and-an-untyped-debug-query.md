---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# Typed entry points and an untyped debug query

## Context and Problem Statement

A LadybugDB table function fixes its output columns at bind time, and LeanElpi 0.3.3 reports bindings as printed strings.

## Considered Options

* Any goal, untyped rows
* Declared predicates as entry points with typed columns
* Typed `elpi_run` for production plus untyped `elpi_query` for debugging

## Decision Outcome

Chosen option: "Typed `elpi_run` for production plus untyped `elpi_query` for debugging", because both.

Rejected: Any goal, untyped rows (flexible, but types end at the boundary); Declared predicates as entry points with typed columns (modes give inputs and outputs).

### Consequences

* Good, because `i:` arguments come from a parameter map and `o:` arguments become typed columns; node kinds become primary-key columns rehydrated with `MATCH`.
* Bad, because LeanElpi must expose entry-point signatures and structured result terms (0.4).

## More Information

Recorded in the knowledge graph as [[decisions#Typed entry points and an untyped debug query]].
