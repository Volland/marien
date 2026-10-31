---
type: Component
openspec: [custom-statements, differential-testing, distribution, engine-host-api, extension-runtime, graph-std, offline-codegen, partitioning, rule-analysis, rule-execution, rule-generation, rule-storage, schema-encoding, schema-evolution, schema-reflection, validation]
---
# Components

One section per module or tool of Marien: what it owns, its source, the components it depends on, the decisions that shape it and the change that introduces it.

How they fit together is in [[architecture#Layers]]; flows are drawn in [[uml]].

## Extension shim

Registers Marien's table functions with LadybugDB and implements their bind, execute and rewriteFunc callbacks; owns no logic beyond marshalling. Source: `shim/extension.cpp`.

Exports only the extension init symbol; everything else is hidden so the bundled Lean runtime, GMP and libuv cannot clash with symbols of LadybugDB or other extensions.

- module:: shim/extension.cpp
- milestone:: Spike
- depends_on:: [[components#Runtime bridge]]
- motivated_by:: [[decisions#Logic in Lean behind a thin C++ shim]]
- motivated_by:: [[decisions#CALL functions first]]
- motivated_by:: [[constraints#Extensions are C++ shared libraries]]
- introduced_by:: [[changes#spike-lean-runtime-in-ladybug]]

## Runtime bridge

The C ABI between shim and Lean: runtime start-up, per-thread initialization, handles, UTF-8 strings and flat fact and row buffers. Source: `Marien/Ffi.lean`, `shim/lean_bridge.c`.

Follows LeanElpi's `ensure_thread` pattern: a thread-local flag calls `lean_initialize_thread` once per LadybugDB worker thread.

- module:: Marien.Ffi
- milestone:: Spike
- motivated_by:: [[decisions#Logic in Lean behind a thin C++ shim]]
- motivated_by:: [[constraints#One Lean runtime per process]]
- introduced_by:: [[changes#spike-lean-runtime-in-ladybug]]

## Catalog reader

Reads LadybugDB's catalog (node tables, rel tables, FROM/TO pairs, property types) into the schema JSON the Lean side consumes. Source: `shim/catalog.cpp`.

- module:: shim/catalog.cpp
- milestone:: M1
- depends_on:: [[components#Extension shim]]
- motivated_by:: [[decisions#Schema types at runtime and Lean inductives offline]]
- introduced_by:: [[changes#add-tracer-bullet]]

## Table scanner

Scans node and rel tables, or the neighbourhood of a batch of anchors, through LadybugDB's storage and graph API in the calling transaction. Source: `shim/scan.cpp`.

Neighbourhood scans (radius and directions from the analysis) arrive with partitioning in M3.

- module:: shim/scan.cpp
- milestone:: M1
- depends_on:: [[components#Extension shim]]
- motivated_by:: [[decisions#Scan tables in the calling transaction]]
- motivated_by:: [[decisions#Materialize facts per call]]
- introduced_by:: [[changes#add-tracer-bullet]]

## Schema model

The Lean schema datatype, its parser from catalog JSON, and the hash over the tables a module reaches. Source: `Marien/Schema.lean`.

The hash is a function of the reached tables only; that locality is a theorem, not a convention.

- module:: Marien.Schema
- milestone:: M1
- motivated_by:: [[decisions#Lazy recheck by schema hash]]
- motivated_by:: [[decisions#Proofs where practical]]
- introduced_by:: [[changes#add-tracer-bullet]]

## Signature generator

Turns a schema into an ELPI signature: one kind per node table with a primary-key constructor, one predicate per property, reified edge kinds and union endpoint kinds. Source: `Marien/Encoding/Signature.lean`.

`Signature.ofSchema` is the single encoding function shared with the offline codegen; `_elpi_*` tables are excluded by construction.

- module:: Marien.Encoding.Signature
- milestone:: M1
- depends_on:: [[components#Schema model]]
- motivated_by:: [[decisions#Predicate-per-property encoding]]
- motivated_by:: [[decisions#Schema types at runtime and Lean inductives offline]]
- introduced_by:: [[changes#add-tracer-bullet]]

## Value codec

Encodes LadybugDB values as ELPI terms and decodes result terms back into typed column values. Source: `Marien/Encoding/Codec.lean`.

`decode (encode v) = v` is proved for every supported property type.

- module:: Marien.Encoding.Codec
- milestone:: M1
- depends_on:: [[components#Signature generator]]
- motivated_by:: [[decisions#Predicate-per-property encoding]]
- motivated_by:: [[decisions#Proofs where practical]]
- introduced_by:: [[changes#add-tracer-bullet]]

## Module store

The save pipeline (stage, typecheck, analyse), the escaped Cypher that persists `_elpi_module` rows, and drop, export and import. Source: `Marien/Store/Module.lean`.

Source text is stored byte-exact; `unescape (escape s) = s` is proved.

- module:: Marien.Store.Module
- milestone:: M1
- depends_on:: [[components#Signature generator]]
- depends_on:: [[components#Handle cache]]
- motivated_by:: [[decisions#Rules stored in system tables]]
- motivated_by:: [[decisions#CALL functions first]]
- introduced_by:: [[changes#add-tracer-bullet]]

## Handle cache

In-memory cache of compiled LeanElpi programs keyed by module version and schema hash; never persisted. Source: `Marien/Store/Cache.lean`.

- module:: Marien.Store.Cache
- milestone:: M1
- depends_on:: [[components#Signature generator]]
- motivated_by:: [[decisions#Rules stored in system tables]]
- motivated_by:: [[decisions#Lazy recheck by schema hash]]
- introduced_by:: [[changes#add-tracer-bullet]]

## Executor

Runs queries and entry points: materializes facts, solves in fuel slices with interrupt, deadline and budget checks, and decodes rows. Source: `Marien/Exec/Run.lean`.

M1 ships the untyped `elpi_query`; M2 adds typed `elpi_run`; M3 adds narrowed scope for monotone entry points.

- module:: Marien.Exec.Run
- milestone:: M1
- depends_on:: [[components#Handle cache]]
- depends_on:: [[components#Value codec]]
- depends_on:: [[components#Table scanner]]
- motivated_by:: [[decisions#Fuel-sliced execution that fails loudly]]
- motivated_by:: [[decisions#Typed entry points and an untyped debug query]]
- motivated_by:: [[constraints#Out of fuel discards the search]]
- introduced_by:: [[changes#add-tracer-bullet]]

## Validator

Runs the `violation` protocol across modules and returns the uniform validation report, delegating large runs to the partition planner. Source: `Marien/Exec/Validate.lean`.

- module:: Marien.Exec.Validate
- milestone:: M2
- depends_on:: [[components#Executor]]
- motivated_by:: [[decisions#Validation protocol]]
- introduced_by:: [[changes#add-typed-validation]]

## Rule analyzer

Per entry point: reached predicates, monotonicity, dynamic inference and the locality check that permits anchor partitions. Source: `Marien/Analysis/`.

Soundness of monotonicity and locality is a stretch theorem; property tests guard it in v1.

- module:: Marien.Analysis
- milestone:: M3
- depends_on:: [[components#Signature generator]]
- motivated_by:: [[decisions#Closed-world scope]]
- motivated_by:: [[decisions#Partitioned validation]]
- motivated_by:: [[decisions#Staged rule generation over a reflected schema]]
- introduced_by:: [[changes#add-analysis-and-partitioning]]

## Partition planner

Chooses full, anchor or key partitioning from the analysis, batches anchors and drives one fresh store per batch. Source: `Marien/Exec/Partition.lean`.

Coverage (every anchor in exactly one batch) and single emission of each violation are theorems.

- module:: Marien.Exec.Partition
- milestone:: M3
- depends_on:: [[components#Rule analyzer]]
- depends_on:: [[components#Executor]]
- depends_on:: [[components#Table scanner]]
- depends_on:: [[components#Structural facts]]
- motivated_by:: [[decisions#Partitioned validation]]
- introduced_by:: [[changes#add-analysis-and-partitioning]]

## Structural facts

Computes SCC and WCC over rel tables in the calling transaction and hands them over as facts such as `in_cycle` and `component`. Source: `shim/structure.cpp`.

- module:: shim/structure.cpp
- milestone:: M3
- depends_on:: [[components#Table scanner]]
- motivated_by:: [[decisions#Partitioned validation]]
- motivated_by:: [[decisions#Scan tables in the calling transaction]]
- introduced_by:: [[changes#add-analysis-and-partitioning]]

## Schema reflector

Produces the monomorphic deep description of the schema and its annotations (`schema.node`, `schema.rel`, `schema.prop`, `schema.annot`) for meta-rules. Source: `Marien/Meta/Reflect.lean`.

- module:: Marien.Meta.Reflect
- milestone:: M4
- depends_on:: [[components#Schema model]]
- motivated_by:: [[decisions#Staged rule generation over a reflected schema]]
- motivated_by:: [[constraints#Clause type variables are rigid]]
- introduced_by:: [[changes#add-higher-order-layer]]

## Rule generator

Runs stage-1 meta-rules over the reflected schema and returns clause text for stage 2, which is typechecked and analysed like hand-written code. Source: `Marien/Meta/Stage.lean`.

- module:: Marien.Meta.Stage
- milestone:: M4
- depends_on:: [[components#Schema reflector]]
- depends_on:: [[components#Rule analyzer]]
- motivated_by:: [[decisions#Staged rule generation over a reflected schema]]
- introduced_by:: [[changes#add-higher-order-layer]]

## Graph standard library

The `graph.std` ELPI module: combinators such as `closure`, `acyclic`, `functional`, `symmetric` and `card`, polymorphic over relation predicates. Source: `lib/graph/std.elpi`.

- module:: lib/graph/std.elpi
- milestone:: M4
- motivated_by:: [[decisions#Predicate-per-property encoding]]
- motivated_by:: [[decisions#Staged rule generation over a reflected schema]]
- introduced_by:: [[changes#add-higher-order-layer]]

## Offline codegen

The `marien-codegen` Lake executable: reads a schema dump and emits a Lean module of inductives with `deriving Elpi`, using the same encoding as the runtime. Source: `Marien/Offline/Codegen.lean`.

- module:: Marien.Offline.Codegen
- milestone:: M5
- depends_on:: [[components#Signature generator]]
- motivated_by:: [[decisions#Schema types at runtime and Lean inductives offline]]
- introduced_by:: [[changes#add-ecosystem]]

## Test harness

Generators of random schemas, graphs and modules, the differential properties, end-to-end tests against an embedded LadybugDB and the Soufflé oracle. Source: `tests/`.

The Soufflé oracle arrives in M5.

- module:: tests
- milestone:: M3
- depends_on:: [[components#Executor]]
- depends_on:: [[components#Partition planner]]
- motivated_by:: [[decisions#Differential testing with an oracle]]
- introduced_by:: [[changes#add-analysis-and-partitioning]]

## Statement extension

Custom statements such as `CREATE RULES`, `CHECK RULES` and `VALIDATE` through LadybugDB's transformer, binder, planner and mapper pipeline, as syntax over the table functions. Source: `shim/statements.cpp`.

- module:: shim/statements.cpp
- milestone:: M5
- depends_on:: [[components#Extension shim]]
- motivated_by:: [[decisions#CALL functions first]]
- introduced_by:: [[changes#add-ecosystem]]
