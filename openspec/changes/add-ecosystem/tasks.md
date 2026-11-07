## 1. Offline codegen

- [x] 1.1 `elpi_signature(format := 'json')`: canonical schema dump, without `_elpi_*`, keys sorted (`Marien/Encoding/Dump.lean`, the catalog JSON with a `format` tag; the shim reads the option from `optionalParams`)
- [x] 1.2 Split printing out of the signature generator behind `SignaturePrinter`; move the existing printer into `ElpiPrinter` (structured `Decl`s; the ELPI text is byte-identical to M4's)
- [x] 1.3 `Marien/Offline/Codegen.lean`: `LeanPrinter` emitting one `inductive … deriving Elpi` per kind (node, reified edge, union endpoint, STRUCT record)
- [x] 1.4 `lake exe marien-codegen <dump.json> -o <Module.lean>`; elaborate the emitted module, read the derived signature, compare with `ElpiPrinter`, exit non-zero naming the first difference (in-process elaboration with one cached import; the module also accumulates the runtime signature, see constraint "Derived declarations come before accumulated units")
- [x] 1.5 Proof `Dump.canonical_perm`: permuted catalog input gives an equal dump
- [x] 1.6 Proof `LeanPrinter.derive_eq_elpi` for the kind/constructor skeleton (against a model of `deriving Elpi`'s type mapping); property test for the full output over random schemas (`tests/M5.lean`, 24 seeds)

## 2. Soufflé oracle

- [x] 2.1 Fragment classifier: first-order, cut-free, no `pi`/`=>`/constraints, stratified negation; count skips (`tests/SouffleOracle/Translate.lean`, its own parser; skips counted by reason in `run.sh`)
- [x] 2.2 Translator to Soufflé `.dl` with facts as `.facts` files, under `tests/oracle/souffle/` (proof relations keep multiplicities; facts from the generated graph)
- [x] 2.3 Harness: run both engines at full, narrowed and partitioned scope; compare answer multisets (`tests/oracle/souffle/run.sh`, `property rows`; 655 agree at size 6 over 200 seeds)
- [x] 2.4 Write reproducers to `tests/oracle/souffle/failures/` on mismatch; fault-injection test (`run.sh --self-test`)
- [x] 2.5 CI job with Soufflé on Linux (job `souffle-oracle` in `tracer-bullet.yml`, `MARIEN_ORACLE=1` in `tests/linux/run.sh` builds Soufflé 2.5 from source for arm64; first GitHub run 42215690054 on 2026-11-06: 685 comparisons agree, 0 differ, self-test passes)

## 3. Custom statements

- [x] 3.1 `CALL elpi_statement('<statement>')` for `CREATE [OR REPLACE] RULES`, `DROP RULES`, `CHECK RULES`, `VALIDATE`, `ANNOTATE`, with `$$` and `$tag$` delimiters (grammar in `Marien/Statement.lean`, text in and CALL form out in `shim/statements.cpp`; the statement transformer first registered here was removed after LadybugDB declined extension grammar, see 4.5)
- [x] 3.2 Desugar each statement to its `CALL elpi_*` form; Planner/Mapper reuse the function plan (`elpi_statement` binds through the CALL form's own bind core, so its rewrite, rows and errors are that function's)
- [x] 3.3 Proof `Statement.desugar_total` (Lean model of the statement datatype and its desugaring)
- [x] 3.4 Proof `Statement.source_roundtrip` for the delimiter lexer model; end-to-end byte test (through `elpi_statement` and the module store)
- [x] 3.5 Paired equivalence tests: each statement against its `CALL` form on random databases (`statements equal their CALL forms` in `tests/differential/property.c`, through `elpi_statement`)

## 4. Upstream proposals

- [x] 4.1 Draft and submit a LadybugDB proposal for a catalog-change hook for extensions (the eager recheck that [[decisions#Lazy recheck by schema hash]] deferred) (`docs/upstream/catalog-change-hook.md`, filed as LadybugDB/ladybug#1518)
- [x] 4.2 If accepted: subscribe to it and mark affected modules `broken` eagerly; the lazy path stays as the fallback (not accepted, 2026-11-07: catalog hooks are untenable upstream because of MVCC and ordering; the suggested WAL tailer sees DDL only after commit, on another thread, and pins the WAL, so it cannot mark modules atomically with the change. Nothing to subscribe to; the lazy recheck stays the only path)
- [x] 4.3 Build a prebuilt Lean archive (marien + LeanElpi + Lean runtime, hidden symbols) consumable from CMake (`scripts/build-lean-archive.sh`, `marien::lean`, `shim/CMakeLists.txt -DMARIEN_LEAN_ARCHIVE`; `scripts/test-lean-archive.sh` passes on macOS arm64 with no Lean on PATH; the Linux branch passes on arm64 in `tests/linux/run.sh` (2026-11-07: only the bridge API global, built without Lean, 78/78), and every release attaches the archive per OS and CPU with `SHA256SUMS-lean`; on macOS the GMP/libuv functions the Lean side calls stay global in the archive, hidden by the extension's export list)
- [ ] 4.4 Propose contributing the extension to `ladybugdb/extensions` using the prebuilt archive, so upstream CI needs no Lean toolchain (drafted in `docs/upstream/extensions-contribution.md`, not filed: needs a LICENSE file, the Linux archive run and release assets first)
- [x] 4.5 Propose a route for extension statements in LadybugDB's grammar (constraint "Only CREATE USER and CREATE ROLE reach extension parsers") (`docs/upstream/extension-statements.md`, filed as LadybugDB/ladybug#1519; declined 2026-11-07 in favour of a function over a string, which `elpi_statement` is; the transformer was removed and the spec now makes `elpi_statement` the interface)
- [ ] 4.6 Ask LadybugDB to pass a prepared statement's bound parameters to the standalone CALL rewrite (constraint "Standalone CALL rewrites run before parameters are bound"), so `CALL elpi_statement($s)` and `CALL elpi_save('m', $src)` need no escaping; once it lands, accept parameters in the write functions and turn the refusal test into a byte test (asked in #1519 on 2026-11-07; the refusal and its test are in place)

## 5. Open question: locality proof

- [x] 5.1 Optional: complete M3's stretch theorem `Locality.sound`; otherwise record in `tg.md/decisions.md` that locality rests on M3's property tests and the Soufflé oracle, and close the item in [[overview#Open questions]] (recorded as "The locality check rests on its theorem premise and two differential checks"; the open-questions list no longer carried the item)

## 6. Traceability: implements

- [x] 6.1 Annotate `@tg: implements:: [[openspec:offline-codegen#Schema dump]]` above the JSON dump code
- [x] 6.2 Annotate `@tg: implements:: [[openspec:offline-codegen#Lean inductives from the schema]]` above `LeanPrinter`
- [x] 6.3 Annotate `@tg: implements:: [[openspec:offline-codegen#Offline and runtime signatures agree]]` above the agreement check
- [x] 6.4 Annotate `@tg: implements:: [[openspec:differential-testing#Soufflé oracle]]` above the translator and harness entry point
- [x] 6.5 Annotate `@tg: implements:: [[openspec:custom-statements#Rule statements]]` above `ElpiStatement` (first above the transformer, removed with it)
- [x] 6.6 Annotate `@tg: implements:: [[openspec:custom-statements#Statements equal their CALL forms]]` above the desugaring dispatch (`ElpiStatement`)
- [x] 6.7 Annotate `@tg: implements:: [[openspec:custom-statements#Statement source is not re-escaped]]` above the delimiter lexer

## 7. Traceability: verifies

- [x] 7.1 offline-codegen tests, each with `@tg: verifies::` above it: `#Schema dump#Dump of a small schema`, `#Dump is canonical`; `#Lean inductives from the schema#Generated module builds`, `#Derived ELPI types match the runtime kinds`; `#Offline and runtime signatures agree#Agreement on random schemas`, `#Disagreement fails the tool`
- [x] 7.2 differential-testing tests: `#Soufflé oracle#Agreement on a validation rule`, `#Agreement under partitioning`, `#Out-of-fragment modules are skipped`, `#Mismatch leaves a reproducer`
- [x] 7.3 custom-statements tests: `#Rule statements#Create rules from a statement`, `#Malformed statement`, `#A query parameter is refused`; `#Statements equal their CALL forms#VALIDATE equals elpi_validate`, `#Errors are identical`; `#Statement source is not re-escaped#Quotes and backslashes survive`, `#Tagged delimiter`

## 8. Docs and graph

- [x] 8.1 Record the design's decisions (one encoding with two printers, the oracle fragment, desugaring in the binder) in `tg.md/decisions.md` with `motivated_by::` edges
- [ ] 8.2 Add `constrains:: [[openspec:custom-statements#Rule statements]] {strength: must}` to [[constraints#Extensions are C++ shared libraries]] (a doc edge to a requirement of an unarchived change does not resolve in `tg check`; add it with the archive)
- [x] 8.3 Add the Offline codegen and Statement extension sections to `tg.md/architecture/components.md`; add `offline-codegen`, `differential-testing` and `custom-statements` to its `openspec:` frontmatter
- [x] 8.4 Register `add-ecosystem` in `tg.md/changes.md`
- [x] 8.5 Run `tg check`, `tg ontology check`, and `tg trace offline-codegen --gaps`, `tg trace differential-testing --gaps`, `tg trace custom-statements --gaps`; close every gap
