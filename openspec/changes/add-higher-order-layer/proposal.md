## Why

Up to M3, Marien runs λProlog rules over a typed encoding of the graph, but every rule names concrete predicates: a constraint such as "this relation is acyclic" has to be written once per rel table. The point of the project is higher-order rules over a typed schema: rules that quantify over the schema itself ("every rel table annotated `acyclic` must be acyclic") and a library of combinators that take relations as arguments.

A single polymorphic `schema.rel` predicate cannot typecheck in LeanElpi, because clause type variables are rigid ([[constraints#Clause type variables are rigid]]). And clauses created during a run would escape the monotonicity and locality checks from M3. This change therefore generates code in stages: meta-rules run over a monomorphic, plain-data description of the schema and emit clause text, which then passes through the same type checker and analysis as hand-written code.

**Milestone:** M4.

**Depends on:** `add-analysis-and-partitioning` (M3), for the rule analysis (reachability, monotonicity, `dynamic` inference, locality) that generated code must pass. `add-typed-validation` (M2), for `violation`, `elpi_validate` and the lazy recheck by schema hash that triggers regeneration. `add-tracer-bullet` (M1), for the schema model, signature generator and module store.

## What Changes

- **Schema reflection.** A deep, monomorphic description of the schema as ELPI facts (`schema.node`, `schema.rel Name From To`, `schema.prop`, `schema.annot Table Key Value`). It is generated from the same schema model as the shallow signature and excludes `_elpi_*` tables. Annotations are stored in a new system table, `_elpi_annotation(table, key, value)`, set with `CALL elpi_annotate(table, key, value)`.
- **Staged rule generation.** Stage 1 runs a module's meta-rules over the reflected schema, at save time and whenever the module's schema hash changes, and produces clause text. Stage 2 stores that text on the module as derived code, typechecks it against the shallow signature and passes it through the M3 rule analysis exactly like hand-written clauses. Generated code depends only on (schema hash, source) and can be inspected with `MATCH (m:_elpi_module) RETURN m.generated`.
- **Runtime generation.** Entry points that add clauses for database predicates with `=>` during a run are inferred `dynamic`. Dynamic entry points run at full scope only and are never partitioned. A user may mark an entry point `dynamic`, but may not mark one non-dynamic.
- **`graph.std`.** A library module of combinators that are polymorphic over relation predicates: `closure`, `acyclic` and `acyclic_witness`, `functional`, `symmetric`, `card R Min Max`. Violation rules can use them directly.

## Capabilities

### New Capabilities
- `schema-reflection`: the reflected schema description, annotations and `elpi_annotate`.
- `rule-generation`: stage 1 meta-rules, stored generated code, analysis of generated code, and inferring `dynamic` from runtime clause generation.
- `graph-std`: the `graph.std` combinator library.

## Impact

**Motivating decisions:**
- [[decisions#Staged rule generation over a reflected schema]] ([[adr:0010]]): generation in stages over a deep description, with checked residual code.
- [[decisions#Predicate-per-property encoding]] ([[adr:0005]]): relations are ordinary predicates, which is what makes the combinators higher-order.
- [[decisions#Closed-world scope]] ([[adr:0009]]) and [[decisions#Partitioned validation]] ([[adr:0016]]): generated code must pass the same checks as hand-written code; `dynamic` entry points run at full scope only.
- [[decisions#Lazy recheck by schema hash]] ([[adr:0011]]): a hash change triggers regeneration in memory, and `elpi_recheck` persists it.
- [[decisions#Proofs where practical]] ([[adr:0020]]): the generator's key properties are proved in Lean.

**Constraints:**
- [[constraints#Clause type variables are rigid]]: rules out a polymorphic `schema.rel` carrying predicate values, and forces the deep/shallow split.
- [[constraints#Table functions can rewrite into Cypher]]: `elpi_annotate` writes through `rewriteFunc`.

**Components introduced:**
- [[components#Schema reflector]] (`Marien/Meta/Reflect.lean`)
- [[components#Rule generator]] (`Marien/Meta/Stage.lean`)
- [[components#Graph standard library]] (`lib/graph/std.elpi`)

**Components changed:** [[components#Module store]] (a `generated` column, `_elpi_annotation`), [[components#Rule analyzer]] (analyses residual code, infers `dynamic` from `=>`), [[components#Handle cache]] (keyed by generated code as well).

**Requirements added:**
- [[openspec:schema-reflection#Reflected schema description]], [[openspec:schema-reflection#System tables are not reflected]], [[openspec:schema-reflection#Schema annotations]]
- [[openspec:rule-generation#Stage one meta-rules]], [[openspec:rule-generation#Generated code is checked like source]], [[openspec:rule-generation#Generated code depends only on schema and source]], [[openspec:rule-generation#Inspectable generated code]], [[openspec:rule-generation#Dynamic entry points]]
- [[openspec:graph-std#Relation combinators]], [[openspec:graph-std#Cycle detection]], [[openspec:graph-std#Cardinality checks]], [[openspec:graph-std#Combinators in violation rules]]

**Change register:** [[changes#add-higher-order-layer]].
