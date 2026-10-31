## 1. Offline codegen

- [ ] 1.1 `elpi_signature(format := 'json')`: canonical schema dump, without `_elpi_*`, keys sorted
- [ ] 1.2 Split printing out of the signature generator behind `SignaturePrinter`; move the existing printer into `ElpiPrinter`
- [ ] 1.3 `Marien/Offline/Codegen.lean`: `LeanPrinter` emitting one `inductive … deriving Elpi` per kind (node, reified edge, union endpoint, STRUCT record)
- [ ] 1.4 `lake exe marien-codegen <dump.json> -o <Module.lean>`; elaborate the emitted module, read the derived signature, compare with `ElpiPrinter`, exit non-zero naming the first difference
- [ ] 1.5 Proof `Dump.canonical_perm`: permuted catalog input gives an equal dump
- [ ] 1.6 Proof `LeanPrinter.derive_eq_elpi` for the kind/constructor skeleton; property test for the full output over random schemas

## 2. Soufflé oracle

- [ ] 2.1 Fragment classifier: first-order, cut-free, no `pi`/`=>`/constraints, stratified negation; count skips
- [ ] 2.2 Translator to Soufflé `.dl` with facts as `.facts` files, under `tests/oracle/souffle/`
- [ ] 2.3 Harness: run both engines at full, narrowed and partitioned scope; compare answer multisets
- [ ] 2.4 Write reproducers to `tests/oracle/souffle/failures/` on mismatch; fault-injection test
- [ ] 2.5 CI job with Soufflé on Linux

## 3. Custom statements

- [ ] 3.1 `shim/statements.cpp`: Transformer for `CREATE [OR REPLACE] RULES`, `DROP RULES`, `CHECK RULES`, `VALIDATE`, `ANNOTATE`, with `$$` and `$tag$` delimiters
- [ ] 3.2 Binder: desugar each statement to its `CALL elpi_*` bound form; Planner/Mapper reuse the function plan
- [ ] 3.3 Proof `Statement.desugar_total` (Lean model of the statement datatype and its desugaring)
- [ ] 3.4 Proof `Statement.source_roundtrip` for the delimiter lexer model; end-to-end byte test
- [ ] 3.5 Paired equivalence tests: each statement against its `CALL` form on random databases

## 4. Upstream proposals

- [ ] 4.1 Draft and submit a LadybugDB proposal for a catalog-change hook for extensions (the eager recheck that [[decisions#Lazy recheck by schema hash]] deferred)
- [ ] 4.2 If accepted: subscribe to it and mark affected modules `broken` eagerly; the lazy path stays as the fallback
- [ ] 4.3 Build a prebuilt Lean archive (marien + LeanElpi + Lean runtime, hidden symbols) consumable from CMake
- [ ] 4.4 Propose contributing the extension to `ladybugdb/extensions` using the prebuilt archive, so upstream CI needs no Lean toolchain

## 5. Open question: locality proof

- [ ] 5.1 Optional: complete M3's stretch theorem `Locality.sound`; otherwise record in `tg.md/decisions.md` that locality rests on M3's property tests and the Soufflé oracle, and close the item in [[overview#Open questions]]

## 6. Traceability: implements

- [ ] 6.1 Annotate `@tg: implements:: [[openspec:offline-codegen#Schema dump]]` above the JSON dump code
- [ ] 6.2 Annotate `@tg: implements:: [[openspec:offline-codegen#Lean inductives from the schema]]` above `LeanPrinter`
- [ ] 6.3 Annotate `@tg: implements:: [[openspec:offline-codegen#Offline and runtime signatures agree]]` above the agreement check
- [ ] 6.4 Annotate `@tg: implements:: [[openspec:differential-testing#Soufflé oracle]]` above the translator and harness entry point
- [ ] 6.5 Annotate `@tg: implements:: [[openspec:custom-statements#Rule statements]]` above the Transformer
- [ ] 6.6 Annotate `@tg: implements:: [[openspec:custom-statements#Statements equal their CALL forms]]` above the Binder desugaring
- [ ] 6.7 Annotate `@tg: implements:: [[openspec:custom-statements#Statement source is not re-escaped]]` above the delimiter lexer

## 7. Traceability: verifies

- [ ] 7.1 offline-codegen tests, each with `@tg: verifies::` above it: `#Schema dump#Dump of a small schema`, `#Dump is canonical`; `#Lean inductives from the schema#Generated module builds`, `#Derived ELPI types match the runtime kinds`; `#Offline and runtime signatures agree#Agreement on random schemas`, `#Disagreement fails the tool`
- [ ] 7.2 differential-testing tests: `#Soufflé oracle#Agreement on a validation rule`, `#Agreement under partitioning`, `#Out-of-fragment modules are skipped`, `#Mismatch leaves a reproducer`
- [ ] 7.3 custom-statements tests: `#Rule statements#Create rules from a statement`, `#Malformed statement`; `#Statements equal their CALL forms#VALIDATE equals elpi_validate`, `#Errors are identical`; `#Statement source is not re-escaped#Quotes and backslashes survive`, `#Tagged delimiter`

## 8. Docs and graph

- [ ] 8.1 Record the design's decisions (one encoding with two printers, the oracle fragment, desugaring in the binder) in `tg.md/decisions.md` with `motivated_by::` edges
- [ ] 8.2 Add `constrains:: [[openspec:custom-statements#Rule statements]] {strength: must}` to [[constraints#Extensions are C++ shared libraries]]
- [ ] 8.3 Add the Offline codegen and Statement extension sections to `tg.md/architecture/components.md`; add `offline-codegen`, `differential-testing` and `custom-statements` to its `openspec:` frontmatter
- [ ] 8.4 Register `add-ecosystem` in `tg.md/changes.md`
- [ ] 8.5 Run `tg check`, `tg ontology check`, and `tg trace offline-codegen --gaps`, `tg trace differential-testing --gaps`, `tg trace custom-statements --gaps`; close every gap
