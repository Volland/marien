# schema-reflection Specification

## Purpose
Describe the visible schema and its annotations to meta-rules as ELPI facts, leaving Marien's own `_elpi_*` tables out, and let users set annotations on tables with `elpi_annotate`.

## Requirements

### Requirement: Reflected schema description
The extension SHALL describe the current schema as monomorphic ELPI facts over plain data, generated from the same schema model as the shallow signature: `schema.node Table`, one fact per node table; `schema.rel Name From To`, one fact per FROM/TO pair of each rel table; `schema.prop Table Column Type`, one fact per property (the primary key included), where `Type` is a term of a closed `schema.ty` kind (`ty_int`, `ty_float`, `ty_string`, `ty_bool`, `ty_date`, `ty_timestamp`, `ty_list T`, `ty_struct Fields`, `ty_other Text`); `schema.key Table Column`, the primary key of each node table; and `schema.ident Table Ident` and `schema.prop_ident Table Column Ident`, the shallow predicate the signature generates for a table or property, so that meta-rules can write it into clause text. Table, column and type names SHALL be strings or constants of monomorphic kinds; no fact of the reflected description SHALL carry a predicate value. The description SHALL be available only to stage 1 meta-rules (see rule-generation, "Stage one meta-rules"), not to stage 2 code at run time.

#### Scenario: Node and rel tables are reflected
- **WHEN** the schema has `NODE TABLE Person(id INT64 PK, name STRING)` and `REL TABLE ReportsTo(FROM Person TO Person)`
- **THEN** the reflected description contains `schema.node "Person"`, `schema.rel "ReportsTo" "Person" "Person"`, `schema.prop "Person" "id" ty_int` and `schema.prop "Person" "name" ty_string`

#### Scenario: Multi-pair rel tables give one fact per pair
- **WHEN** a rel table `Owns` declares `FROM Person TO Car` and `FROM Company TO Car`
- **THEN** the reflected description contains `schema.rel "Owns" "Person" "Car"` and `schema.rel "Owns" "Company" "Car"`

#### Scenario: Reflection typechecks without rigid-variable conflicts
- **WHEN** the reflected description of a schema with rel tables of different endpoint types is loaded with a meta-module
- **THEN** LeanElpi accepts it without type errors

### Requirement: System tables are not reflected
The reflected description SHALL NOT contain any fact that mentions a table whose name starts with `_elpi_`, nor any column of such a table, nor any annotation on it.

#### Scenario: Module storage stays invisible
- **WHEN** the database contains `_elpi_module`, `_elpi_accumulates` and `_elpi_annotation` next to user tables
- **THEN** no `schema.node`, `schema.rel`, `schema.prop` or `schema.annot` fact names any of them

### Requirement: Schema annotations
`CALL elpi_init()` SHALL also create, if missing, a system node table `_elpi_annotation(id STRING PRIMARY KEY, table_name STRING, key STRING, value STRING)` (`table` is a reserved word in LadybugDB), and the extension SHALL store annotations in it, keyed by (table, key), and SHALL expose them in the reflected description as `schema.annot Table Key Value`. `CALL elpi_annotate(table, key, value)` SHALL insert or replace an annotation through `rewriteFunc`, SHALL fail when `table` does not name an existing user table, and SHALL change the schema hash of every module that reaches that table, so that its generated code is rebuilt (see rule-generation, "Stage one meta-rules"). An empty `value` SHALL remove the annotation.

#### Scenario: Annotation appears in reflection
- **WHEN** `CALL elpi_annotate('ReportsTo', 'acyclic', 'true')` runs
- **THEN** the reflected description contains `schema.annot "ReportsTo" "acyclic" "true"`

#### Scenario: Annotating an unknown table fails
- **WHEN** `CALL elpi_annotate('NoSuchTable', 'acyclic', 'true')` runs
- **THEN** the call fails with an error naming `NoSuchTable` and no row is written

#### Scenario: Annotation change triggers regeneration
- **WHEN** a module's meta-rules read `schema.annot`, and an annotation on a table the module reaches is added
- **THEN** the next `elpi_run` of that module regenerates its code before running
