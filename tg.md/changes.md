---
type: Change
status: proposed  # per section: see each status:: line
---
# Changes

The OpenSpec changes that build Marien, one per milestone, in build order. Each lives in `openspec/changes/<id>/` with its proposal, design, tasks and spec deltas.

## spike-lean-runtime-in-ladybug

Spike: load a Lean-runtime shared library into LadybugDB and call it from a worker thread, to measure size and symbol clashes before committing.

- status:: proposed

## add-leanelpi-host-api

M0: the LeanElpi 0.4 API Marien needs: entry-point signatures, structured result terms, resumable fuel and a public clause AST. Implemented in the lean-elpi repository.

- status:: proposed

## add-tracer-bullet

M1: the whole stack end to end: shim, single runtime, catalog to signature, `elpi_save`, untyped `elpi_query`, full-scope materialization and fuel slicing.

- status:: proposed

## add-typed-validation

M2: typed `elpi_run`, the `violation` protocol and `elpi_validate`, lazy recheck by schema hash, and distribution from Marien's extension server.

- status:: proposed

## add-analysis-and-partitioning

M3: rule analysis (reachability, monotonicity, dynamic, locality), narrowed scope, anchor and key partitions, structural facts and the differential property tests.

- status:: proposed

## add-higher-order-layer

M4: schema reflection and annotations, staged rule generation, dynamic entry points and the `graph.std` combinator library.

- status:: proposed

## add-ecosystem

M5: offline Lean codegen from the shared encoding, the Soufflé oracle, custom statements and the upstream proposals.

- status:: proposed
