## Why

The spike proves that a Lean runtime can live inside LadybugDB, and M0 provides the engine API. M1 is the first end-to-end slice through every layer: the schema becomes a typed ELPI signature, a module is saved in the database with `elpi_save`, and `elpi_query` runs a goal over facts read from the graph. Each layer is the thinnest version that can be built on. M1 has no typed entry points, analysis, partitioning or meta-rules. Those come in M2 to M4. What it does include from day one is the behaviour later milestones rely on: one encoding function, source stored byte for byte, fuel slicing, and limits that end in errors.

**Milestone:** M1.

**Depends on:** `spike-lean-runtime-in-ladybug` (go decision and build recipe), `add-leanelpi-host-api` (LeanElpi 0.4: goals from terms, structured results, resumable slices, bulk fact loading, multi-unit load).

## What Changes

- A schema model built from LadybugDB's catalog, and a signature generator that turns it into ELPI declarations under the predicate-per-property encoding, with an injective naming scheme and explicit rules for every property type.
- A value codec between database values and ELPI terms, used for materialization and for results.
- System tables `_elpi_module` and `_elpi_accumulates`, created by `elpi_init()`, and the functions `elpi_save`, `elpi_drop`, `elpi_export` and `elpi_import`. Writes go through `rewriteFunc`, with module source embedded by a proved escaping function.
- A handle cache of compiled modules keyed by module version and schema hash.
- `elpi_query(module, goal)`: full-scope materialization by scanning tables in the calling transaction, fuel-sliced execution with interrupt and deadline checks, untyped result rows.
- Extension options `elpi_fuel`, `elpi_timeout_ms`, `elpi_max_solutions` and `elpi_max_facts`.

## Capabilities

### New Capabilities
- `schema-encoding`: the catalog → schema model → ELPI signature pipeline and the value codec.
- `rule-storage`: modules in system tables, save, drop, export and import, and the compiled-handle cache.
- `rule-execution`: materialization, the untyped debug query, fuel-sliced execution and execution limits. M2 and M3 add to it.

## Impact

**Motivating decisions:**
- [[decisions#Predicate-per-property encoding]] ([[adr:0005]])
- [[decisions#Schema types at runtime and Lean inductives offline]] ([[adr:0004]]): the encoding is one pure function, reused by offline codegen in M5.
- [[decisions#Rules stored in system tables]] ([[adr:0006]])
- [[decisions#Materialize facts per call]] ([[adr:0003]]) and [[decisions#Scan tables in the calling transaction]] ([[adr:0021]])
- [[decisions#Read-only runs]] ([[adr:0007]])
- [[decisions#Typed entry points and an untyped debug query]] ([[adr:0008]]): M1 builds the untyped half.
- [[decisions#CALL functions first]] ([[adr:0012]])
- [[decisions#Fuel-sliced execution that fails loudly]] ([[adr:0014]])
- [[decisions#Proofs where practical]] ([[adr:0020]])

**Binding constraints:**
- [[constraints#Table functions can rewrite into Cypher]]
- [[constraints#Output columns are fixed at bind time]]
- [[constraints#LeanElpi memory grows in long runs]]

**Components introduced:** [[components#Extension shim]], [[components#Catalog reader]], [[components#Table scanner]], [[components#Runtime bridge]], [[components#Schema model]], [[components#Signature generator]], [[components#Value codec]], [[components#Module store]], [[components#Handle cache]], [[components#Executor]].

**Requirements added:**
- `schema-encoding`: [[openspec:schema-encoding#Schema model from the catalog]], [[openspec:schema-encoding#Injective naming]], [[openspec:schema-encoding#Node table encoding]], [[openspec:schema-encoding#Rel table encoding]], [[openspec:schema-encoding#Property type mapping]], [[openspec:schema-encoding#System tables are invisible to rules]], [[openspec:schema-encoding#Canonical schema hash]], [[openspec:schema-encoding#Value codec round-trip]], [[openspec:schema-encoding#Signature inspection]]
- `rule-storage`: [[openspec:rule-storage#Module system tables]], [[openspec:rule-storage#Save checks before storing]], [[openspec:rule-storage#Source is stored byte for byte]], [[openspec:rule-storage#Derived module metadata]], [[openspec:rule-storage#Accumulate dependencies]], [[openspec:rule-storage#Drop protects dependents]], [[openspec:rule-storage#Export and import]], [[openspec:rule-storage#Compiled handle cache]]
- `rule-execution`: [[openspec:rule-execution#Full-scope materialization]], [[openspec:rule-execution#Untyped debug query]], [[openspec:rule-execution#Fuel-sliced execution]], [[openspec:rule-execution#Execution limits are errors]], [[openspec:rule-execution#Fresh store per call]]

**Change register:** [[changes#add-tracer-bullet]]
