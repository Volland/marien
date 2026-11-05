## ADDED Requirements

### Requirement: Violation protocol
A module SHALL take part in validation exactly when it declares `pred violation o:severity, o:string, o:subject.` with that signature. The extension SHALL prepend to every module the declarations `kind severity type.` and `type error, warning, info severity.` and the generated `subject` kind. The `string` argument SHALL be a violation code; an optional `pred violation_message i:string, i:subject, o:string.` SHALL supply the message, and the code SHALL be used as the message when it is absent. A module that declares `violation` with any other signature SHALL be rejected at save time with a type error that names the expected signature. A module without `violation` SHALL be saved and run normally and SHALL be skipped by `elpi_validate`.

#### Scenario: Module with violation takes part
- **WHEN** module `org` declares the protocol signature and a clause `violation error "no-manager" (subj_person P) :- person.name P _, not (reports_to P _ _).`
- **THEN** `elpi_validate(['org'])` reports one row per person without a manager

#### Scenario: Wrong signature is rejected
- **WHEN** a module declares `pred violation o:string.`
- **THEN** `elpi_save` fails with a type error naming `violation o:severity, o:string, o:subject`

#### Scenario: Reasoning modules are skipped
- **WHEN** `elpi_validate()` runs over a database whose module `paths` does not declare `violation`
- **THEN** no row comes from `paths` and no error is raised

### Requirement: Subject union kind
The signature generator SHALL emit `kind subject type.` and one constructor per node table and per rel table: `type subj_<table> <kind> -> subject.`, using the same lower-case kind names as the schema encoding. The value codec SHALL decode a `subject` term to the pair (table label, primary-key value) and SHALL encode such a pair back to the same term; for an edge kind, the primary-key value SHALL be the edge's identity as the schema encoding defines it. Tables excluded from the signature (`_elpi_*`) SHALL have no constructor.

#### Scenario: One constructor per table
- **WHEN** the schema has node tables `Person` and `Dept` and rel table `ReportsTo`
- **THEN** the generated signature contains `subj_person`, `subj_dept` and `subj_reports_to` and no constructor for any `_elpi_*` table

#### Scenario: Subject decodes to label and key
- **WHEN** a violation's subject is `subj_person (person 42)`
- **THEN** the report row has `subject_label = 'Person'` and `subject_pk = '42'`

#### Scenario: Subject codec round-trips
- **WHEN** any (label, key) pair of an existing table is encoded to a `subject` term and decoded again
- **THEN** the result is the original pair

### Requirement: Uniform validation report
The extension SHALL provide `elpi_validate(modules LIST(STRING) default all, min_severity STRING default 'info')` returning the columns `(module STRING, version INT64, severity STRING, code STRING, message STRING, subject_label STRING, subject_pk STRING)`. It SHALL run `violation S C X` in every listed module that follows the protocol, keep rows whose severity is at or above `min_severity` in the order `error > warning > info`, and SHALL return rows grouped by module in the order the modules are listed (name order when the list is omitted). A module that cannot run (broken, out of fuel, over a limit) SHALL make the whole call fail with an error naming the module; `elpi_validate` SHALL never return a partial report as if it were complete. In this milestone every module SHALL run at full scope.

#### Scenario: Report across modules
- **WHEN** modules `org` and `hr` both follow the protocol and each finds one violation
- **THEN** `elpi_validate()` returns two rows, the `hr` row before the `org` row, each with its module's current version

#### Scenario: Severity filter
- **WHEN** `org` reports one `error` and one `warning` and `elpi_validate(['org'], 'error')` runs
- **THEN** only the `error` row is returned

#### Scenario: A failing module fails the call
- **WHEN** `hr` runs out of fuel during `elpi_validate()`
- **THEN** the call fails with an error naming `hr` and the exhausted budget
- **AND** no rows from `org` are returned
