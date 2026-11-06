## MODIFIED Requirements

### Requirement: Explicit recheck
The extension SHALL provide `elpi_recheck(modules LIST(STRING) default all)`, returning `(module STRING, old_status STRING, new_status STRING, error STRING)`. It SHALL regenerate and recheck each listed module against the current schema, running its stage 1 meta-rules again (see rule-generation, "Stage one meta-rules"), and SHALL persist the new hash, the generated clause text (`_elpi_module.generated`, empty for a module without meta-rules), status and error through `rewriteFunc` in one statement, so that either every listed module row is updated or none is. A module that does not recheck keeps its stored generated text.

#### Scenario: Recheck persists regenerated modules
- **WHEN** a property is added to `Person` and `elpi_recheck()` runs
- **THEN** `org` is reported `stale → ok` and its stored hash equals the hash recomputed from the catalog

#### Scenario: Recheck is atomic
- **WHEN** `elpi_recheck(['org', 'hr'])` runs inside a transaction that is rolled back
- **THEN** neither module row has changed
