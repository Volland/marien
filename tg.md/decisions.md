---
type: Decision
status: accepted  # per section: see each status:: line
date: 2026-10-31
owner: Volodymyr Pavlyshyn
specs: ["adr:0023", "adr:0022", "adr:0001", "adr:0002", "adr:0003", "adr:0004", "adr:0005", "adr:0006", "adr:0007", "adr:0008", "adr:0009", "adr:0010", "adr:0011", "adr:0012", "adr:0013", "adr:0014", "adr:0015", "adr:0016", "adr:0017", "adr:0018", "adr:0019", "adr:0020", "adr:0021"]
---
# Decisions

The architecture decisions of Marien from the design interview of 2026-10-31, one section per decision, each with its status and the [[constraints]] or earlier decisions that motivate it.

Each has a long-form MADR record in `docs/adr/` with the options considered; the components it shapes are in [[components]].

## LeanElpi is the engine

Rules run on LeanElpi, the native Lean 4 implementation of the ELPI dialect of λProlog, not on upstream OCaml ELPI over FFI.

**Context.** Upstream ELPI would put the OCaml runtime next to Lean and C++ in one database process, and schema types would end at a string boundary. **Consequences.** Marien depends on LeanElpi releases and can ask for engine changes in the same hands.

Record: [ADR 0002](../docs/adr/0002-leanelpi-is-the-engine.md).

- status:: accepted

## Materialize facts per call

A run turns the database rows it needs into ELPI facts and loads them with the stored rules; the engine never calls back into LadybugDB.

**Context.** Builtins that read the database lazily would re-enter it while a function call holds its transaction state. **Consequences.** A run is a pure function of rules, scope and parameters, so it can be cached, replayed and compared; memory bounds how much one run can load.

Record: [ADR 0003](../docs/adr/0003-materialize-facts-per-call.md).

