---
type: Change
status: proposed  # per section: see each status:: line
---
# Changes

The OpenSpec changes that build Marien, one per milestone, in build order. Each lives in `openspec/changes/<id>/` with its proposal, design, tasks and spec deltas.

## spike-lean-runtime-in-ladybug

Spike: load a Lean-runtime shared library into LadybugDB and call it from a worker thread, to measure size and symbol clashes before committing.

- status:: archived
- date:: 2026-10-31

Archived to `openspec/changes/archive/2026-10-31-spike-lean-runtime-in-ladybug/`; its `extension-runtime` requirements now live in `openspec/specs/extension-runtime/spec.md`. Verdict and evidence: `spike/RESULT.md` (macOS go; Linux go with `libleanrt.a` rebuilt by `scripts/build-leanrt-pic.sh`).

## add-leanelpi-host-api

M0: the LeanElpi 0.4 API Marien needs: entry-point signatures, structured result terms, resumable fuel and a public clause AST. Implemented in the lean-elpi repository.

The engine side is lean-elpi change `add-host-api` (module `Elpi.Host`, with its three proofs), published in LeanElpi 0.4.1. Building M1 added host libraries for `accumulate`, goals parsed from text and the reserved names to the façade (two new requirements here, 20 contract checks), in lean-elpi PR #2 for 0.4.2. Marien pins that PR's commit `91ea5ba`. Open: merging it, the 0.4.2 release and the pin to its tag.

- status:: proposed

## add-tracer-bullet

M1: the whole stack end to end: shim, single runtime, catalog to signature, `elpi_save`, untyped `elpi_query`, full-scope materialization and fuel slicing.

Implemented: the Lean layers with their five proofs (54 Lean tests), the C++ shim and bridge (`shim/`), and 33 integration tests against LadybugDB 0.22.1, in CI on macOS arm64 and Linux aarch64 (`tests/linux/run.sh`). Archived with one task open: the pin to the LeanElpi 0.4.2 tag (Marien pins commit `91ea5ba`), tracked by [[changes#add-leanelpi-host-api]].

- status:: archived
- date:: 2026-11-06

Archived to `openspec/changes/archive/2026-11-06-add-tracer-bullet/`; its requirements live in `openspec/specs/` (`rule-execution`, `rule-storage`, `schema-encoding`).

## add-typed-validation

M2: typed `elpi_run`, the `violation` protocol and `elpi_validate`, lazy recheck by schema hash, and distribution from Marien's extension server.

Implemented: typed entry points, validation and schema evolution with six proofs (75 Lean tests, 52 integration tests on macOS arm64 and Linux aarch64), the out-of-tree build, the load-time version check and the release workflow, first published as v0.3.0 (four platforms, GitHub release and the Pages extension server). Installation is download and `LOAD EXTENSION`, since LadybugDB 0.22.1 refuses `INSTALL` for non-official names ([[decisions#Install by download until INSTALL accepts third-party names]]).

- status:: archived
- date:: 2026-11-05

Archived to `openspec/changes/archive/2026-11-05-add-typed-validation/`; its requirements live in `openspec/specs/` (`distribution`, `rule-execution`, `schema-evolution`, `validation`).

## add-analysis-and-partitioning

M3: rule analysis (reachability, monotonicity, dynamic, locality), narrowed scope, anchor and key partitions, structural facts and the differential property tests.

Implemented: the analyzer with stored verdicts, narrowed scopes, anchor and key partitions, structural facts, three planner theorems, `reach_closed`, the soundness theorems `monotone_sound` and `locality_sound` over an abstract Horn semantics, and the differential properties (unit, integration and property tests). Left for later: indexing deep enough for full-scope joins ([[constraints#Deep indexing scans the first-argument bucket]]), and scopes as query parameters, which LadybugDB refuses ([[constraints#Table function arguments are literals]]).

- status:: archived
- date:: 2026-11-05

Archived to `openspec/changes/archive/2026-11-05-add-analysis-and-partitioning/`; its requirements live in `openspec/specs/` (`differential-testing`, `partitioning`, `rule-analysis`, `rule-execution`).

## add-higher-order-layer

M4: schema reflection and annotations, staged rule generation, dynamic entry points and the `graph.std` combinator library.

Implemented: schema reflection with annotations (`elpi_annotate`, `_elpi_annotation`), stage 1 meta-rules whose text is checked and analysed like source and stored in `_elpi_module.generated`, `graph.std` built into the extension, and locality that follows relation arguments into combinators; four proofs (`ofSchema_no_system`, `ofSchema_perm`, `generate_perm`, `heads_declared`), unit, property and integration tests. Archived with the optional proof `Reference.closure_spec` not done.

- status:: archived
- date:: 2026-11-06

Archived to `openspec/changes/archive/2026-11-06-add-higher-order-layer/`; its requirements live in `openspec/specs/` (`graph-std`, `rule-generation`, `schema-evolution`, `schema-reflection`).

## add-ecosystem

M5: offline Lean codegen from the shared encoding, the Soufflé oracle, custom statements and the upstream proposals.

Released in v0.4.0 (2026-11-06, four platforms, with the new website): the schema dump and `marien-codegen` with the agreement check and two proofs (`Dump.canonical_perm`, `LeanPrinter.derive_eq_elpi`); the Soufflé oracle (`tests/oracle/souffle/run.sh`); custom statements with two proofs (`desugar_total`, `source_roundtrip`), registered as a transformer and run through `CALL elpi_statement` until LadybugDB routes them; the prebuilt Lean archive (`scripts/build-lean-archive.sh`). Filed upstream: LadybugDB/ladybug#1518 (catalog-change hook) and #1519 (extension statements). Open: the Soufflé CI job's first run, the upstream answers, the `ladybugdb/extensions` proposal (drafted).

- status:: proposed
