## 1. Project skeleton

- [ ] 1.1 `lakefile.lean` with the `Marien` library, `lean-elpi` pinned at `v0.4.0`, and a static archive target
- [ ] 1.2 `shim/` CMake project pinned to the LadybugDB release, reusing the spike's link recipe, export list and size check
- [ ] 1.3 Check whether `rewriteFunc` can return a statement with several clauses (MERGE plus edge replacement); record the answer and choose the statement shape
- [ ] 1.4 CI: build, size check, dependency and symbol checks, Lean tests, integration tests against an embedded LadybugDB

## 2. Schema encoding

- [ ] 2.1 Catalog reader (C++): serialize node tables, rel tables, FROM/TO pairs, keys and property types to JSON
- [ ] 2.2 `Marien/Schema.lean`: schema model, JSON decoding, `_elpi_*` filter, canonical form and hash
- [ ] 2.3 `Marien/Encoding/Signature.lean`: snake-case naming with collision check, node and rel declarations, union endpoint kinds, type mapping with warnings
- [ ] 2.4 `Marien/Encoding/Codec.lean`: database value ↔ term for every supported type, range checks
- [ ] 2.5 `elpi_signature([table])`

## 3. Rule storage

- [ ] 3.1 `elpi_init()` creating `_elpi_module` and `_elpi_accumulates`
- [ ] 3.2 `Marien/Store/Module.lean`: save pipeline (load units, type check, derived metadata from the public AST, accumulate cycle check), escaping, rewrite text
- [ ] 3.3 `elpi_save`, `elpi_drop`, `elpi_export`, `elpi_import` table functions with `rewriteFunc`
- [ ] 3.4 `Marien/Store/Cache.lean`: LRU handle cache keyed by `(name, version, schemaHash)`, option `elpi_cache_size`

## 4. Rule execution

- [ ] 4.1 Table scanner (C++): scan node and rel tables in the caller's transaction into column batches
- [ ] 4.2 Materializer: tables from derived metadata, codec, `addFacts` per batch, `elpi_max_facts`
- [ ] 4.3 `Marien/Exec/Run.lean`: parse goal, fresh store, slice loop with resumable slices
- [ ] 4.4 `elpi_query` table function, not parallel, checking interrupt and deadline between slices, rows `(sol, var, value, exhausted)`
- [ ] 4.5 Options `elpi_fuel`, `elpi_timeout_ms`, `elpi_max_solutions`, `elpi_max_facts`, `elpi_slice_steps`, registered with LadybugDB's extension options

## 5. Proofs

- [ ] 5.1 Prove `assignNames_injective`
- [ ] 5.2 Prove `signature_excludes_system`
- [ ] 5.3 Prove `canonical_perm`
- [ ] 5.4 Prove `Codec.decode_encode` for every supported type, including LIST and STRUCT
- [ ] 5.5 Define the model of Cypher string-literal lexing and prove `unescape_escape` and `escape_no_delim`

## 6. Traceability: schema-encoding

- [ ] 6.1 Annotate `implements:: [[openspec:schema-encoding#Schema model from the catalog]]`, and add `verifies` for `#Node and rel tables are read`
- [ ] 6.2 Annotate `implements:: [[openspec:schema-encoding#Injective naming]]`, and add `verifies` for `#Snake-case mapping` and `#Collision is an error` (cite `assignNames_injective`)
- [ ] 6.3 Annotate `implements:: [[openspec:schema-encoding#Node table encoding]]`, and add `verifies` for `#Generated node declarations` and `#Null is an absent fact`
- [ ] 6.4 Annotate `implements:: [[openspec:schema-encoding#Rel table encoding]]`, and add `verifies` for `#Single-pair rel`, `#Multi-pair rel` and `#Parallel edges stay distinct`
- [ ] 6.5 Annotate `implements:: [[openspec:schema-encoding#Property type mapping]]`, and add `verifies` for `#Temporal values as epoch integers`, `#Unsupported type is skipped with a warning` and `#Out-of-range integer fails`
- [ ] 6.6 Annotate `implements:: [[openspec:schema-encoding#System tables are invisible to rules]]`, and add `verifies` for `#Module cannot read its own storage` (cite `signature_excludes_system`)
- [ ] 6.7 Annotate `implements:: [[openspec:schema-encoding#Canonical schema hash]]`, and add `verifies` for `#Order does not matter` (cite `canonical_perm`) and `#Type change changes the hash`
- [ ] 6.8 Annotate `implements:: [[openspec:schema-encoding#Value codec round-trip]]`, and add `verifies` for `#Every supported type round-trips` (cite `Codec.decode_encode`)
- [ ] 6.9 Annotate `implements:: [[openspec:schema-encoding#Signature inspection]]`, and add `verifies` for `#Show one table`

