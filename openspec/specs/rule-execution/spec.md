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

### Requirement: Full-scope materialization
Before solving, the extension SHALL load as facts every row of every table whose generated predicates the module calls, directly or through accumulated modules, as recorded in its derived metadata. Rows SHALL be read through the storage interface within the calling query's transaction, not by running a nested Cypher query, so a run sees exactly the snapshot of the statement that called it.

#### Scenario: Facts reflect the calling transaction
- **WHEN** a transaction creates a Person and then calls `elpi_query` on a module that reads `person` before committing
- **THEN** the new Person is among the facts

#### Scenario: Unused tables are not loaded
- **WHEN** a module calls only `person.name`, and the database also has a large `Event` table
- **THEN** no `event` fact is loaded

### Requirement: Untyped debug query
`CALL elpi_query(module, goal)` SHALL parse `goal` as an ELPI query against the module, solve it, and return one row per (solution, variable) pair with columns `sol INT64`, `var STRING`, `value STRING` and `exhausted BOOL`. `value` holds the binding as the JSON form of a structured result term. A solution with no named variables SHALL produce one row with null `var` and `value`. `exhausted` SHALL be true when the search ran to completion and false when `elpi_max_solutions` stopped it.

#### Scenario: Bindings as rows
- **WHEN** `CALL elpi_query('people', 'person.name P N') RETURN *` runs over two persons
- **THEN** four rows are returned, two per solution, with `var` values `P` and `N`
- **AND** `exhausted` is true on every row

#### Scenario: Goal with a syntax error
- **WHEN** the goal text has a parse error
- **THEN** the call fails with the parse error and the column within the goal

### Requirement: Fuel-sliced execution
The executor SHALL run each query in slices of at most `elpi_slice_steps` resolution steps, using the engine's resumable slices. Between slices it SHALL check LadybugDB's interrupt flag for the calling query and the deadline set by `elpi_timeout_ms`, and SHALL stop with an error as soon as either fires. One call SHALL run on one thread, with the table function declared as not parallel.

#### Scenario: Cancellation stops a runaway rule
- **WHEN** a module defining `loop :- loop.` is queried with `loop` and the query is interrupted from another connection after one second
- **THEN** the call fails with an interruption error within one slice of the interrupt

#### Scenario: Slicing does not change answers
- **WHEN** the same query is run with `elpi_slice_steps` set to 100 and to 10⁶
- **THEN** both runs return the same rows in the same order

### Requirement: Execution limits are errors
The options `elpi_fuel` (total resolution steps), `elpi_timeout_ms` and `elpi_max_facts` (facts loaded by materialization) SHALL each end the call with an error naming the limit and its value when exceeded. They SHALL never end it with a partial result. Only `elpi_max_solutions` MAY stop a search early, and the result SHALL say so through `exhausted = false`.

#### Scenario: Fuel exhaustion is an error
- **WHEN** a query needs more steps than `elpi_fuel` allows
- **THEN** the call fails with an error naming `elpi_fuel`
- **AND** no rows are returned

#### Scenario: Fact budget is checked before solving
- **WHEN** materialization would load more facts than `elpi_max_facts`
- **THEN** the call fails before solving, naming `elpi_max_facts` and the table that crossed it

#### Scenario: Solution limit is reported
- **WHEN** `elpi_max_solutions` is 1 and the goal has three solutions
- **THEN** the rows of one solution are returned with `exhausted = false`

### Requirement: Fresh store per call
Every call SHALL solve in a fresh engine store holding the cached compiled module plus the facts loaded for this call. Nothing from the store SHALL survive the call, so memory not reclaimed during a run is released when it ends.

#### Scenario: Memory returns after a run
- **WHEN** a query that allocates about 500 MB of engine memory is run ten times in a row
- **THEN** resident memory after the tenth run is within 10% of resident memory after the first
