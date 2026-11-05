## ADDED Requirements

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
