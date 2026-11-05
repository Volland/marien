## 1. Schema reflection

- [x] 1.1 `Marien/Meta/Reflect.lean`: `Reflect.ofSchema : SchemaModel → Annotations → List Fact` emitting `schema.node`, `schema.rel` (one per FROM/TO pair), `schema.prop` with the closed `schema.ty` kind, and `schema.annot`, sorted (`facts` over the visible schema, rendered and sorted by `ofSchema`; also `schema.key`, `schema.ident`, `schema.prop_ident`; annotations are part of the `Schema` model)
- [x] 1.2 Filter `_elpi_*` tables, columns and annotations before emitting
- [x] 1.3 System table `_elpi_annotation(table, key, value)` created on `LOAD marien` (created by `elpi_init` with the other system tables, since `LOAD` cannot write; columns `id, table_name, key, value`, `table` being reserved)
- [x] 1.4 `elpi_annotate(table, key, value)` through `rewriteFunc`: insert or replace, delete on empty value, error on an unknown table
- [x] 1.5 Include annotations of reached tables in each module's schema hash (the reached-table hash covers reached tables' annotations; a staged module hashes the whole schema)
- [x] 1.6 Proof `Reflect.ofSchema_no_system`: no emitted fact names a table with prefix `_elpi_`
- [x] 1.7 Proof `Reflect.ofSchema_perm`: permuting the catalog input leaves the output unchanged

## 2. Staged rule generation

- [x] 2.1 Parse a module's `meta` section; check that it declares `pred generate o:string.` (between `% @marien meta` and `% @marien end`, `Stage.split`)
- [x] 2.2 `Marien/Meta/Stage.lean`: run `generate` over the description and the meta-rules under fuel, time and `elpi_max_generated_bytes` limits; concatenate solutions in order (fuel and `elpi_max_generated_bytes`, not time: a clock would make the text depend on time)
- [x] 2.3 Reject database predicates in stage 1 with a dedicated error (recognised from the compile error, since stage 1 has no signature)
- [x] 2.4 Load `source ++ generated` through the same path as hand-written code: typecheck, then the M3 analysis
- [x] 2.5 Map errors to positions in the generated text, with the producing meta-rule solution
- [x] 2.6 Store `generated` and its schema hash on `_elpi_module`; lazy regeneration updates only the handle cache; `elpi_recheck` persists it
- [x] 2.7 `elpi_export` omits `generated`; `elpi_import` regenerates (export was already sources only; import runs `check`, which regenerates)
- [x] 2.8 Proof `Stage.generate_deterministic`: `generate` is pure in (description, source) (and `Stage.generate_perm`: catalog order does not change the text)
- [x] 2.9 Proof `Stage.heads_declared`: every emitted clause head is declared in the module or in `Signature.ofSchema` (`Stage.checkHeads`, with `heads_declared` proving it)

## 3. Dynamic entry points

- [x] 3.1 Extend the rule analyzer: an entry point is `dynamic` when it reaches `=>` with a database-predicate clause head (from M3; generated code goes through the same analysis)
- [x] 3.2 Accept `dynamic <pred>.` declarations; ignore attempts to mark an inferred-dynamic entry point non-dynamic (as `% @marien dynamic <pred>`, from M3; `% @marien static` cannot clear an inferred mark)
- [x] 3.3 Reject narrowed-scope and partitioned calls to dynamic entry points with an error citing the clause (the partition error says dynamic entry points run at full scope only; a run fails the same way when generated code turns dynamic after the save)

## 4. graph.std

- [x] 4.1 `lib/graph/std.elpi`: `edge_of`, `closure` (with a visited set, terminating on cycles), `symmetric_witness`, `functional_witness`
- [x] 4.2 `acyclic`, `acyclic_witness`, with a variant that reads `in_cycle` when structural facts are loaded (`acyclic_witness_in in_cycle.<rel>` for the structural facts)
- [x] 4.3 `card`, `card_witness` with `-1` meaning unbounded and nodes without edges counted as 0 (`card_witness` takes the node predicate first: a polymorphic library cannot enumerate a kind)
- [x] 4.4 Locality metadata in the library, checked by the analysis (`% @marien local`/`nonlocal` lines in the library, tested against the check in `tests/M4.lean`; the check now inlines combinators with their relation arguments)
- [x] 4.5 Lean reference implementations in `tests/GraphStd/Reference.lean` and property tests comparing answer sets on random finite relations (`tests/GraphStd/`: 60 random relations)
- [ ] 4.6 Optional: prove the Lean reference `closure` equal to the transitive closure (`Reference.closure_spec`)

