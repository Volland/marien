## ADDED Requirements

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
