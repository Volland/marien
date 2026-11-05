# rule-execution Specification

## Purpose
Run a stored module's typed entry point from Cypher, with output columns known at bind time and arguments checked against the entry point's signature, over the full graph or over a narrowed scope when the entry point is monotone. M1's untyped query is still added by add-tracer-bullet.

## Requirements

### Requirement: Typed entry points
The extension SHALL provide the table function `elpi_run(module STRING, pred STRING, params MAP)` that calls a predicate declared with modes in the saved module. At bind time it SHALL read the predicate's signature through the engine host API and SHALL declare one output column per `o:` argument, named after the argument position (`out1`, `out2`, …) unless the declaration names it, with the LadybugDB type given by the value codec: a node or edge kind SHALL map to the type of that table's primary key, `int` to INT64, `float` to DOUBLE, `string` to STRING, `list T` to LIST of T's column type and a generated record kind to STRUCT. Every `i:` argument SHALL be taken from `params` by position name and encoded through the value codec; a missing, extra or ill-typed parameter SHALL fail the bind with an error that names the parameter. A predicate without a mode declaration, or with an argument whose type has no column mapping, SHALL be rejected at bind time. Each solution SHALL produce one row, decoded from the engine's structured result term, never from printed text.

#### Scenario: Output columns are typed at bind time
- **WHEN** module `org` declares `pred manager_of i:person, o:person, o:string.` over a `Person` table with an INT64 primary key and `elpi_run('org', 'manager_of', {in1: 7})` is bound
- **THEN** the call declares columns `out2 INT64` and `out3 STRING` before any solving starts

#### Scenario: Node results come back as primary keys
- **WHEN** person 7 reports to person 3 and `elpi_run('org', 'manager_of', {in1: 7})` runs
- **THEN** it returns the row `(3, <title>)`
- **AND** `CALL elpi_run(...) WITH out2 MATCH (p:Person {id: out2}) RETURN p` returns person 3

#### Scenario: Bad parameters fail the bind
- **WHEN** `elpi_run('org', 'manager_of', {in1: 'seven'})` is bound
- **THEN** the bind fails with an error that names `in1` and the expected type `person`

#### Scenario: Predicates without modes are rejected
- **WHEN** a module declares `type helper person -> prop.` and `elpi_run` names `helper`
- **THEN** the bind fails with an error saying the predicate has no mode declaration

#### Scenario: Strings round-trip without printing
- **WHEN** an output argument is bound to a string containing quotes, a backslash and a newline
- **THEN** the returned STRING value equals the string in the engine byte for byte

### Requirement: Narrowed scope for monotone entry points
`elpi_run` and `elpi_validate` SHALL accept an optional `scope` argument: a map from node table names to lists of primary-key values, usually passed as a query parameter computed by the caller. The table scanner SHALL load only the listed nodes of a restricted table, their properties, and only edges whose restricted endpoints are listed; tables absent from the map SHALL be loaded in full. Scope is applied by the scanner in the calling transaction, never by running a nested query. The extension SHALL accept a scope only when the rule analyzer has marked the entry point monotone; for any other entry point the call SHALL fail at bind time with an error that names the offending construct and its position from the stored verdict. Rows returned under a narrowed scope SHALL be marked as possibly incomplete by an extra boolean column `narrowed`, set to true.

#### Scenario: Monotone entry point accepts a scope
- **WHEN** monotone entry point `colleague` is run with `scope = {Person: $ids}`, where `$ids` holds the keys of the persons in department 7
- **THEN** the call succeeds and every row has `narrowed = true`

#### Scenario: Non-monotone entry point refuses a scope
- **WHEN** `violation`, which negates `reports_to`, is run with any scope
- **THEN** the bind fails with an error naming `not`, its position and `reports_to`

#### Scenario: Narrowing never adds answers
- **WHEN** a monotone entry point is run with and without a scope over the same graph
- **THEN** every row of the narrowed run appears in the full-scope run
