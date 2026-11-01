## 1. Typed entry points

- [x] 1.1 Value codec column map: kind → primary-key type, `int`, `float`, `string`, `list T`, record kinds (`Marien/Codec.lean`) (in `Marien/Encoding/Codec.lean`: `Col`, `colOfTy`, `colOfLType`)
- [x] 1.2 `elpi_run` bind: handle lookup, engine signature, column declaration, parameter decoding with named errors (`Marien/Exec/Run.lean`, `shim/functions.cpp`) (`prepareRun` and `bindArgs` in `Marien/Exec/Run.lean`; the binder in `shim/extension.cpp`)
- [x] 1.3 `elpi_run` execute: decode structured result terms to rows (cells as typed prefix tokens, `rowCells` and `parseCell`)
- [x] 1.4 Prove `Marien.Codec.value_roundtrip` (with `decodeC_sound`, the converse on terms that decode)

## 2. Validation

- [x] 2.1 Generate `severity` and the `subject` union in the signature generator; exclude `_elpi_*` tables
- [x] 2.2 Check the `violation` signature at save time; optional `violation_message` (`checkProtocol` in `Marien/Store/Module.lean`)
- [x] 2.3 `elpi_validate` with module ordering, severity filter and fail-whole-call on any module failure (`Marien/Exec/Validate.lean`)
- [x] 2.4 Prove `Marien.Codec.subject_decode_encode` and `Marien.Codec.subject_encode_decode`
- [x] 2.5 Prove `Marien.Validate.filter_sound`

## 3. Schema evolution

- [x] 3.1 Reached-table set at save time through `accumulate`; canonical catalog serialization; hash stored in `_elpi_module` (`Derived.reached`, `Schema.reachedHash`; accumulated modules' reach comes from their stored metadata)
- [x] 3.2 Bind-time hash check, in-memory regeneration and handle-cache insert under the new hash; no fallback (`compiledFor`: the reached hash is part of the cache key)
- [x] 3.3 `status` column (`ok`, `stale`, `broken`) and stored error (`error` column added by `elpi_init`, also to tables of M1)
- [x] 3.4 `elpi_recheck` with one `rewriteFunc` statement for all listed modules
- [x] 3.5 Prove `Marien.Schema.hash_restrict` and `Marien.Schema.hash_perm`

## 4. Distribution

- [x] 4.1 `lake` target for the static archive; CMake project in `shim/`; `scripts/build-extension.sh`; pinned version file (`scripts/build-extension.sh`, `scripts/check-one-library.sh`)
- [x] 4.2 Hidden visibility and an exported-symbol check in CI (`scripts/check-exports.sh` in CI)
- [x] 4.3 Load-time version check that refuses to register functions on mismatch (exact through liblbug's `Version::getVersion`; by storage version in the CLI, which does not export it)
- [ ] 4.4 CI matrix (LadybugDB version × macOS/Linux × arm64/x86_64), artifact naming, release blocked by any failing entry (written: `.github/workflows/release.yml` over `scripts/release-matrix.sh`, shape checked by `scripts/check-release-workflow.sh`; open until a tag runs it, the x86_64 entries have never been built)
- [ ] 4.5 Extension server layout and an install-and-load CI job (layout: `scripts/package-extension.sh`; CI downloads from it and loads by path, `scripts/test-install.sh`. Blocked: LadybugDB 0.22.1 refuses `INSTALL marien FROM` and `LOAD marien` because only official names may be installed, see constraint "INSTALL accepts only official extensions"; needs an upstream change or a spec change)

## 5. Traceability annotations

- [x] 5.1 `@tg: implements:: [[openspec:rule-execution#Typed entry points]]` above the `elpi_run` binder; `@tg: verifies::` above the tests for scenarios "Output columns are typed at bind time", "Node results come back as primary keys", "Bad parameters fail the bind", "Predicates without modes are rejected", "Strings round-trip without printing"
- [x] 5.2 `@tg: implements:: [[openspec:validation#Violation protocol]]` above the save-time check; `@tg: verifies::` for "Module with violation takes part", "Wrong signature is rejected", "Reasoning modules are skipped"
- [x] 5.3 `@tg: implements:: [[openspec:validation#Subject union kind]]` above the generator and codec; `@tg: verifies::` for "One constructor per table", "Subject decodes to label and key", "Subject codec round-trips" (the round-trip theorem carries the annotation)
- [x] 5.4 `@tg: implements:: [[openspec:validation#Uniform validation report]]` above `elpi_validate`; `@tg: verifies::` for "Report across modules", "Severity filter", "A failing module fails the call"
- [x] 5.5 `@tg: implements:: [[openspec:schema-evolution#Reached-table schema hash]]`; `@tg: verifies::` for "Unrelated DDL keeps the hash", "Reached DDL changes the hash", "Catalog order does not matter"
- [x] 5.6 `@tg: implements:: [[openspec:schema-evolution#Lazy recheck on run]]`; `@tg: verifies::` for "Compatible change recompiles in memory", "Breaking change fails the run"
- [x] 5.7 `@tg: implements:: [[openspec:schema-evolution#Broken module status]]`; `@tg: verifies::` for "Recheck marks a module broken", "Saving clears broken"
- [x] 5.8 `@tg: implements:: [[openspec:schema-evolution#Explicit recheck]]`; `@tg: verifies::` for "Recheck persists regenerated modules", "Recheck is atomic"
- [x] 5.9 `@tg: implements:: [[openspec:distribution#Out-of-tree build]]` on the build script and CMake project; `@tg: verifies::` for "One file is produced", "Only entry points are exported"
- [x] 5.10 `@tg: implements:: [[openspec:distribution#Build matrix]]` on the CI workflow; `@tg: verifies::` for "Artifact names carry the matrix entry", "One failing entry blocks the release"
- [ ] 5.11 `@tg: implements:: [[openspec:distribution#Install from extension server]]`; `@tg: verifies::` for "Install and load" (implements is partial on `scripts/package-extension.sh`; the scenario stays unverified, see 4.5)
- [x] 5.12 `@tg: implements:: [[openspec:distribution#LadybugDB version check]]`; `@tg: verifies::` for "Mismatched database is refused"

## 6. Knowledge graph

- [x] 6.1 Record any new decisions and constraints from design.md in `tg.md/decisions.md` and `tg.md/constraints.md` with `motivated_by::` and `constrains:: [[openspec:<capability>#<Requirement>]] {strength: must}` edges
- [x] 6.2 Update the component sections for Validator, Executor, Value codec, Signature generator, Module store, Handle cache and Extension shim; add `validation`, `schema-evolution`, `distribution` and `rule-execution` to the `openspec:` frontmatter of `tg.md/architecture/components.md`
- [x] 6.3 Register the change in `tg.md/changes.md` as `add-typed-validation`
- [ ] 6.4 Run `tg check`, `tg ontology check`, and `tg trace validation --gaps`, `tg trace schema-evolution --gaps`, `tg trace distribution --gaps`, `tg trace rule-execution --gaps`; close every gap