- status:: accepted
- motivated_by:: [[constraints#LeanElpi memory grows in long runs]] {weight: secondary}

## Schema types at runtime and Lean inductives offline

Inside the database the schema becomes a generated ELPI signature, checked when rules are saved; an optional offline tool turns the same schema into Lean inductives for proofs.

**Context.** The FFI path typechecks pure ELPI with no Lean `Environment`, and loading `.olean` files into the database is too heavy. **Consequences.** One pure Lean function from schema to signature serves both sides, so a rule proved offline is the rule that runs.

Record: [ADR 0004](../docs/adr/0004-schema-types-at-runtime-and-lean-inductives-offline.md).

- status:: accepted
- motivated_by:: [[decisions#LeanElpi is the engine]]

## Predicate-per-property encoding

Each node table is a kind with a primary-key constructor, each property a predicate, and each rel table a predicate over a reified edge kind with one predicate per edge property.

**Context.** Record terms break every rule when a column is added, and a generic triple store loses the types. **Consequences.** Nulls are absent facts, schema additions keep old rules well-typed, multigraphs work, and relations are ordinary predicates that higher-order rules can take as arguments. Rel tables with several FROM/TO pairs get a union endpoint kind; LIST maps to `list`, STRUCT to a generated record kind, DATE and TIMESTAMP to epoch `int`, other types are skipped with a warning.

Record: [ADR 0005](../docs/adr/0005-predicate-per-property-encoding.md).

- status:: accepted
- motivated_by:: [[decisions#Schema types at runtime and Lean inductives offline]]

## Rules stored in system tables

Modules live in `_elpi_module` rows with their source text as written, derived metadata beside it, and `accumulate` dependencies as `_elpi_accumulates` edges.

**Context.** Files drift from the database and cannot share a transaction with schema changes; clause-level storage loses comments and clause order. **Consequences.** Rules travel with backups and are queryable by Cypher; `_elpi_*` tables are left out of the generated signature; compiled handles are cached in memory by module version and schema hash, never stored; `elpi_export` and `elpi_import` give a git round trip.

Record: [ADR 0006](../docs/adr/0006-rules-stored-in-system-tables.md).

- status:: accepted
- motivated_by:: [[constraints#Table functions can rewrite into Cypher]]

## Read-only runs

Running rules never writes to the graph; results are rows, and callers who want inferred facts in the graph compose the call with Cypher `MERGE`.

**Context.** LadybugDB's grammar allows an in-query `CALL` followed by updating clauses. **Consequences.** Runs stay pure. A later `elpi_materialize` procedure with provenance-tagged derived edges is a separate design.

Record: [ADR 0007](../docs/adr/0007-read-only-runs.md).

- status:: accepted
- motivated_by:: [[decisions#Materialize facts per call]]

## Typed entry points and an untyped debug query

`elpi_run` calls a declared predicate: `i:` arguments come from a parameter map, `o:` arguments become typed columns. `elpi_query` runs any goal and returns untyped rows.

**Context.** Output columns must be known at bind time, and the 0.3.3 C API reports bindings as printed strings. **Consequences.** LeanElpi needs a Lean API for entry-point signatures and structured result terms. Node results come back as primary keys, rehydrated with `MATCH`.

Record: [ADR 0008](../docs/adr/0008-typed-entry-points-and-an-untyped-debug-query.md).

- status:: accepted
- motivated_by:: [[constraints#Output columns are fixed at bind time]] {weight: primary}

## Closed-world scope

By default a run loads every table its entry point can reach, in full; a narrowed scope is allowed only for entry points proved monotone in the database predicates.

**Context.** Negation as failure, cut and `forall` over a partial scope report missing data as absence. **Consequences.** Module save records, per entry point, which generated predicates it reaches and whether any use sits under negation, cut or `forall`.

Record: [ADR 0009](../docs/adr/0009-closed-world-scope.md).

- status:: accepted
- motivated_by:: [[decisions#Materialize facts per call]]

## Staged rule generation over a reflected schema

Meta-rules run at save time and on schema change over a monomorphic description of the schema and its annotations, and emit clause text that is checked like hand-written code.

**Context.** A single polymorphic `schema.rel` cannot typecheck, and clauses created during a run escape the static checks. **Consequences.** Generated code depends only on the schema hash and is stored for inspection. Entry points that add clauses for database predicates with `=>` at run time are inferred `dynamic`; dynamic entry points run at full scope only and are never partitioned. Annotations live in a `_elpi_annotation` table; `graph.std` supplies combinators such as `closure`, `acyclic` and `functional`.

Built in M4 (`Marien/Meta/`): the description carries `schema.ident` and `schema.prop_ident`, the shallow predicates a meta-rule writes into clause text, and stage 2 loads the generated text as its own unit after the module's clauses.

Record: [ADR 0010](../docs/adr/0010-staged-rule-generation-over-a-reflected-schema.md).

- status:: accepted
- motivated_by:: [[constraints#Clause type variables are rigid]] {weight: primary}
- motivated_by:: [[decisions#Closed-world scope]]

## Lazy recheck by schema hash

Each module stores a hash of the tables it reaches; a run whose hash differs regenerates and rechecks the module in memory, and `elpi_recheck` revalidates everything and persists the result.

**Context.** There is no DDL hook. **Consequences.** Unrelated DDL never invalidates a module; a module that fails the recheck errors and is marked `broken`, with no fallback to stale generated code. An upstream DDL hook for eager checks was proposed and declined (LadybugDB/ladybug#1518, 2026-11-07), so this is the only path: it is correct for every snapshot, which an asynchronous WAL tailer would not be.

Record: [ADR 0011](../docs/adr/0011-lazy-recheck-by-schema-hash.md).

- status:: accepted
- motivated_by:: [[constraints#No DDL hooks for extensions]] {weight: primary}

## CALL functions first

The interface is a set of table functions (`elpi_save`, `elpi_run`, `elpi_query`, `elpi_validate`, `elpi_recheck`, `elpi_annotate`, `elpi_signature`, lifecycle calls); custom statements come later as syntax over them.

**Context.** Custom statements tie the extension to LadybugDB parser internals. **Consequences.** Writes go through `rewriteFunc`, which embeds module source in generated Cypher, so escaping is a correctness concern and save-then-export must return identical bytes.

Record: [ADR 0012](../docs/adr/0012-call-functions-first.md).

- status:: accepted
- motivated_by:: [[constraints#Table functions can rewrite into Cypher]] {weight: primary}

## Logic in Lean behind a thin C++ shim

Encoding, staging, analysis, decoding and the handle cache are Lean code in a `marien` package; a thin C++ shim implements LadybugDB's interfaces, and both link with LeanElpi into one shared library.

**Context.** Logic written in C++ would duplicate the encoding that offline codegen must share. **Consequences.** The published `libleanelpi` is not linked; LeanElpi is linked statically, symbols are hidden except the init entry point, and each foreign thread is initialized once as in LeanElpi's `ensure_thread`.

Record: [ADR 0013](../docs/adr/0013-logic-in-lean-behind-a-thin-c-shim.md).

- status:: accepted
- motivated_by:: [[constraints#One Lean runtime per process]] {weight: primary}
- motivated_by:: [[constraints#Extensions are C++ shared libraries]]
- motivated_by:: [[decisions#Schema types at runtime and Lean inductives offline]]

## Fuel-sliced execution that fails loudly

The shim runs the machine in fuel slices and checks LadybugDB's interrupt flag and a deadline between slices; running out of fuel, time or fact budget is an error, never a truncated result.

**Context.** A run that stops early and reports no violations is the worst lie a validator can tell. **Consequences.** LeanElpi must let a query resume after a slice. One call is single-threaded; limits are the options `elpi_fuel`, `elpi_timeout_ms`, `elpi_max_solutions` and `elpi_max_facts`.

Record: [ADR 0014](../docs/adr/0014-fuel-sliced-execution-that-fails-loudly.md).

- status:: accepted
- motivated_by:: [[constraints#Out of fuel discards the search]]

## Validation protocol

A module that defines `violation` of severity, code text and a generated `subject` union takes part in `elpi_validate`, which returns one uniform report across modules.

**Context.** Validation needs one entry point and one report shape for CI. **Consequences.** Violations stay typed in rules and become uniform columns at the boundary. Since most validation uses negation, it runs at full scope or partitioned.

Record: [ADR 0015](../docs/adr/0015-validation-protocol.md).

- status:: accepted
- motivated_by:: [[decisions#Typed entry points and an untyped debug query]]

## Partitioned validation

Large validations run in partitions: anchor partitions with a static locality check, key partitions for uniqueness rules, and global facts precomputed with LadybugDB's algo extension.

**Context.** Full scope over 1M to 100M facts does not fit one LeanElpi store. **Consequences.** An anchor partition declares an anchor kind and radius; every database atom must be guarded by the anchor within that radius, and each violation's subject must be the anchor so overlaps do not double-count. Each batch gets a fresh store. Structure such as cycles and components comes from SCC and WCC computed in the calling transaction and loaded as facts, so it is never stale.

Record: [ADR 0016](../docs/adr/0016-partitioned-validation.md).

- status:: accepted
- motivated_by:: [[constraints#Target scale is 1M to 100M facts]] {weight: primary}
- motivated_by:: [[constraints#LeanElpi memory grows in long runs]]
- motivated_by:: [[decisions#Closed-world scope]]
- motivated_by:: [[decisions#Scan tables in the calling transaction]]

## Out-of-tree extension with its own repository

Marien lives in its own repository, pinned to a LadybugDB version, and is served from its own extension server ([[decisions#Install by download until INSTALL accepts third-party names]]); contributing it to `ladybugdb/extensions` is proposed once stable.

**Context.** Upstream builds with CMake and has no Lean toolchain. **Consequences.** CI builds a matrix of LadybugDB version, OS and CPU. The spike measured 2.7 MB uncompressed and 0.8 MB gzipped on macOS arm64 with dead-stripping, and no symbol clashes with other extensions.

Record: [ADR 0017](../docs/adr/0017-out-of-tree-extension-with-its-own-repository.md).

- status:: accepted
- motivated_by:: [[constraints#Extensions are C++ shared libraries]]

## Differential testing with an oracle

Tests check the guarantees directly with random schemas, graphs and modules, and compare a first-order stratified subset of rules against Soufflé.

**Context.** Every correctness guarantee rests on a static analysis that can be wrong. **Consequences.** Required properties: partitioned equals full scope, narrowed scope is a subset of full scope, rejected modules have counterexamples, generation depends only on the schema hash, the encoding and save round-trip, and offline and runtime signatures agree.

Record: [ADR 0018](../docs/adr/0018-differential-testing-with-an-oracle.md).

- status:: accepted
- motivated_by:: [[decisions#Closed-world scope]]
- motivated_by:: [[decisions#Partitioned validation]]

## Milestone order

Build a linking spike, then LeanElpi 0.4, the tracer bullet, typed validation, analysis and scale, the higher-order layer, and the ecosystem work, in that order.

**Context.** Linking a Lean runtime into LadybugDB is the likeliest failure, and nothing validates at the target scale before partitioning exists. **Consequences.** Analysis and partitioning (M3) come before staging (M4), which reuses that analysis. LeanElpi 0.4 must ship entry-point signatures, structured terms, resumable fuel and a public clause AST.

Record: [ADR 0019](../docs/adr/0019-milestone-order.md).

- status:: accepted
- motivated_by:: [[constraints#Target scale is 1M to 100M facts]]
- motivated_by:: [[constraints#Out of fuel discards the search]]

## Proofs where practical

Lean code proves properties that are total statements over inductive data and have small proofs; operational behaviour of the engine is covered by property tests.

**Context.** Codec round-trips, name injectivity, exclusion of `_elpi_*` tables, hash determinism and partition coverage would otherwise rot silently. **Consequences.** Every design lists its key properties as proved (theorem and file) or tested (with the reason). Soundness of the monotonicity and locality checks is proved over an abstract semantics ([[decisions#Analysis soundness over an abstract Horn semantics]]); property tests check the engine itself.

Record: [ADR 0020](../docs/adr/0020-proofs-where-practical.md).

- status:: accepted
- motivated_by:: [[decisions#Logic in Lean behind a thin C++ shim]]
- motivated_by:: [[decisions#Differential testing with an oracle]]

## Scan tables in the calling transaction

Materialization, partition neighbourhoods and structural facts read tables through LadybugDB's storage and graph API in the transaction of the calling function, as the algo extension does, never through nested Cypher.

**Context.** A function call cannot safely issue nested queries, and facts computed by separate statements can be stale. **Consequences.** Every run sees one consistent snapshot and SCC or WCC facts are never stale; the shim depends on internal storage APIs that change between LadybugDB versions.

Record: [ADR 0021](../docs/adr/0021-scan-tables-in-the-calling-transaction.md).

- status:: accepted
- motivated_by:: [[decisions#Materialize facts per call]] {weight: primary}
- motivated_by:: [[constraints#Extensions are C++ shared libraries]]

## Runtime-only Lean initialization

The runtime bridge defines its own `lean_initialize` that starts only the Lean runtime, and the extension never links `libleancpp`, so module initializers do not pull in the Lean compiler package.

**Context.** Lean 4.35 module initializers call `lean_initialize`, whose toolchain version initializes the compiler package; LeanElpi's FFI library inherits that. **Consequences.** The extension is 2.7 MB instead of 68 MB and starts in about 12 ms. Lean code linked into the extension must not depend on the C++ kernel (`Lean.Expr` primitives, `MetaM`); the link fails with undefined `lean_*` symbols if it does, because `libleancpp` is absent. A Lean upgrade must re-check that `lean_initialize` is still the only hook.

Record: [ADR 0022](../docs/adr/0022-runtime-only-lean-initialization.md).

- status:: accepted
- motivated_by:: [[constraints#Lean module initializers call lean_initialize]] {weight: primary}
- motivated_by:: [[decisions#Logic in Lean behind a thin C++ shim]]

## Call LeanElpi only through its host façade

Marien calls LeanElpi only through LeanElpi's `Elpi.Host` module, wrapped once in `Marien.Engine`; no other Marien module imports the engine.

**Context.** Marien needs signatures, goals from terms, structured solutions, resumable slices, facts as terms and the clause AST, which LeanElpi 0.3.3 keeps in internal modules or lacks. **Consequences.** An engine upgrade touches one file, and `tests/EngineContract.lean` checks every scenario of `engine-host-api` against the pinned release. LeanElpi commits to a public AST and result-term type. Marien pins the façade by commit until the release that carries everything it uses (0.4.2).

Record: [ADR 0023](../docs/adr/0023-leanelpi-host-facade.md).

- status:: accepted
- motivated_by:: [[decisions#Logic in Lean behind a thin C++ shim]] {weight: primary}
- motivated_by:: [[decisions#LeanElpi is the engine]]
- motivated_by:: [[constraints#Out of fuel discards the search]]

## Catalog as JSON, rows as column batches

The catalog crosses from the shim to Lean as JSON, read once per call; table rows cross as column batches of values built through the runtime bridge, never one call per row.

**Context.** The catalog is small and the offline tool of M5 reads the same JSON from a file; rows can number millions. **Consequences.** The C++ side writes JSON and pushes values, the codec turns them into terms, and the bridge API never exposes a Lean structure layout.

Record: `openspec/changes/add-tracer-bullet/design.md`.

- status:: accepted
- motivated_by:: [[decisions#Logic in Lean behind a thin C++ shim]] {weight: primary}
- motivated_by:: [[decisions#Scan tables in the calling transaction]]

## Snake-case names with a collision check

Generated identifiers are lower snake case (`ReportsTo` becomes `reports_to`); a clash between two catalog names, a keyword or a library name fails generation and names what clashed.

**Context.** Hand-written rules must read well; clashes are rare. **Consequences.** The naming is injective whenever generation succeeds (`assignNames_injective`); a schema with a clash cannot be used until a table or property is renamed. Rejected: an always-injective escape scheme, which makes every rule harder to read.

Record: `openspec/changes/add-tracer-bullet/design.md`.

- status:: accepted
- motivated_by:: [[decisions#Predicate-per-property encoding]] {weight: primary}
- motivated_by:: [[constraints#Names starting with an underscore are variables]]

## Constructor and node predicate share the table name

A node table `T` gives the constructor `t` (applied to the key) and the predicate `t` listing every node; a rel table gives the edge constructor and the rel predicate `r`. The signature declares each predicate before its constructor.

**Context.** The later specs write `person 42` for a node and `reports_to P E M` for an edge. **Consequences.** LeanElpi resolves the overloading by type; the declaration order is load-bearing and tested.

Record: `openspec/changes/add-tracer-bullet/specs/schema-encoding/spec.md`.

- status:: accepted
- motivated_by:: [[decisions#Predicate-per-property encoding]] {weight: primary}
- motivated_by:: [[constraints#A pred declaration replaces a constant of the same name]]

## Edge ids are internal ids

The edge term of a rel table wraps LadybugDB's internal rel id (table id and offset in one integer); results report nodes by primary key. Edge ids are stable only within one transaction.

**Context.** Rel tables have no primary key, and parallel edges must stay distinct. **Consequences.** Enough for a read-only run; edge terms must not be stored across transactions.

Record: `openspec/changes/add-tracer-bullet/design.md`.

- status:: accepted
- motivated_by:: [[decisions#Read-only runs]] {weight: primary}

## Explicit elpi_init

`CALL elpi_init()` creates `_elpi_module` and `_elpi_accumulates` with `CREATE ... IF NOT EXISTS`; every other function that needs them fails with a message naming `elpi_init()`.

**Context.** DDL during `LOAD` would surprise users and may be impossible on a read-only connection. **Consequences.** One extra call per database; init is idempotent.

Record: `openspec/changes/add-tracer-bullet/design.md`.

- status:: accepted
- motivated_by:: [[decisions#Rules stored in system tables]] {weight: primary}
- motivated_by:: [[constraints#Table functions can rewrite into Cypher]]

## One rewritten statement per write

`elpi_save` and `elpi_drop` check everything at bind time and return one Cypher statement through `rewriteFunc`; `elpi_init` and `elpi_import` return several, wrapped in `BEGIN TRANSACTION … COMMIT` unless the caller already runs a transaction.

**Context.** A rewrite batch is not atomic in autocommit mode. **Consequences.** A save is atomic with the caller's transaction; module sources are embedded as escaped literals whose correctness is proved (`unescape_escape`, `escape_no_delim`).

Record: `openspec/changes/add-tracer-bullet/design.md`.

- status:: accepted
- motivated_by:: [[constraints#Table functions can rewrite into Cypher]] {weight: primary}
- motivated_by:: [[constraints#A rewrite is a batch of statements]]
- motivated_by:: [[constraints#Rewrite functions take literals only]]

## Handle cache keyed by source hashes

The handle cache keys a compiled module by name, version, source hash, schema hash and the source hashes of the modules it accumulates.

**Context.** The cache is per process and shared by every database it opens, and versions restart after a drop, so a version alone served one database's program to another (found by the integration tests). **Consequences.** A changed dependency or schema compiles anew; equal sources share an entry across databases.

Record: `openspec/changes/add-tracer-bullet/design.md`.

- status:: accepted
- motivated_by:: [[decisions#Lazy recheck by schema hash]] {weight: primary}
- motivated_by:: [[decisions#Rules stored in system tables]]

## Debug queries load the tables their goal names

`elpi_query` materializes the tables of every generated predicate the module mentions and, in addition, those named in the goal text, so a debug goal such as `person.born P D` sees facts even when the module never calls `person.born`.

**Context.** Materialization by the module's metadata alone made such goals answer nothing, silently. **Consequences.** A debug query costs at most the tables its goal adds; typed entry points (M2) load what the module reaches.

Record: `openspec/changes/add-tracer-bullet/design.md`.

- status:: accepted
- motivated_by:: [[decisions#Typed entry points and an untyped debug query]] {weight: primary}
- motivated_by:: [[decisions#Materialize facts per call]]

## Columns of typed entry points come from the predicate signature

`elpi_run` reads the predicate's modes and argument types when it is bound: argument `k` is parameter `ink` when its mode is `i` and output column `outk` when it is `o`, typed by the value codec's column map.

**Context.** Columns are fixed before solving, and only a `pred` declaration carries modes (a `type … -> prop` defaults every argument to `o`). **Consequences.** A predicate declared with `type` only is rejected, as is an argument without a column mapping. Node kinds become their table's primary-key type, edge kinds the internal id. Cells cross to the shim as typed prefix tokens and are never printed. `value_roundtrip` and `decodeC_sound` prove the column codec.

Record: `openspec/changes/archive/2026-11-05-add-typed-validation/design.md`.

- status:: accepted
- motivated_by:: [[decisions#Typed entry points and an untyped debug query]] {weight: primary}
- motivated_by:: [[constraints#Output columns are fixed at bind time]]
- motivated_by:: [[decisions#Proofs where practical]]

## Subject as a generated union kind

Every signature declares `kind subject type.` with one constructor `subj_<table>` per node and rel table, plus `severity` with `error`, `warning` and `info`. A violation's subject decodes to the table label and the key.

**Context.** A string subject loses typing in rules; one `violation_<table>` per table loses the single entry point. **Consequences.** The protocol's names join the injective-naming check, so a table called `Subject` is refused rather than shadowing the kind. `subject_decode_encode` and `subject_encode_decode` prove the codec, given unique constructors and labels.

Record: `openspec/changes/archive/2026-11-05-add-typed-validation/design.md`.

- status:: accepted
- motivated_by:: [[decisions#Validation protocol]] {weight: primary}

## A module reaches what its accumulated modules reach

A module reaches the tables whose generated identifiers its clauses or declarations mention, plus what every module it accumulates reaches, read from their stored metadata.

Called generated predicates are collected the same way.

**Context.** The engine's clause view holds the module's own clauses, not those of accumulated libraries. **Consequences.** The reached-table hash covers a library's tables too, and a run loads the facts an accumulated module's clauses need (M1 missed them). A module saved before reached tables were recorded is hashed over the whole schema.

Record: `openspec/changes/archive/2026-11-05-add-typed-validation/design.md`.

- status:: accepted
- motivated_by:: [[decisions#Lazy recheck by schema hash]] {weight: primary}

## Runs recompile in memory; only elpi_recheck writes

A run compares the module's reached-table hash with the cache key; a new hash compiles the module afresh in memory, and a failure fails the run. `elpi_recheck` alone persists hash, signature, status and error, in one rewritten statement.

**Context.** A `CALL` in a read query cannot write, and there is no DDL hook. **Consequences.** No run ever uses an older compilation after the schema changed. `stale` exists only as `elpi_recheck`'s old status; `broken` is stored with its error, and saving the module clears it.

Record: `openspec/changes/archive/2026-11-05-add-typed-validation/design.md`.

- status:: accepted
- motivated_by:: [[decisions#Read-only runs]] {weight: primary}
- motivated_by:: [[constraints#Table functions can rewrite into Cypher]]
- motivated_by:: [[constraints#No DDL hooks for extensions]]

## Version check by release, else by storage version

On load the extension compares the running LadybugDB's release with the pinned one through `Version::getVersion`, looked up at run time. When the host does not export it, the host's storage version must equal the pinned release's.

**Context.** liblbug exports the release version; the CLI does not, and an undefined symbol would make the library fail to load with a linker message. **Consequences.** In applications on liblbug a mismatch is refused exactly; in the CLI only across storage versions, so a patch release of the same storage version is not told apart.

Record: `openspec/changes/archive/2026-11-05-add-typed-validation/design.md`.

- status:: accepted
- motivated_by:: [[constraints#The CLI does not export the release version]] {weight: primary}
- motivated_by:: [[constraints#Extensions are C++ shared libraries]]

## Releases built from one matrix script

`scripts/release-matrix.sh` lists the supported LadybugDB versions, OSes and CPUs; the release workflow builds and tests each entry, names its artifact after all three, and publishes only when every entry passed.

**Context.** One build per LadybugDB version, OS and CPU is the only way an extension loads. **Consequences.** Adding a LadybugDB version is a one-line change; `scripts/check-release-workflow.sh` checks the shape on every push. All four entries first shipped together in v0.3.0.

Record: `openspec/changes/archive/2026-11-05-add-typed-validation/design.md`.

- status:: accepted
- motivated_by:: [[decisions#Out-of-tree extension with its own repository]] {weight: primary}
- motivated_by:: [[constraints#Extensions are C++ shared libraries]]

## Landing page on the extension server

The Pages site that serves the extension layout also carries Marien's website from `web/` (home, tour, guide, stylesheet, logo), laid over the layout by `scripts/build-site.sh` with the release and LadybugDB versions filled in.

**Context.** A Pages deployment replaces the whole site, so the page cannot be deployed apart from the extension files. **Consequences.** Releases deploy both; between releases `pages.yml` rebuilds the site from the latest release's zips plus the page, and both workflows share one concurrency group. The logo is an orange, black and white ladybug (Marienkäfer) with a λ on its left wing case and the term tree of `f(a, b)` on its right, the term's nodes being its spots; the favicon is a simplified drawing for small sizes.

- status:: accepted
- motivated_by:: [[decisions#Releases built from one matrix script]] {weight: primary}
- motivated_by:: [[constraints#INSTALL accepts only official extensions]] {note: "the page tells users to load by path"}

## Analysis on the clause AST at save and recheck

The rule analyzer runs on the clause AST of a module and the modules it accumulates whenever the module is saved or rechecked, and stores one verdict per entry point with the module.

**Context.** Narrowed scopes and partitions are safe only when an analysis says so, and the answer must match the compiled code. **Consequences.** A verdict holds what the entry point reaches (runs load only those tables), whether it is monotone or `dynamic` and why, and its accepted partition. A run after a schema change analyses again in memory; `elpi_recheck` stores the new verdicts. Reachability is a closure proved closed (`reach_closed`). Positions in verdicts are those of the clause holding the construct: the AST has no positions for single goals.

Record: `openspec/changes/archive/2026-11-05-add-analysis-and-partitioning/design.md`.

- status:: accepted
- motivated_by:: [[decisions#Closed-world scope]] {weight: primary}
- motivated_by:: [[decisions#Staged rule generation over a reflected schema]]

## The subject is the anchor

An anchor partition anchors each clause on its subject variable `subj_<kind> A`: a batch keeps a row only when its subject is one of the batch's anchors, so each violation is reported by exactly one batch.

**Context.** The spec asks for locality around an anchor and for the subject to be the anchor. **Consequences.** Distances are measured from the subject, so a rule about a manager whose atoms lie near the manager is accepted (sound, and wider than the spec's wording); a subject that is a constant or another table's constructor is rejected. With the row filter, overlapping neighbourhoods cannot report a violation twice (`violation_unique_batch`).

- status:: accepted
- motivated_by:: [[decisions#Partitioned validation]] {weight: primary}

## Locality by inlining, conservatively

Before measuring distances the analyzer inlines helper predicates into the entry clause; recursion, calls through variables, cuts, implications and library calls that reach the database reject the partition instead of being approximated.

**Context.** A precise interprocedural analysis is large and would need the property tests anyway. **Consequences.** Negation sees only the variables bound before it; each edge atom records the direction from its nearer endpoint, and the scanner follows exactly those directions. The rejection measure of `tests/differential/run.sh` shows how often a rejected module would have been fine (cuts and library calls: never found wrong in 200 samples).

- status:: accepted
- motivated_by:: [[decisions#Closed-world scope]] {weight: primary}
- motivated_by:: [[decisions#Differential testing with an oracle]]

## Rejected partitions fail the save

A declared partition that the checks reject makes `elpi_save` fail with the reason and the clause position, so no stored module carries a declaration it does not honour.

**Consequences.** A partition on a dynamic entry point names the `=>` goal. After a schema change that makes a partition unsafe, `elpi_recheck` marks the module broken and runs fail with the reason. Monotonicity also treats `findall` like `forall`: collecting all answers is not monotone.

- status:: accepted
- motivated_by:: [[decisions#Closed-world scope]] {weight: primary}

## Structural facts from Marien's own graph routines

`in_cycle.<rel>` and `component.<rel>` come from Marien's own iterative Tarjan and union-find over the edges scanned in the calling transaction, not from LadybugDB's algo extension.

**Context.** The algo package cannot load on macOS, and its routines are not callable from another extension without a nested query. **Consequences.** The facts are computed on every call that reaches them and never stored, so they are never stale; they are the same facts the algo extension would give.

- status:: accepted
- motivated_by:: [[constraints#Official algo extension fails to load on macOS]] {weight: primary}
- motivated_by:: [[decisions#Scan tables in the calling transaction]]

## Batches and buckets are cut in Lean

The shim enumerates anchors and key values in the calling transaction; batch sizes and bucket numbers come from Lean (`batchSizes`, `bucketsOf`), so the coverage theorems describe the code that runs.

**Consequences.** `batches_partition`, `violation_unique_batch` and `key_buckets_sound` are about `Marien/Exec/Partition.lean` itself. A batch whose neighbourhood exceeds `elpi_max_facts` is split in halves down to one anchor; errors name the batch (`batch 3 of 5`).

- status:: accepted
- motivated_by:: [[decisions#Proofs where practical]] {weight: primary}
- motivated_by:: [[decisions#Partitioned validation]]

## Generated predicates are indexed to depth 2

Every generated predicate declares `:index (2)` on its node and edge arguments (3 for union endpoints), so a lookup compares keys, not only the constructor every fact of a table shares.

**Consequences.** Full-scope joins run about three times faster; they remain linear per lookup until LeanElpi keys its index deeper.

- status:: accepted
- motivated_by:: [[constraints#Deep indexing scans the first-argument bucket]] {weight: primary}

## Differential properties with a Lean generator and a C runner

Workloads come from a seeded Lean generator; a C runner checks partition equivalence and narrowing against an embedded LadybugDB with the built extension; rejected cases run on Marien's executor in Lean, since the extension refuses them.

**Consequences.** Failures are shrunk by regenerating the seed at smaller sizes and keeping the smallest failing case. The rejection measure is printed, never a failure.

- status:: accepted
- motivated_by:: [[decisions#Differential testing with an oracle]] {weight: primary}

## Analysis soundness over an abstract Horn semantics

The monotonicity and locality checks are proved sound over a staged ground Horn semantics with stratified negation, not over LeanElpi's operational semantics; the differential properties check the engine.

**Context.** The checks are syntactic, and a proof over LeanElpi's search would need a formal model of the engine. **Consequences.** `Marien/Analysis/Semantics.lean` proves `monotone_sound` (a sub-database gives no new answers), `locality_sound` (answers near the subject are the same on its neighbourhood) and `static_independent` (a stratum that reads no database fact answers the same on every database). What links the theorems to the checks is stated in the file: negated goals reach no database predicate, and every atom a clause about the subject reads lies within the radius. Cut and `forall` are outside the fragment and rejected.

- status:: accepted
- motivated_by:: [[decisions#Proofs where practical]] {weight: primary}
- motivated_by:: [[decisions#Differential testing with an oracle]]

## Install by download until INSTALL accepts third-party names

Users download the build for their LadybugDB, OS and CPU from Marien's extension server and run `LOAD EXTENSION` with its path; the server keeps the layout `INSTALL marien FROM '<url>'` fetches, for when LadybugDB allows it.

**Context.** LadybugDB 0.22.1 binds `INSTALL` and `LOAD <name>` only for its official extensions. **Consequences.** The `distribution` requirement asks for download and load; CI loads from a local server in the layout (`scripts/test-install.sh`) and, after each deployment, fetches every entry from the live site and compares it with the tested artifact (`scripts/check-site.sh`).

- status:: accepted
- motivated_by:: [[constraints#INSTALL accepts only official extensions]] {weight: primary}
- motivated_by:: [[decisions#Out-of-tree extension with its own repository]]

## Meta-rules in a marked section of the module

A module's meta-rules sit between `% @marien meta` and `% @marien end`; the section is cut out of the stage 2 program and the meta-rules are loaded on their own, both with every line kept in place.

**Context.** Meta-rules need `pred generate` and the description's predicates, which the stage 2 program must not see; a separate module per meta-program would split one rule set in two. **Consequences.** Errors in either part point at the module's own lines; errors in generated text point at `<module> (generated)` with the solution of `generate` that produced the line.

- status:: accepted
- motivated_by:: [[decisions#Staged rule generation over a reflected schema]] {weight: primary}
- motivated_by:: [[decisions#Rules stored in system tables]]

## Stage one is bounded by fuel and size, never by a clock

Stage 1 runs under `elpi_fuel` and `elpi_max_generated_bytes` (default 1 000 000), and sees neither the shallow signature nor any fact.

**Context.** A time limit would make the generated text depend on the machine and the moment; a meta-rule that one clause per pair of tables can blow up past `elpi_max_facts`, which never counts text. **Consequences.** `generate` is a pure function of the description and the source (`Stage.generate_deterministic`, `Stage.generate_perm`); a meta-rule that calls a database predicate is refused by name from the compile error.

- status:: accepted
- motivated_by:: [[decisions#Staged rule generation over a reflected schema]] {weight: primary}
- motivated_by:: [[decisions#Fuel-sliced execution that fails loudly]]

## Staged modules hash the whole schema

A module with meta-rules, or one that accumulates such a module, stores the hash of the whole visible schema with its annotations, not of the tables it reaches.

**Context.** Stage 1 reads the whole description, so any table or annotation can change the generated text. **Consequences.** Any DDL or `elpi_annotate` regenerates a staged module on its next run (in memory) or at `elpi_recheck` (stored); modules without meta-rules keep the reached-table hash, which now also covers the annotations of reached tables.

- status:: accepted
- motivated_by:: [[decisions#Lazy recheck by schema hash]] {weight: primary}
- motivated_by:: [[decisions#A module reaches what its accumulated modules reach]]

## Generated clauses only for declared predicates

Every clause in a module's generated text must be for a predicate the module's own clauses or the shallow signature declare (`Stage.checkHeads`, proved by `Stage.heads_declared`).

**Context.** LeanElpi compiles a clause for an undeclared predicate without complaint. **Consequences.** Generated code cannot add entry points nobody wrote or reviewed; a meta-rule that needs a helper predicate declares it in the module.

- status:: accepted
- motivated_by:: [[decisions#Staged rule generation over a reflected schema]] {weight: primary}
- motivated_by:: [[decisions#Proofs where practical]]

## The generated column holds stage one text

`_elpi_module.generated` holds the text the module's meta-rules generated, empty without meta-rules, instead of the shallow signature it was checked against.

**Context.** The signature is a function of the schema and was never read back. **Consequences.** `MATCH (m:_elpi_module) RETURN m.generated` shows generated code; `elpi_recheck` persists regenerated text; `elpi_export` leaves it out and `elpi_import` regenerates it.

- status:: accepted
- motivated_by:: [[decisions#Staged rule generation over a reflected schema]] {weight: primary}

## graph.std is built into the extension

`lib/graph/std.elpi` is compiled into the extension with `include_str`, and `accumulate graph.std.` resolves to it in every module; no stored module may take the name.

**Context.** The analysis must read the combinators' real clauses, and a stored copy could drift from the version the extension was tested with. **Consequences.** Upgrading the extension upgrades the library; its locality claims (`% @marien local …`) are tested against the analysis.

- status:: accepted
- motivated_by:: [[decisions#Predicate-per-property encoding]] {weight: primary}
- motivated_by:: [[decisions#Partitioned validation]]

## Combinators take the node predicate where they enumerate nodes

`card_witness Nodes R Min Max X N` takes the node predicate of `R`'s source kind (`person`), since a library polymorphic in the kind cannot list a kind's nodes; `acyclic_witness_in` takes the structural predicate `in_cycle.<rel>`.

**Context.** A clause `nodes P :- person P` fixes the type variable of a polymorphic `nodes`, which LeanElpi rejects. **Consequences.** Nodes without edges count as 0; the spec's signatures carry the extra argument.

- status:: accepted
- motivated_by:: [[constraints#Clause type variables are rigid]] {weight: primary}

## Locality follows predicate arguments into combinators

The locality check inlines a combinator with its relation arguments substituted, checks a `findall` template as a scoped goal, splices inlined conjunctions into their parent and closes bound variables over equations already unified.

**Context.** Before M4 any call through a variable predicate rejected a partition, so no combinator could be used in a partitioned rule. **Consequences.** `card_witness`, `functional_witness` and `symmetric_witness` partition at radius 1; search-based `closure` and `acyclic_witness` are rejected with the chain of calls in the message. The differential properties (300 cases) still hold.

- status:: accepted
- motivated_by:: [[decisions#Locality by inlining, conservatively]] {weight: primary}
- motivated_by:: [[decisions#Partitioned validation]]

## One encoding, two printers

`Signature.ofSchema` returns structured declarations; `ElpiPrinter` renders the text the database loads, and the offline `LeanPrinter` renders one `inductive … deriving Elpi` per kind from the same declarations.

**Context.** The offline types must be the runtime encoding, not a second encoder that has to agree with it. **Consequences.** The in-database text is byte-identical to M4's; `marien-codegen` elaborates its module and compares the declarations `deriving Elpi` registered with `ElpiPrinter`'s, on parsed types, failing with the first differing kind and constructor. `LeanPrinter.derive_eq_elpi` proves the printer correspondence against a model of `deriving Elpi`. Rejected: a second encoder in the tool, and codegen from the runtime ELPI text (a lossy parse back into structure).

- status:: accepted
- motivated_by:: [[decisions#Schema types at runtime and Lean inductives offline]] {weight: primary}
- motivated_by:: [[decisions#Logic in Lean behind a thin C++ shim]]
- motivated_by:: [[decisions#Proofs where practical]]
- changed_by:: [[changes#add-ecosystem]]

## The generated module accumulates the runtime signature

The module `marien-codegen` emits declares the program `<namespace>.signature` and accumulates the whole `ElpiPrinter` text into it, after the inductives.

**Context.** Derived declarations always precede accumulated ones, and a predicate declared after a constructor of the same name replaces it. The runtime text declares each predicate before its constructor, so re-accumulating it restores the overloading the database has. **Consequences.** A stored module loads against the program unedited; the derived declarations alone are what the agreement check compares.

- status:: accepted
- motivated_by:: [[constraints#Derived declarations come before accumulated units]] {weight: primary}
- motivated_by:: [[decisions#Constructor and node predicate share the table name]]
- changed_by:: [[changes#add-ecosystem]]

## The schema dump is the catalog JSON, canonical

`CALL elpi_signature(format := 'json')` returns the catalog JSON that `Schema.ofJson` already parses, with a `format` tag, sorted keys and sorted tables, properties, pairs and annotations; STRUCT fields keep their order.

**Context.** The offline tool must build the same `Schema` value the extension builds. **Consequences.** No second schema format; `Dump.canonical_perm` proves that catalog order does not change the document, and equal schemas give byte-identical dumps.

- status:: accepted
- motivated_by:: [[decisions#Schema types at runtime and Lean inductives offline]] {weight: primary}
- changed_by:: [[changes#add-ecosystem]]

## Soufflé over the first-order stratified fragment

The oracle translates a module only when every clause reached from its entry point is in the first-order, cut-free, stratified fragment; anything else is skipped with its reason and counted.

Excluded: `pi`, `=>`, lambdas, lists, cuts, calls outside the module and the schema, edge-id constants and edge subjects.

**Context.** Over finite ground facts, stratified Datalog negation and λProlog negation as failure agree on that fragment, so a comparison there is exact. **Consequences.** The oracle shares no code with Marien: its own parser reads the module, and the facts it gives Soufflé are computed from the generator's graph with the scanner's scope rule (listed nodes, their properties, edges whose restricted endpoints are listed), not taken from Marien's materialization, so a fault in the scanner shows too. Coverage is partial and visible: at size 6 over 200 seeds, 655 comparisons and 304 skipped targets, mostly the bounded `reach` helper. Rejected: a Cypher oracle, upstream OCaml ELPI.

- status:: accepted
- motivated_by:: [[decisions#Differential testing with an oracle]] {weight: primary}
- motivated_by:: [[decisions#Partitioned validation]]
- changed_by:: [[changes#add-ecosystem]]

## Proof relations keep answer multiplicities

Each clause of the entry point becomes one Soufflé relation per branch of its disjunctive normal form, over its answer columns and every variable of the branch; the harness projects and keeps duplicates.

A `_` in a positive literal becomes a fresh variable, so two parallel edges are two proofs.

**Context.** `elpi_validate` returns one row per solution, while Soufflé relations are sets. A tuple of a proof relation is one proof, so the projection is ELPI's answer multiset. **Consequences.** Module predicates called positively are unfolded; a recursive one is outside the fragment, since its number of derivations is not a Datalog relation. Under negation only existence matters: `not G` becomes an auxiliary relation over the variables bound before it, defined from the earlier literals and `G`, and module predicates there are set relations, recursive or not.

- status:: accepted
- motivated_by:: [[decisions#Soufflé over the first-order stratified fragment]] {weight: primary}
- changed_by:: [[changes#add-ecosystem]]

## Statements desugar in the transformer

A custom statement becomes, in the transformer, the parse tree of its `CALL elpi_*` form with literal arguments; LadybugDB's own binder, planner and mapper run it. `CALL elpi_statement` runs it until the grammar routes statements.

**Context.** A binder extension receives no binder or client context, so it cannot bind the `CALL` it would desugar to; the parse tree of the `CALL` needs nothing else. LadybugDB does not export `ParsedFunctionExpression`'s vtable, so the node is copied from LadybugDB's parse of `CALL <fn>()`. **Consequences.** No statement logic outside `Statement.desugar`; the source reaches `elpi_save` as a value, never re-escaped. `VALIDATE … MIN SEVERITY` needs module names, since `elpi_validate` has no all-modules form at a severity. Rejected: desugaring in a binder extension, and rewriting into `CALL` text, since LadybugDB does not rewrite a rewritten standalone call again.

- status:: superseded
- motivated_by:: [[decisions#CALL functions first]] {weight: primary}
- motivated_by:: [[constraints#Only CREATE USER and CREATE ROLE reach extension parsers]]
- motivated_by:: [[constraints#Extensions are C++ shared libraries]]
- changed_by:: [[changes#add-ecosystem]]

## Statements are a string function

Custom statements run as `CALL elpi_statement('<statement>')`: Lean parses and desugars the text, and the function binds exactly as the statement's `CALL elpi_*` form does. There is no statement transformer.

**Context.** LadybugDB routes no new syntax to extension transformers, and its maintainers declined a route: they prefer a function over a string, as SQL databases embed Cypher, to extensions changing the grammar (LadybugDB/ladybug#1519). **Consequences.** A statement is a Cypher string literal, so its quotes and backslashes are escaped once; the `$$` body is then taken byte for byte. A query parameter would avoid the escaping but cannot reach a rewriting function, so writes refuse one by name. The transformer, its copy of LadybugDB's `ParsedFunctionExpression` and the ANTLR include were removed.

- status:: accepted
- date:: 2026-11-07
- supersedes:: [[decisions#Statements desugar in the transformer]] {since: "0.4.1", reason: "LadybugDB declined extension grammar (#1519)"}
- motivated_by:: [[decisions#CALL functions first]] {weight: primary}
- motivated_by:: [[constraints#Only CREATE USER and CREATE ROLE reach extension parsers]]
- motivated_by:: [[constraints#Standalone CALL rewrites run before parameters are bound]]
- changed_by:: [[changes#add-ecosystem]]

## The locality check rests on its theorem premise and two differential checks

`locality_sound` is proved over the abstract semantics given its premise `closed`; that `Marien/Analysis/Locality.lean` establishes `closed` for the modules it accepts is tested, not proved.

**Context.** The M3 stretch theorem `Locality.sound` would have to model the check's inlining of combinators, its scoped `findall` templates and its variable closure, a large proof for code the tests already exercise. **Consequences.** Two independent checks stand in for it: M3's partition-equivalence property (partitioned equals full scope in Marien, 1000 cases in CI) and the Soufflé oracle, which compares Marien's partitioned report with Soufflé at full scope on the modules the check accepts (`tests/oracle/souffle/run.sh`). The proof stays possible later; this closes the open item of M5.

- status:: accepted
- motivated_by:: [[decisions#Analysis soundness over an abstract Horn semantics]] {weight: primary}
- motivated_by:: [[decisions#Soufflé over the first-order stratified fragment]]
- motivated_by:: [[decisions#Proofs where practical]]
- changed_by:: [[changes#add-ecosystem]]

## The website's example runs in CI

The tour on the website (`web/tour.html`) follows one know-your-customer graph (`examples/kyc/`), and every result it shows is quoted from `examples/kyc/expected.txt`, which CI compares with what the LadybugDB CLI prints.

**Context.** A page of hand-written outputs drifts from the extension silently. **Consequences.** A change in Marien's output fails the build until `expected.txt` and the tour are updated together. KYC is the example domain because typed validation, cycle detection over ownership and beneficial-owner queries matter there, and its data is the kind that must stay in the database.

- status:: accepted
- motivated_by:: [[decisions#Landing page on the extension server]] {weight: primary}
- motivated_by:: [[decisions#Differential testing with an oracle]] {note: "outputs are checked, not written by hand"}
