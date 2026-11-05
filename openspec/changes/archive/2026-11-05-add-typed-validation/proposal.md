## Why

After the tracer bullet (M1) Marien can save a module and run an untyped goal over a fully materialized graph, but results come back as strings, there is no uniform way to ask "is this graph valid", a schema change silently leaves stored modules stale, and the extension can only be built by hand. M2 makes Marien usable for validation on small and medium graphs: typed entry points whose columns are known at bind time, one validation protocol with one report shape, safe behaviour under schema change, and an install path that ordinary LadybugDB users can follow.

**Milestone:** M2 (typed validation).

**Depends on:** `add-leanelpi-host-api` (M0: entry-point signatures and structured result terms from the `engine-host-api` capability), `add-tracer-bullet` (M1: `schema-encoding`, `rule-storage`, and `rule-execution` with "Untyped debug query", "Full-scope materialization", "Fuel-sliced execution" and "Execution limits are errors").

## What Changes

- `elpi_run(module, pred, params)`: calls a declared predicate; `i:` arguments are decoded from a parameter map through the value codec, `o:` arguments become typed output columns fixed at bind time; node kinds come back as primary-key columns.
- Validation protocol: a module that declares `pred violation o:severity, o:string, o:subject.` takes part in `elpi_validate([modules], [min_severity])`, which returns one report `(module, version, severity, code, message, subject_label, subject_pk)`. `subject` is a generated union kind with one constructor per node and edge kind.
- Schema evolution: every module stores a hash of the tables it reaches. A run whose hash differs regenerates and rechecks the module in memory; failure makes the run error and never falls back to stale code. `elpi_recheck()` revalidates every module, persists generated code and `status` through `rewriteFunc`, and returns a report.
- Distribution: out-of-tree build (Lake static archive plus a CMake-built shim) pinned to one LadybugDB version, a CI matrix over LadybugDB version × OS × CPU, and installation from Marien's extension server (download and `LOAD EXTENSION`, in the layout `INSTALL marien FROM '<url>'` will use once LadybugDB accepts names outside its official list); loading into a mismatched LadybugDB is refused.

## Capabilities

### New Capabilities
- `validation`: the `violation` protocol, the generated `subject` union and `elpi_validate`.
- `schema-evolution`: per-module schema hashes, lazy recheck, `broken` status and `elpi_recheck`.
- `distribution`: the out-of-tree build, CI matrix, extension server and version check.

### Modified Capabilities
- `rule-execution`: adds "Typed entry points" (`elpi_run`).

## Impact

**Motivating decisions:**
- [[decisions#Typed entry points and an untyped debug query]] ([[adr:0008]]): typed columns at bind time.
- [[decisions#Validation protocol]] ([[adr:0015]]): one entry point and one report shape.
- [[decisions#Lazy recheck by schema hash]] ([[adr:0011]]): no DDL hooks, so check on run.
- [[decisions#Out-of-tree extension with its own repository]] ([[adr:0017]]): own build and extension server.
- [[decisions#CALL functions first]] ([[adr:0012]]): `elpi_recheck` writes through `rewriteFunc`.
- [[decisions#Proofs where practical]] ([[adr:0020]]): codec and hash properties are theorems.

**Binding constraints:**
- [[constraints#Output columns are fixed at bind time]]: `elpi_run` must know its columns before solving.
- [[constraints#No DDL hooks for extensions]]: rechecks are lazy or explicit.
- [[constraints#Table functions can rewrite into Cypher]]: how `elpi_recheck` persists.
- [[constraints#Extensions are C++ shared libraries]]: one build per LadybugDB version.

**Components introduced or extended:**
- [[components#Validator]] (`Marien/Exec/Validate.lean`), new.
- [[components#Executor]], [[components#Value codec]], [[components#Signature generator]], [[components#Module store]], [[components#Handle cache]], [[components#Extension shim]], extended.

**Requirements added:**
- [[openspec:rule-execution#Typed entry points]]
- [[openspec:validation#Violation protocol]], [[openspec:validation#Subject union kind]], [[openspec:validation#Uniform validation report]]
- [[openspec:schema-evolution#Reached-table schema hash]], [[openspec:schema-evolution#Lazy recheck on run]], [[openspec:schema-evolution#Broken module status]], [[openspec:schema-evolution#Explicit recheck]]
- [[openspec:distribution#Out-of-tree build]], [[openspec:distribution#Build matrix]], [[openspec:distribution#Install from extension server]], [[openspec:distribution#LadybugDB version check]]

**Registered as:** [[changes#add-typed-validation]].