## 7. Traceability: rule-storage

- [ ] 7.1 Annotate `implements:: [[openspec:rule-storage#Module system tables]]`, and add `verifies` for `#Init is idempotent` and `#Missing tables are explained`
- [ ] 7.2 Annotate `implements:: [[openspec:rule-storage#Save checks before storing]]`, and add `verifies` for `#Ill-typed module is rejected` and `#Version increases`
- [ ] 7.3 Annotate `implements:: [[openspec:rule-storage#Source is stored byte for byte]]`, and add `verifies` for `#Hostile characters survive` and `#Source cannot escape its literal` (cite `unescape_escape`, `escape_no_delim`)
- [ ] 7.4 Annotate `implements:: [[openspec:rule-storage#Derived module metadata]]`, and add `verifies` for `#Called generated predicates are listed`
- [ ] 7.5 Annotate `implements:: [[openspec:rule-storage#Accumulate dependencies]]`, and add `verifies` for `#Missing dependency` and `#Cycle is rejected`
- [ ] 7.6 Annotate `implements:: [[openspec:rule-storage#Drop protects dependents]]`, and add `verifies` for `#Dependent blocks drop`
- [ ] 7.7 Annotate `implements:: [[openspec:rule-storage#Export and import]]`, and add `verifies` for `#Round trip through a bundle` and `#One bad module aborts the import`
- [ ] 7.8 Annotate `implements:: [[openspec:rule-storage#Compiled handle cache]]`, and add `verifies` for `#Second run reuses the program` and `#New version is a new entry`

## 8. Traceability: rule-execution

- [ ] 8.1 Annotate `implements:: [[openspec:rule-execution#Full-scope materialization]]`, and add `verifies` for `#Facts reflect the calling transaction` and `#Unused tables are not loaded`
- [ ] 8.2 Annotate `implements:: [[openspec:rule-execution#Untyped debug query]]`, and add `verifies` for `#Bindings as rows` and `#Goal with a syntax error`
- [ ] 8.3 Annotate `implements:: [[openspec:rule-execution#Fuel-sliced execution]]`, and add `verifies` for `#Cancellation stops a runaway rule` and `#Slicing does not change answers`
- [ ] 8.4 Annotate `implements:: [[openspec:rule-execution#Execution limits are errors]]`, and add `verifies` for `#Fuel exhaustion is an error`, `#Fact budget is checked before solving` and `#Solution limit is reported`
- [ ] 8.5 Annotate `implements:: [[openspec:rule-execution#Fresh store per call]]`, and add `verifies` for `#Memory returns after a run`

## 9. lat.md and checks

- [ ] 9.1 Record the design's decisions in lat.md as `Decision` sections, or extend existing ones: catalog as JSON with data as column batches, snake-case naming with collision check, edge ids as internal ids, explicit `elpi_init`, one rewritten statement per write. Give each a `motivated_by::` edge to [[constraints#Table functions can rewrite into Cypher]], [[decisions#Scan tables in the calling transaction]] or the relevant decision
- [ ] 9.2 Add or update constraints found during the build (storage API access, `rewriteFunc` statement shape) with `source::` lines and `constrains::` edges to the affected requirements, for example `- constrains:: [[openspec:rule-storage#Save checks before storing]] {strength: must}`
- [ ] 9.3 Update the component sections introduced here and add `schema-encoding`, `rule-storage` and `rule-execution` to the `openspec:` frontmatter of `tg.md/architecture/components.md`
- [ ] 9.4 Run `tg check`, `tg ontology check`, and `tg trace schema-encoding --gaps`, `tg trace rule-storage --gaps` and `tg trace rule-execution --gaps`, and close every gap they report
