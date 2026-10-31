---
type: Constraint
source: "per section: see each constraint's source:: line"
---
# Constraints

Facts nobody on this project chose: limits of LadybugDB, of LeanElpi and of the Lean runtime, plus the target scale. Each one forces one or more [[decisions]].

## Extensions are C++ shared libraries

LadybugDB loads extensions only as C++ shared libraries built against the exact database version that loads them; there is no stable extension ABI.

- source:: LadybugDB `src/include/extension/` and the `ladybugdb/extensions` build, checked 2026-10-31
- constrains:: [[decisions#Logic in Lean behind a thin C++ shim]]
- constrains:: [[decisions#Out-of-tree extension with its own repository]]

## Output columns are fixed at bind time

A LadybugDB table function declares its output columns and their types in its bind phase, before it executes.

- source:: `table_func_bind_t` in LadybugDB `src/include/function/table/table_function.h`
- constrains:: [[decisions#Typed entry points and an untyped debug query]]

## No DDL hooks for extensions

LadybugDB offers transformer, binder, planner, mapper and catalog extensions, but no event an extension can subscribe to when the schema changes.

- source:: LadybugDB `src/include/extension/`, checked 2026-10-31
- constrains:: [[decisions#Lazy recheck by schema hash]]

## Table functions can rewrite into Cypher

A standalone `CALL` may supply a `rewriteFunc` that turns its bind data into a Cypher statement, which is how an extension function can write without re-entering the database.

- source:: `table_func_rewrite_t` in LadybugDB `src/include/function/table/table_function.h:141`
- constrains:: [[decisions#CALL functions first]]
- constrains:: [[decisions#Rules stored in system tables]]

## Clause type variables are rigid

LeanElpi checks clauses against the declared type with its type variables rigid, so one polymorphic predicate cannot have clauses that each fix the variables differently.

- source:: lean-elpi `openspec/specs/elpi-typechecker/spec.md`, Requirement "Prenex polymorphism"
- constrains:: [[decisions#Staged rule generation over a reflected schema]]

## One Lean runtime per process

Each self-contained Lean shared library embeds `libleanrt`; loading two of them into one process gives two runtimes with separate global state.

- source:: lean-elpi `scripts/build-ffi.sh` and `openspec/changes/add-language-bindings/design.md`
- constrains:: [[decisions#Logic in Lean behind a thin C++ shim]]

## Out of fuel discards the search

In LeanElpi 0.3.3 `Step.outOfFuel` carries no machine, unlike `yield`, so a query that runs out of fuel cannot be resumed.

- source:: lean-elpi `Elpi/Core/Machine.lean:94`, release 0.3.3
- constrains:: [[decisions#Fuel-sliced execution that fails loudly]]
- constrains:: [[decisions#Milestone order]]

## LeanElpi memory grows in long runs

LeanElpi uses 50 to 200 MB on ELPI's benchmarks, and nothing reclaims unification variables during a long run.

- source:: lean-elpi README, "Performance and compatibility", release 0.3.3
- constrains:: [[decisions#Partitioned validation]]
- constrains:: [[decisions#Materialize facts per call]]

## Target scale is 1M to 100M facts

Validation rules are expected to reach tables holding between one and one hundred million facts.

- source:: design interview, 2026-10-31
- constrains:: [[decisions#Partitioned validation]]
- constrains:: [[decisions#Milestone order]]
