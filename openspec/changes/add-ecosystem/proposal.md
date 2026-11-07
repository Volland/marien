## Why

After M4, Marien is complete inside the database. Three things remain outside it, each promised by an accepted decision:

- **Proofs about rules need real Lean types.** [[decisions#Schema types at runtime and Lean inductives offline]] keeps the in-database signature in pure ELPI and promises an offline path to Lean inductives that shares the same encoding. Without that path, "a rule proved offline is the rule that runs" is a promise with nothing behind it.
- **The static analyses need an independent check.** M3's property tests compare Marien with itself (partitioned against full scope, narrowed against full). [[decisions#Differential testing with an oracle]] adds an engine with no shared code: Soufflé, over the first-order stratified fragment, where its semantics coincide with negation as failure on ground facts.
- **The interface reads like plumbing.** [[decisions#CALL functions first]] deferred custom statements until the function set was stable. It is stable now.

This change also tracks the upstream proposals for LadybugDB (a DDL hook for eager rechecks, and hosting the extension in `ladybugdb/extensions`), as tasks with no spec in this repository.

**Milestone:** M5.

**Depends on:** `add-higher-order-layer` (M4), so custom statements cover the full function set, including `elpi_annotate`. `add-analysis-and-partitioning` (M3), for the differential harness, random workloads and the locality check that the oracle tests also cover. `add-typed-validation` (M2) and `add-tracer-bullet` (M1), for the schema model, `Signature.ofSchema` and the `CALL` functions.

## What Changes

- **Offline codegen.** `lake exe marien-codegen <schema.json>` reads a schema dump (written by `CALL elpi_signature()` in JSON mode) and emits a Lean module with one `inductive` per kind, `deriving Elpi`. It uses the same `Signature.ofSchema` as the runtime, followed by a Lean printer instead of an ELPI printer. A check fails the build when the offline and runtime signatures disagree.
- **Soufflé oracle.** A translator from the first-order stratified subset of a module (no `pi`, no `=>`, no higher-order arguments, no cut) and the materialized facts to Soufflé Datalog. The test harness runs both engines and compares answer multisets.
- **Custom statements.** `CREATE RULES <name> AS $$…$$`, `DROP RULES <name>`, `CHECK RULES`, `VALIDATE [<modules>] [MIN SEVERITY <s>]` and `ANNOTATE <table> SET <key> = <value>`, run through `CALL elpi_statement('<statement>')`, a function over the statement text, since LadybugDB keeps its grammar to itself. Each one behaves exactly like its `CALL` form.
- **Upstream proposals** (tasks only): a catalog-change hook in LadybugDB for eager rechecks; contributing the extension to `ladybugdb/extensions` with a prebuilt Lean archive, so upstream CI needs no Lean toolchain.
- **The open question on proving the locality check** is answered here: either the M3 stretch theorem is completed, or the decision to rely on tests is recorded.

## Capabilities

### New Capabilities
- `offline-codegen`: the codegen tool, the schema dump format and the signature-agreement check.
- `differential-testing`: the Soufflé oracle. (The property tests from M3 stay where M3 put them; this change adds the oracle requirement only.)
- `custom-statements`: the statement extension and its equivalence with the `CALL` forms.

## Impact

**Motivating decisions:**
- [[decisions#Schema types at runtime and Lean inductives offline]] ([[adr:0004]]): one encoding, two printers.
- [[decisions#Differential testing with an oracle]] ([[adr:0018]]): an independent engine for the static analyses.
- [[decisions#CALL functions first]] ([[adr:0012]]): statements are syntax over the functions.
- [[decisions#Out-of-tree extension with its own repository]] ([[adr:0017]]): upstreaming is proposed once the extension is stable.
- [[decisions#Lazy recheck by schema hash]] ([[adr:0011]]): the DDL hook is the "B later" step of that decision.
- [[decisions#Proofs where practical]] ([[adr:0020]]): the printer correspondence and statement desugaring are proved where practical.

**Constraints:**
- [[constraints#No DDL hooks for extensions]]: the reason for the upstream hook proposal.
- [[constraints#Extensions are C++ shared libraries]]: binds the statement extension and the upstream build.

**Components introduced:**
- [[components#Offline codegen]] (`Marien/Offline/Codegen.lean`)
- [[components#Statement extension]] (`shim/statements.cpp`)

**Components changed:** [[components#Test harness]] (Soufflé oracle under `tests/oracle/souffle/`), [[components#Signature generator]] (a printer interface shared by the ELPI and Lean printers).

**Requirements added:**
- [[openspec:offline-codegen#Schema dump]], [[openspec:offline-codegen#Lean inductives from the schema]], [[openspec:offline-codegen#Offline and runtime signatures agree]]
- [[openspec:differential-testing#Soufflé oracle]]
- [[openspec:custom-statements#Rule statements]], [[openspec:custom-statements#Statements equal their CALL forms]], [[openspec:custom-statements#Statement source is not re-escaped]]

**Change register:** [[changes#add-ecosystem]].