## 5. Traceability: implements

- [x] 5.1 Annotate `@tg: implements:: [[openspec:schema-reflection#Reflected schema description]]` above `Reflect.ofSchema`
- [x] 5.2 Annotate `@tg: implements:: [[openspec:schema-reflection#System tables are not reflected]]` above the system-table filter
- [x] 5.3 Annotate `@tg: implements:: [[openspec:schema-reflection#Schema annotations]]` above the `elpi_annotate` binder/rewrite
- [x] 5.4 Annotate `@tg: implements:: [[openspec:rule-generation#Stage one meta-rules]]` above the stage 1 driver
- [x] 5.5 Annotate `@tg: implements:: [[openspec:rule-generation#Generated code is checked like source]]` above the shared load path
- [x] 5.6 Annotate `@tg: implements:: [[openspec:rule-generation#Generated code depends only on schema and source]]` above `Stage.generate`
- [x] 5.7 Annotate `@tg: implements:: [[openspec:rule-generation#Inspectable generated code]]` above the `generated` persistence code
- [x] 5.8 Annotate `@tg: implements:: [[openspec:rule-generation#Dynamic entry points]]` above the `dynamic` inference
- [x] 5.9 Annotate `@tg: implements:: [[openspec:graph-std#Relation combinators]]`, `#Cycle detection`, `#Cardinality checks` and `#Combinators in violation rules` at the top of the corresponding sections of `lib/graph/std.elpi` (ELPI `%` comments) (tg does not read ELPI comments, so the edges are repeated on `GraphStd.source`)

## 6. Traceability: verifies

- [x] 6.1 schema-reflection tests, each with `@tg: verifies::` above it: `#Reflected schema description#Node and rel tables are reflected`, `#Multi-pair rel tables give one fact per pair`, `#Reflection typechecks without rigid-variable conflicts`; `#System tables are not reflected#Module storage stays invisible`; `#Schema annotations#Annotation appears in reflection`, `#Annotating an unknown table fails`, `#Annotation change triggers regeneration`
- [x] 6.2 rule-generation tests: `#Stage one meta-rules#Per-table clauses from an annotation`, `#Stage one sees no data`, `#Unparseable output fails the save`; `#Generated code is checked like source#Ill-typed generated clause is rejected`, `#Generated negation affects narrowed scope`; `#Generated code depends only on schema and source#Regeneration is byte-identical`, `#Catalog order does not matter`; `#Inspectable generated code#Generated code is queryable`, `#Export omits derived code`; `#Dynamic entry points#Hypothetical database facts make an entry point dynamic`, `#Dynamic entry points are never partitioned`, `#Local hypotheticals stay static`
- [x] 6.3 graph-std tests: `#Relation combinators#Closure over a relation`, `#Closure terminates on cycles`, `#One combinator, two relations`, `#Functional witness`; `#Cycle detection#Witnesses on a cycle`, `#Precomputed facts agree with search`; `#Cardinality checks#Missing mandatory edge`, `#Unbounded maximum`; `#Combinators in violation rules#Cardinality rule partitions by anchor`, `#Search-based cycle rule cannot be anchor-partitioned`

## 7. Docs and graph

- [x] 7.1 Record the design's decisions in `tg.md/decisions.md` (or refine [[decisions#Staged rule generation over a reflected schema]]) with `motivated_by::` edges, and the new limit `elpi_max_generated_bytes`
- [x] 7.2 Add `constrains:: [[openspec:rule-generation#Stage one meta-rules]] {strength: must}` to [[constraints#Clause type variables are rigid]]
- [x] 7.3 Add the Schema reflector, Rule generator and Graph standard library sections to `tg.md/architecture/components.md`; add `schema-reflection`, `rule-generation` and `graph-std` to its `openspec:` frontmatter
- [x] 7.4 Register `add-higher-order-layer` in `tg.md/changes.md`
- [x] 7.5 Run `tg check`, `tg ontology check`, and `tg trace schema-reflection --gaps`, `tg trace rule-generation --gaps`, `tg trace graph-std --gaps`; close every gap
