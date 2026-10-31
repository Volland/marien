## ADDED Requirements

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
