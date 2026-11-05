# schema-evolution Specification

## Purpose
Keep stored modules correct when the schema changes: detect staleness by the hash of the tables a module reaches, recompile lazily, and report modules that no longer type-check instead of running them.

## Requirements

### Requirement: Reached-table schema hash
At save time the extension SHALL compute, for each module, the set of tables whose generated predicates its clauses mention, transitively through `accumulate`, and SHALL store in the module row a hash of the catalog entries of exactly those tables (names, property names and types, primary keys, FROM/TO pairs) in a canonical order. The hash SHALL NOT depend on any table outside that set, nor on the order in which the catalog lists tables or properties.

#### Scenario: Unrelated DDL keeps the hash
- **WHEN** module `org` reaches `Person` and `ReportsTo` and a new node table `Invoice` is created
- **THEN** the hash recomputed for `org` equals the stored hash

#### Scenario: Reached DDL changes the hash
- **WHEN** a property `email STRING` is added to `Person`
- **THEN** the hash recomputed for `org` differs from the stored hash

#### Scenario: Catalog order does not matter
- **WHEN** two databases declare the same tables and properties in different orders
- **THEN** a module reaching them gets the same hash in both

### Requirement: Lazy recheck on run
Before any run (`elpi_run`, `elpi_query`, `elpi_validate`) the extension SHALL recompute the module's reached-table hash at bind time. When it differs from the stored hash it SHALL regenerate the module's signature, re-typecheck and recompile it in memory, cache the result in the handle cache under the new hash and run that. It SHALL NOT write the module row during a run. When regeneration or the type check fails, the run SHALL fail with the type error and its source position; it SHALL NOT fall back to the stored or a previously cached compilation.

#### Scenario: Compatible change recompiles in memory
- **WHEN** a property is added to `Person` and `elpi_run('org', ...)` runs
- **THEN** the run succeeds against the new signature
- **AND** the stored row of `org` is unchanged

#### Scenario: Breaking change fails the run
- **WHEN** rel table `ReportsTo` is dropped and `elpi_run('org', ...)` runs
- **THEN** the run fails with a type error naming `reports_to` and its position in `org`
- **AND** no result from an earlier compilation is returned

### Requirement: Broken module status
Each module row SHALL carry `status` with the values `ok`, `stale` and `broken`. `elpi_save` SHALL set `ok`. A run that finds a hash mismatch SHALL report the module as `stale` in its in-memory view without writing; `elpi_recheck` SHALL set `ok` or `broken` and SHALL store the error of a broken module next to it. `elpi_validate` SHALL fail on a broken module as on any other failure.

#### Scenario: Recheck marks a module broken
- **WHEN** `ReportsTo` is dropped and `elpi_recheck()` runs
- **THEN** `org` is stored with `status = 'broken'` and the type error

#### Scenario: Saving clears broken
- **WHEN** a corrected `org` source is saved with `elpi_save`
- **THEN** its status is `ok`

### Requirement: Explicit recheck
The extension SHALL provide `elpi_recheck(modules LIST(STRING) default all)`, returning `(module STRING, old_status STRING, new_status STRING, error STRING)`. It SHALL regenerate and recheck each listed module against the current schema and SHALL persist the new hash, generated signature text, status and error through `rewriteFunc` in one statement, so that either every listed module row is updated or none is.

#### Scenario: Recheck persists regenerated modules
- **WHEN** a property is added to `Person` and `elpi_recheck()` runs
- **THEN** `org` is reported `stale → ok` and its stored hash equals the hash recomputed from the catalog

#### Scenario: Recheck is atomic
- **WHEN** `elpi_recheck(['org', 'hr'])` runs inside a transaction that is rolled back
- **THEN** neither module row has changed
