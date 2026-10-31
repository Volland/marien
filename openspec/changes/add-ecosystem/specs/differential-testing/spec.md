## ADDED Requirements

### Requirement: Soufflé oracle
The test harness SHALL translate every generated or hand-written test module whose reached clauses lie in the first-order stratified fragment (no `pi`, no `=>`, no higher-order arguments, no cut, no constraints, negation only over stratified predicates), together with the facts materialized for a run, into a Soufflé Datalog program. It SHALL run Soufflé and Marien on the same input and SHALL require equal answer multisets for each entry point, at full scope, narrowed scope and partitioned. A module outside the fragment SHALL be skipped and counted, never translated approximately. A difference SHALL fail the test and save a reproducer (schema, facts, module, query) under `tests/oracle/souffle/failures/`.

#### Scenario: Agreement on a validation rule
- **WHEN** the module `violation error "no-manager" (subj_person P) :- person.name P _, not (reports_to P _ _).` and a random graph are run in both engines
- **THEN** the violation multisets are equal

#### Scenario: Agreement under partitioning
- **WHEN** a module that passes the locality check is validated partitioned in Marien and at full scope in Soufflé
- **THEN** the violation multisets are equal

#### Scenario: Out-of-fragment modules are skipped
- **WHEN** a random module uses `pi` or a `graph.std` combinator with a predicate argument
- **THEN** the harness skips it for the oracle, records it in the skip count, and runs no translation

#### Scenario: Mismatch leaves a reproducer
- **WHEN** an injected fault makes Marien drop one answer
- **THEN** the test fails and writes schema, facts, module and query under `tests/oracle/souffle/failures/`
