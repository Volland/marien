---
type: Component
openspec: [custom-statements, differential-testing, distribution, engine-host-api, extension-runtime, graph-std, offline-codegen, partitioning, rule-analysis, rule-execution, rule-generation, rule-storage, schema-encoding, schema-evolution, schema-reflection, validation]
---
# Components

One section per module or tool of Marien: what it owns, its source, the components it depends on, the decisions that shape it and the change that introduces it.

How they fit together is in [[architecture#Layers]]; flows are drawn in [[uml]].

## Extension shim

Registers Marien's table functions with LadybugDB and implements their bind, execute and rewriteFunc callbacks; owns no logic beyond marshalling. Source: `shim/extension.cpp`.

Exports only the loader entry points `init` and `name`; everything else is hidden so the bundled Lean runtime, GMP and libuv cannot clash with symbols of LadybugDB or other extensions. Compiled with the platform's system C++ compiler against the pinned LadybugDB headers plus the CMake-generated ones (`shim/CMakeLists.txt`, checking the LadybugDB tag), and linked by `scripts/link-extension.sh`. Prototype: `spike/shim.cpp`.

Registers `elpi_init`, `elpi_save`, `elpi_drop`, `elpi_import` and `elpi_recheck` as standalone functions whose bind asks Lean for the statements and whose `rewriteFunc` returns them; `elpi_export`, `elpi_signature`, `elpi_query`, `elpi_run` and `elpi_validate` as table functions; and the options `elpi_fuel`, `elpi_timeout_ms`, `elpi_max_solutions`, `elpi_max_facts`, `elpi_slice_steps` and `elpi_cache_size`. Integration tests: `tests/integration/integration.c`.

`elpi_run` takes its parameters as a STRUCT or MAP literal and declares its columns at bind from the types Lean reports; rows arrive as typed prefix tokens and become LadybugDB values (integers range-checked against the column type). `elpi_validate` runs every module to the end before it returns a row. On load, `init` refuses a LadybugDB release other than the pinned one before it registers anything. Built from a clean checkout by `scripts/build-extension.sh`; released by `.github/workflows/release.yml` over `scripts/release-matrix.sh`.

- module:: shim/extension.cpp
- milestone:: Spike
- depends_on:: [[components#Runtime bridge]]
- motivated_by:: [[decisions#Logic in Lean behind a thin C++ shim]]
- motivated_by:: [[decisions#CALL functions first]]
- motivated_by:: [[constraints#Extensions are C++ shared libraries]]
- motivated_by:: [[decisions#One rewritten statement per write]]
- motivated_by:: [[decisions#Explicit elpi_init]]
- motivated_by:: [[decisions#Version check by release, else by storage version]]
- motivated_by:: [[decisions#Releases built from one matrix script]]
- introduced_by:: [[changes#spike-lean-runtime-in-ladybug]]
- changed_by:: [[changes#add-typed-validation]] {note: "elpi_run, elpi_validate, elpi_recheck, the version check and the release build"}
- changed_by:: [[changes#add-analysis-and-partitioning]] {note: "scope overloads, the narrowed column, elpi_partition_batch, runTyped"}

## Runtime bridge

The C ABI between shim and Lean: runtime start-up, per-thread initialization, handles, UTF-8 strings and flat fact and row buffers. Source: `Marien/Ffi.lean`, `shim/lean_bridge.c`.

The Lean entry points (`Marien/Ffi.lean`) take and return strings, string arrays, value arrays and opaque handles; `shim/lean_bridge.h` turns them into a plain C API whose symbols all start with `marien_bridge_`, the only Lean-side symbols the Linux link keeps global. Follows LeanElpi's `ensure_thread` pattern: a thread-local flag calls `lean_initialize_thread` once per LadybugDB worker thread. Starts the runtime once per process under `pthread_once`, and defines a runtime-only `lean_initialize` so the Lean compiler package is never linked. Prototype: `spike/bridge.c`. The Lean side calls LeanElpi only through its `Elpi.Host` module (signatures, goals from terms, fuel slices, facts as terms, clause AST).

- module:: Marien.Ffi
- milestone:: Spike
- motivated_by:: [[decisions#Logic in Lean behind a thin C++ shim]]
- motivated_by:: [[constraints#One Lean runtime per process]]
- motivated_by:: [[decisions#Runtime-only Lean initialization]]
- motivated_by:: [[decisions#Catalog as JSON, rows as column batches]]
- changed_by:: [[changes#add-tracer-bullet]]
- introduced_by:: [[changes#spike-lean-runtime-in-ladybug]]

## Engine contract

The one module through which Marien calls LeanElpi: it wraps LeanElpi's `Elpi.Host` façade. Source: `Marien/Engine.lean`; contract tests: `tests/EngineContract.lean` (`lake test`).

- module:: Marien.Engine
- milestone:: M0
- motivated_by:: [[decisions#Call LeanElpi only through its host façade]]
- motivated_by:: [[decisions#LeanElpi is the engine]]
- introduced_by:: [[changes#add-leanelpi-host-api]]

## Catalog reader

Reads LadybugDB's catalog (node tables, rel tables, FROM/TO pairs, property types) into the schema JSON the Lean side consumes. Source: `shim/catalog.cpp`.

- module:: shim/catalog.cpp
- milestone:: M1
- depends_on:: [[components#Extension shim]]
- motivated_by:: [[decisions#Schema types at runtime and Lean inductives offline]]
- motivated_by:: [[decisions#Catalog as JSON, rows as column batches]]
- introduced_by:: [[changes#add-tracer-bullet]]

## Table scanner

Scans node and rel tables, or the neighbourhood of a batch of anchors, through LadybugDB's storage and graph API in the calling transaction. Source: `shim/scan.cpp`.

Node tables are scanned with `NodeTableScanState` a vector at a time; rel tables through `graph::OnDiskGraph`, with each endpoint's primary keys gathered by offset first. M3: a `RowFilter` restricts which node rows are read, and an edge is read only between allowed endpoints; `neighbourhood` walks the recorded directions breadth first from a batch of anchors, `scopeFilter` turns a narrowed scope into a filter, and `edgeOffsets` feeds the structural facts.

- module:: shim/scan.cpp
- milestone:: M1
- depends_on:: [[components#Extension shim]]
- motivated_by:: [[decisions#Scan tables in the calling transaction]]
- motivated_by:: [[decisions#Materialize facts per call]]
- motivated_by:: [[decisions#Catalog as JSON, rows as column batches]]
- motivated_by:: [[decisions#Edge ids are internal ids]]
- introduced_by:: [[changes#add-tracer-bullet]]
- changed_by:: [[changes#add-analysis-and-partitioning]] {note: "row filters, neighbourhoods, scopes"}

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

Every signature starts with the validation protocol's `severity` and `subject` kinds, and each table adds its `subj_<table>` constructor; the protocol's names take part in the injectivity check. `tableOf?` maps any generated identifier back to its table, for the reached-table set.

- module:: Marien.Encoding.Signature
- milestone:: M1
- depends_on:: [[components#Schema model]]
- motivated_by:: [[decisions#Predicate-per-property encoding]]
- motivated_by:: [[decisions#Schema types at runtime and Lean inductives offline]]
- motivated_by:: [[decisions#Snake-case names with a collision check]]
- motivated_by:: [[decisions#Constructor and node predicate share the table name]]
- motivated_by:: [[decisions#Subject as a generated union kind]]
- introduced_by:: [[changes#add-tracer-bullet]]
- changed_by:: [[changes#add-typed-validation]] {note: "protocol declarations and subject constructors"}
- motivated_by:: [[decisions#Generated predicates are indexed to depth 2]]
- changed_by:: [[changes#add-analysis-and-partitioning]] {note: "structural predicates and index declarations"}

## Value codec

Encodes LadybugDB values as ELPI terms and decodes result terms back into typed column values. Source: `Marien/Encoding/Codec.lean`.

`decode (encode v) = v` is proved for every supported property type.

M2 adds the column codec of typed entry points (`Col`: scalars, lists, records, node kinds as primary keys, edge kinds as internal ids) with `value_roundtrip` and `decodeC_sound`, and the subject codec with `subject_decode_encode` and `subject_encode_decode`.

- module:: Marien.Encoding.Codec
- milestone:: M1
- depends_on:: [[components#Signature generator]]
- motivated_by:: [[decisions#Predicate-per-property encoding]]
- motivated_by:: [[decisions#Proofs where practical]]
- motivated_by:: [[decisions#Columns of typed entry points come from the predicate signature]]
- motivated_by:: [[decisions#Subject as a generated union kind]]
- introduced_by:: [[changes#add-tracer-bullet]]
- changed_by:: [[changes#add-typed-validation]] {note: "column and subject codecs"}

## Module store

The save pipeline (stage, typecheck, analyse), the escaped Cypher that persists `_elpi_module` rows, and drop, export and import. Source: `Marien/Store/Module.lean`.

Source text is stored byte-exact; `unescape (escape s) = s` and the absence of a bare delimiter are proved over a model of LadybugDB's string-literal lexer (`Marien/Store/Literal.lean`).

- module:: Marien.Store.Module
- milestone:: M1
- depends_on:: [[components#Signature generator]]
- depends_on:: [[components#Handle cache]]
- motivated_by:: [[decisions#Rules stored in system tables]]
- motivated_by:: [[decisions#CALL functions first]]
- motivated_by:: [[decisions#One rewritten statement per write]]
- motivated_by:: [[decisions#A module reaches what its accumulated modules reach]]
- motivated_by:: [[decisions#Runs recompile in memory; only elpi_recheck writes]]
- introduced_by:: [[changes#add-tracer-bullet]]
- changed_by:: [[changes#add-typed-validation]] {note: "reached tables and hash, the violation signature check, status and error, elpi_recheck"}
- changed_by:: [[changes#add-analysis-and-partitioning]] {note: "the rule analyzer at save and recheck, verdicts in derived"}
- changed_by:: [[changes#add-higher-order-layer]] {note: "stage 1 in check, generated text in _elpi_module.generated, _elpi_annotation and elpi_annotate, graph.std as a library"}

## Handle cache

In-memory LRU cache of compiled LeanElpi programs keyed by module version and source, schema hash and the sources of accumulated modules; never persisted. Source: `Marien/Store/Cache.lean`.

From M2 the schema hash in the key is the module's reached-table hash, so DDL on tables a module does not reach keeps its entry, and DDL on one it reaches compiles it anew.

- module:: Marien.Store.Cache
- milestone:: M1
- depends_on:: [[components#Signature generator]]
- motivated_by:: [[decisions#Rules stored in system tables]]
- motivated_by:: [[decisions#Lazy recheck by schema hash]]
- motivated_by:: [[decisions#Handle cache keyed by source hashes]]
- introduced_by:: [[changes#add-tracer-bullet]]
- changed_by:: [[changes#add-typed-validation]] {note: "keyed by the reached-table hash"}
- changed_by:: [[changes#add-higher-order-layer]] {note: "staged modules key on the whole-schema hash, which determines their generated text"}

## Executor

Runs queries and entry points: materializes facts, solves in fuel slices with interrupt, deadline and budget checks, and decodes rows. Source: `Marien/Exec/Run.lean`.

M1 ships the untyped `elpi_query`; M2 adds typed `elpi_run` (`prepareRun`, `bindArgs`, `startGoal`), one module of `elpi_validate` (`prepareValidate`) and the lazy recheck (`compiledFor`); M3: each entry point loads the tables its verdict says it reaches (`reachedBy`); `checkScope` refuses a scope at bind time unless the entry point is monotone; a partitioned session solves batch by batch, each in a fresh store, keeping rows whose subject is a batch anchor (`Session.forBatch`, `keeps`).

- module:: Marien.Exec.Run
- milestone:: M1
- depends_on:: [[components#Handle cache]]
- depends_on:: [[components#Value codec]]
- depends_on:: [[components#Table scanner]]
- motivated_by:: [[decisions#Fuel-sliced execution that fails loudly]]
- motivated_by:: [[decisions#Typed entry points and an untyped debug query]]
- motivated_by:: [[constraints#Out of fuel discards the search]]
- motivated_by:: [[decisions#Debug queries load the tables their goal names]]
- motivated_by:: [[decisions#Columns of typed entry points come from the predicate signature]]
- motivated_by:: [[decisions#Runs recompile in memory; only elpi_recheck writes]]
- introduced_by:: [[changes#add-tracer-bullet]]
- changed_by:: [[changes#add-typed-validation]] {note: "elpi_run, elpi_validate sessions, lazy recheck"}
- motivated_by:: [[decisions#The subject is the anchor]]
- changed_by:: [[changes#add-analysis-and-partitioning]] {note: "verdict-driven scans, scope check, partitioned sessions"}

## Validator

Runs the `violation` protocol across modules and returns the uniform validation report, delegating large runs to the partition planner. Source: `Marien/Exec/Validate.lean`.

M2: `validationOrder` picks the listed modules that declare `violation` (all, by name, when the list is omitted), `reportRow` decodes a solution with the subject codec and asks `violation_message` for the message, and `keep` applies the severity threshold (`filter_sound`). Every module runs at full scope; a failing one fails the call.

M3: a module whose `violation` has an accepted partition runs batch by batch; a scope is refused unless `violation` is monotone, and rows on a scope carry `narrowed = true`.

- module:: Marien.Exec.Validate
- milestone:: M2
- depends_on:: [[components#Executor]]
- motivated_by:: [[decisions#Validation protocol]]
- motivated_by:: [[decisions#Subject as a generated union kind]]
- introduced_by:: [[changes#add-typed-validation]]
- changed_by:: [[changes#add-analysis-and-partitioning]] {note: "partitioned and narrowed runs"}

## Rule analyzer

Per entry point: reached predicates, monotonicity, dynamic inference and the locality check that permits anchor partitions. Source: `Marien/Analysis/`.

Soundness of monotonicity and locality is proved over an abstract semantics of the analysed fragment (`Semantics`: `monotone_sound`, `locality_sound`, `static_independent`); the property tests check the real engine.

`Reach` builds the call graph (variable calls over-approximated by type) and its closure (`reach_closed`); `Monotone` finds the first `not`, cut, `forall` or `findall` over the database and the `=>` goals that make an entry point dynamic; `Locality` inlines helpers and checks anchor and key partitions; `Verdict` stores the result with the module.

- module:: Marien.Analysis
- milestone:: M3
- depends_on:: [[components#Signature generator]]
- motivated_by:: [[decisions#Closed-world scope]]
- motivated_by:: [[decisions#Partitioned validation]]
- motivated_by:: [[decisions#Staged rule generation over a reflected schema]]
- introduced_by:: [[changes#add-analysis-and-partitioning]]
- motivated_by:: [[decisions#Analysis on the clause AST at save and recheck]]
- motivated_by:: [[decisions#Locality by inlining, conservatively]]
- motivated_by:: [[decisions#Rejected partitions fail the save]]

## Partition planner

Chooses full, anchor or key partitioning from the analysis, batches anchors and drives one fresh store per batch. Source: `Marien/Exec/Partition.lean`.

Coverage (every anchor in exactly one batch) and single emission of each violation are theorems.

`batches` and `bucketOf` are the code the shim calls (`marien_partition_batches`, `marien_partition_buckets`). The shim's `runTyped` drives the batches with a fresh store, fuel, fact budget and deadline each, splits a batch that overflows `elpi_max_facts` down to one anchor and names a failing batch.

- module:: Marien.Exec.Partition
- milestone:: M3
- depends_on:: [[components#Rule analyzer]]
- depends_on:: [[components#Executor]]
- depends_on:: [[components#Table scanner]]
- depends_on:: [[components#Structural facts]]
- motivated_by:: [[decisions#Partitioned validation]]
- introduced_by:: [[changes#add-analysis-and-partitioning]]
- motivated_by:: [[decisions#Batches and buckets are cut in Lean]]
- motivated_by:: [[decisions#The subject is the anchor]]

## Structural facts

Computes SCC and WCC over rel tables in the calling transaction and hands them over as facts such as `in_cycle` and `component`. Source: `shim/structure.cpp`.

Tarjan's algorithm (without recursion) gives `in_cycle` (a component with another node, or a self-edge); union-find gives `component`, numbered in the order of each component's first row. Only rows the call's filter allows become facts.

- module:: shim/structure.cpp
- milestone:: M3
- depends_on:: [[components#Table scanner]]
- motivated_by:: [[decisions#Partitioned validation]]
- motivated_by:: [[decisions#Scan tables in the calling transaction]]
- introduced_by:: [[changes#add-analysis-and-partitioning]]
- motivated_by:: [[decisions#Structural facts from Marien's own graph routines]]

## Schema reflector

Produces the monomorphic deep description of the schema and its annotations (`schema.node`, `schema.rel`, `schema.prop`, `schema.annot`) for meta-rules. Source: `Marien/Meta/Reflect.lean`.

`ofSchema` renders facts of the visible schema (`schema.key`, `schema.ident` and `schema.prop_ident` too) and sorts them; `ofSchema_no_system` and `ofSchema_perm` prove that no `_elpi_*` table appears and that catalog order does not matter.

- module:: Marien.Meta.Reflect
- milestone:: M4
- depends_on:: [[components#Schema model]]
- motivated_by:: [[decisions#Staged rule generation over a reflected schema]]
- motivated_by:: [[constraints#Clause type variables are rigid]]
- introduced_by:: [[changes#add-higher-order-layer]]

## Rule generator

Runs stage-1 meta-rules over the reflected schema and returns clause text for stage 2, which is typechecked and analysed like hand-written code. Source: `Marien/Meta/Stage.lean`.

`split` cuts the `% @marien meta` section out of a source, `generate` runs `generate S` under fuel and the byte cap and concatenates its solutions, `checkHeads` refuses clauses for undeclared predicates and `locate` traces an error in generated text to its solution. The [[components#Module store]] calls it from `check`, so save, recheck, import and the lazy recheck of a run all generate the same way.

- module:: Marien.Meta.Stage
- milestone:: M4
- depends_on:: [[components#Schema reflector]]
- depends_on:: [[components#Rule analyzer]]
- motivated_by:: [[decisions#Staged rule generation over a reflected schema]]
- motivated_by:: [[decisions#Meta-rules in a marked section of the module]]
- motivated_by:: [[decisions#Stage one is bounded by fuel and size, never by a clock]]
- motivated_by:: [[decisions#Generated clauses only for declared predicates]]
- introduced_by:: [[changes#add-higher-order-layer]]

## Graph standard library

The `graph.std` ELPI module: combinators such as `closure`, `acyclic`, `functional`, `symmetric` and `card`, polymorphic over relation predicates. Source: `lib/graph/std.elpi`.

Built in with `include_str` (`Marien/Meta/GraphStd.lean`); its answer sets equal Lean references on random relations (`tests/GraphStd/`), and its locality claims are tested against the analysis.

- module:: lib/graph/std.elpi
- milestone:: M4
- motivated_by:: [[decisions#Predicate-per-property encoding]]
- motivated_by:: [[decisions#Staged rule generation over a reflected schema]]
- motivated_by:: [[decisions#graph.std is built into the extension]]
- motivated_by:: [[decisions#Combinators take the node predicate where they enumerate nodes]]
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

M3: `tests/M3.lean` covers the analyzer and the planner; `tests/Property/` holds the seeded generator, its unit tests and the Lean model that measures rejections; `tests/differential/` runs partition equivalence and narrowing against an embedded LadybugDB.

- module:: tests
- milestone:: M3
- depends_on:: [[components#Executor]]
- depends_on:: [[components#Partition planner]]
- motivated_by:: [[decisions#Differential testing with an oracle]]
- introduced_by:: [[changes#add-analysis-and-partitioning]]
- motivated_by:: [[decisions#Differential properties with a Lean generator and a C runner]]

## Statement extension

Custom statements such as `CREATE RULES`, `CHECK RULES` and `VALIDATE` through LadybugDB's transformer, binder, planner and mapper pipeline, as syntax over the table functions. Source: `shim/statements.cpp`.

- module:: shim/statements.cpp
- milestone:: M5
- depends_on:: [[components#Extension shim]]
- motivated_by:: [[decisions#CALL functions first]]
- introduced_by:: [[changes#add-ecosystem]]
