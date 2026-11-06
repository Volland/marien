# rule-storage Specification

## Purpose
Keep rule modules in the database itself: `_elpi_*` system tables hold each module's source byte for byte, its version and derived metadata, with saves checked before anything is stored, `accumulate` dependencies, export and import, and a compiled handle cache.

## Requirements

### Requirement: Module system tables
`CALL elpi_init()` SHALL create, if missing, the node table `_elpi_module(name STRING PRIMARY KEY, version INT64, source STRING, generated STRING, schema_hash STRING, status STRING, derived STRING, saved_at TIMESTAMP)` and the rel table `_elpi_accumulates(FROM _elpi_module TO _elpi_module)`. Every other `elpi_*` function that needs them SHALL fail with a message telling the user to run `elpi_init()` when they are missing.

#### Scenario: Init is idempotent
- **WHEN** `CALL elpi_init()` is run twice
- **THEN** both calls succeed and the tables exist once

#### Scenario: Missing tables are explained
- **WHEN** `elpi_save` is called before `elpi_init()`
- **THEN** it fails with a message that names `elpi_init()`

### Requirement: Save checks before storing
`CALL elpi_save(name, source)` SHALL parse the source, load it after the generated signature and the sources of the modules it accumulates, and type-check it. It SHALL store the module only if all of that succeeds. On failure, nothing SHALL be written, and the error SHALL give the module name and the line and column within the module's own source. On success, the stored `version` SHALL be one more than the previous version of that name (1 for a new name), and `status` SHALL be `ok`.

#### Scenario: Ill-typed module is rejected
- **WHEN** a module calls `person.nme P N`, which the signature does not declare
- **THEN** `elpi_save` fails with a type error at that line and column
- **AND** `_elpi_module` is unchanged

#### Scenario: Version increases
- **WHEN** a module is saved three times with different sources
- **THEN** its stored version is 3

### Requirement: Source is stored byte for byte
The stored `source` SHALL equal the submitted text byte for byte, including comments, blank lines, quotes, backslashes, `$` signs and non-ASCII characters. When the source is embedded in the Cypher statement produced by `rewriteFunc`, the escaping function SHALL be such that unescaping its result gives back the input, and the escaped text SHALL contain no unescaped delimiter of the Cypher string literal it is placed in.

#### Scenario: Hostile characters survive
- **WHEN** a module whose source contains `"`, `'`, `\`, `\n` written literally, `$$`, a tab and `λ` is saved and then exported
- **THEN** the exported source equals the saved source byte for byte

#### Scenario: Source cannot escape its literal
- **WHEN** a module's source contains `'}) DETACH DELETE (n) //`
- **THEN** the save stores that text as source and no other statement runs

### Requirement: Derived module metadata
On save, the extension SHALL store in `derived` a JSON description extracted from the parsed module: the predicates it declares, the predicates it defines clauses for, the generated predicates it calls (directly or through its accumulated modules), its accumulated module names, and its entry predicates (those declared with `pred` and modes).

#### Scenario: Called generated predicates are listed
- **WHEN** a module calls `person.name` and `reports_to`, and defines `violation`
- **THEN** `derived` lists `person.name` and `reports_to` as called generated predicates and `violation` as defined and as an entry predicate

### Requirement: Accumulate dependencies
An `accumulate m.` directive SHALL refer to a stored module named `m`. Saving SHALL fail when `m` does not exist or when the accumulation would create a cycle. On success, the extension SHALL replace the module's outgoing `_elpi_accumulates` edges with one edge per accumulated module.

#### Scenario: Missing dependency
- **WHEN** a module accumulates `graph-base` and no module of that name is stored
- **THEN** `elpi_save` fails naming `graph-base`

#### Scenario: Cycle is rejected
- **WHEN** `a` accumulates `b`, and `b` is then saved accumulating `a`
- **THEN** the second save fails, naming the cycle `b → a → b`

### Requirement: Drop protects dependents
`CALL elpi_drop(name)` SHALL delete the module and its outgoing accumulate edges, and SHALL fail without changes when another module accumulates it.

#### Scenario: Dependent blocks drop
- **WHEN** `org-rules` accumulates `graph-base` and `elpi_drop('graph-base')` is called
- **THEN** the call fails naming `org-rules`

### Requirement: Export and import
`CALL elpi_export()` SHALL return one row per module `(name, version, source)`, ordered so that every module comes after the modules it accumulates. `CALL elpi_import(bundle)` SHALL take a JSON array of `{name, source}` objects in any order and save them in dependency order as one statement, so that either all modules are stored or none are.

#### Scenario: Round trip through a bundle
- **WHEN** all modules are exported, the database is emptied of modules, and the exported rows are imported as a bundle
- **THEN** every module has the same source as before

#### Scenario: One bad module aborts the import
- **WHEN** a bundle of three modules contains one with a type error
- **THEN** the import fails and none of the three is stored

### Requirement: Compiled handle cache
Compiled programs SHALL be kept in an in-memory cache keyed by module name, module version, a hash of the module's source, schema hash and the sources of the modules it accumulates, and SHALL NOT be written to the database. The cache is shared by every database the process opens, so two databases with a module of the same name and version SHALL NOT share an entry unless the sources are equal. A run whose key is cached SHALL reuse the compiled program without parsing or type checking. The cache SHALL be bounded by the extension option `elpi_cache_size` (number of entries) with least-recently-used eviction.

#### Scenario: Second run reuses the program
- **WHEN** the same module is queried twice with an unchanged schema
- **THEN** the second run does not parse or type-check the module

#### Scenario: New version is a new entry
- **WHEN** a module is saved again and then queried
- **THEN** the query compiles and uses the new version
