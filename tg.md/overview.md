---
type: Concept
---
# Overview

Marien is a LadybugDB extension written in Lean 4 that stores λProlog programs in the database and runs them with LeanElpi to reason about and validate the graph.

Types come from the graph schema, rules can be higher-order and can quantify over the schema, and every guarantee about answers is enforced by a static check. The choices are in [[decisions]], the forces behind them in [[constraints]], the structure in [[architecture]] and the milestones in [[changes]].

## Schema encoding

The schema becomes an ELPI signature: one kind per node table, one predicate per property, reified edges and node terms named by primary key.

- defines:: [[decisions#Predicate-per-property encoding]]

## Closed-world scope

A run sees exactly the facts it loaded, so negation, cut and `forall` are only sound when every fact the rules can reach was loaded.

- defines:: [[decisions#Closed-world scope]]
- defines:: [[decisions#Partitioned validation]]

## Open questions

Points the design interview of 2026-10-31 left open; each needs an answer before the milestone that depends on it.

- Whether LadybugDB will accept upstream patches for DDL hooks and for hosting the extension.
