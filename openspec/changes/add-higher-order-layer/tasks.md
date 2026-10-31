## 1. Schema reflection

- [ ] 1.1 `Marien/Meta/Reflect.lean`: `Reflect.ofSchema : SchemaModel → Annotations → List Fact` emitting `schema.node`, `schema.rel` (one per FROM/TO pair), `schema.prop` with the closed `schema.ty` kind, and `schema.annot`, sorted
- [ ] 1.2 Filter `_elpi_*` tables, columns and annotations before emitting
- [ ] 1.3 System table `_elpi_annotation(table, key, value)` created on `LOAD marien`
- [ ] 1.4 `elpi_annotate(table, key, value)` through `rewriteFunc`: insert or replace, delete on empty value, error on an unknown table
- [ ] 1.5 Include annotations of reached tables in each module's schema hash
- [ ] 1.6 Proof `Reflect.ofSchema_no_system`: no emitted fact names a table with prefix `_elpi_`
- [ ] 1.7 Proof `Reflect.ofSchema_perm`: permuting the catalog input leaves the output unchanged

## 2. Staged rule generation

- [ ] 2.1 Parse a module's `meta` section; check that it declares `pred generate o:string.`
- [ ] 2.2 `Marien/Meta/Stage.lean`: run `generate` over the description and the meta-rules under fuel, time and `elpi_max_generated_bytes` limits; concatenate solutions in order
- [ ] 2.3 Reject database predicates in stage 1 with a dedicated error
- [ ] 2.4 Load `source ++ generated` through the same path as hand-written code: typecheck, then the M3 analysis
- [ ] 2.5 Map errors to positions in the generated text, with the producing meta-rule solution
- [ ] 2.6 Store `generated` and its schema hash on `_elpi_module`; lazy regeneration updates only the handle cache; `elpi_recheck` persists it
- [ ] 2.7 `elpi_export` omits `generated`; `elpi_import` regenerates
- [ ] 2.8 Proof `Stage.generate_deterministic`: `generate` is pure in (description, source)
- [ ] 2.9 Proof `Stage.heads_declared`: every emitted clause head is declared in the module or in `Signature.ofSchema`

## 3. Dynamic entry points

- [ ] 3.1 Extend the rule analyzer: an entry point is `dynamic` when it reaches `=>` with a database-predicate clause head
- [ ] 3.2 Accept `dynamic <pred>.` declarations; ignore attempts to mark an inferred-dynamic entry point non-dynamic
- [ ] 3.3 Reject narrowed-scope and partitioned calls to dynamic entry points with an error citing the clause

## 4. graph.std

- [ ] 4.1 `lib/graph/std.elpi`: `edge_of`, `closure` (with a visited set, terminating on cycles), `symmetric_witness`, `functional_witness`
- [ ] 4.2 `acyclic`, `acyclic_witness`, with a variant that reads `in_cycle` when structural facts are loaded
- [ ] 4.3 `card`, `card_witness` with `-1` meaning unbounded and nodes without edges counted as 0
- [ ] 4.4 Locality metadata in the library, checked by the analysis
- [ ] 4.5 Lean reference implementations in `tests/GraphStd/Reference.lean` and property tests comparing answer sets on random finite relations
- [ ] 4.6 Optional: prove the Lean reference `closure` equal to the transitive closure (`Reference.closure_spec`)

## 5. Traceability: implements

- [ ] 5.1 Annotate `@tg: implements:: [[openspec:schema-reflection#Reflected schema description]]` above `Reflect.ofSchema`
- [ ] 5.2 Annotate `@tg: implements:: [[openspec:schema-reflection#System tables are not reflected]]` above the system-table filter
- [ ] 5.3 Annotate `@tg: implements:: [[openspec:schema-reflection#Schema annotations]]` above the `elpi_annotate` binder/rewrite
- [ ] 5.4 Annotate `@tg: implements:: [[openspec:rule-generation#Stage one meta-rules]]` above the stage 1 driver
- [ ] 5.5 Annotate `@tg: implements:: [[openspec:rule-generation#Generated code is checked like source]]` above the shared load path
- [ ] 5.6 Annotate `@tg: implements:: [[openspec:rule-generation#Generated code depends only on schema and source]]` above `Stage.generate`
- [ ] 5.7 Annotate `@tg: implements:: [[openspec:rule-generation#Inspectable generated code]]` above the `generated` persistence code
- [ ] 5.8 Annotate `@tg: implements:: [[openspec:rule-generation#Dynamic entry points]]` above the `dynamic` inference
- [ ] 5.9 Annotate `@tg: implements:: [[openspec:graph-std#Relation combinators]]`, `#Cycle detection`, `#Cardinality checks` and `#Combinators in violation rules` at the top of the corresponding sections of `lib/graph/std.elpi` (ELPI `%` comments)

## 6. Traceability: verifies

- [ ] 6.1 schema-reflection tests, each with `@tg: verifies::` above it: `#Reflected schema description#Node and rel tables are reflected`, `#Multi-pair rel tables give one fact per pair`, `#Reflection typechecks without rigid-variable conflicts`; `#System tables are not reflected#Module storage stays invisible`; `#Schema annotations#Annotation appears in reflection`, `#Annotating an unknown table fails`, `#Annotation change triggers regeneration`
- [ ] 6.2 rule-generation tests: `#Stage one meta-rules#Per-table clauses from an annotation`, `#Stage one sees no data`, `#Unparseable output fails the save`; `#Generated code is checked like source#Ill-typed generated clause is rejected`, `#Generated negation affects narrowed scope`; `#Generated code depends only on schema and source#Regeneration is byte-identical`, `#Catalog order does not matter`; `#Inspectable generated code#Generated code is queryable`, `#Export omits derived code`; `#Dynamic entry points#Hypothetical database facts make an entry point dynamic`, `#Dynamic entry points are never partitioned`, `#Local hypotheticals stay static`
- [ ] 6.3 graph-std tests: `#Relation combinators#Closure over a relation`, `#Closure terminates on cycles`, `#One combinator, two relations`, `#Functional witness`; `#Cycle detection#Witnesses on a cycle`, `#Precomputed facts agree with search`; `#Cardinality checks#Missing mandatory edge`, `#Unbounded maximum`; `#Combinators in violation rules#Cardinality rule partitions by anchor`, `#Search-based cycle rule cannot be anchor-partitioned`

## 7. Docs and graph

- [ ] 7.1 Record the design's decisions in `tg.md/decisions.md` (or refine [[decisions#Staged rule generation over a reflected schema]]) with `motivated_by::` edges, and the new limit `elpi_max_generated_bytes`
- [ ] 7.2 Add `constrains:: [[openspec:rule-generation#Stage one meta-rules]] {strength: must}` to [[constraints#Clause type variables are rigid]]
- [ ] 7.3 Add the Schema reflector, Rule generator and Graph standard library sections to `tg.md/architecture/components.md`; add `schema-reflection`, `rule-generation` and `graph-std` to its `openspec:` frontmatter
- [ ] 7.4 Register `add-higher-order-layer` in `tg.md/changes.md`
- [ ] 7.5 Run `tg check`, `tg ontology check`, and `tg trace schema-reflection --gaps`, `tg trace rule-generation --gaps`, `tg trace graph-std --gaps`; close every gap
