---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# Validation protocol

## Context and Problem Statement

Validation needs one entry point and one report shape across rule sets.

## Considered Options

* No protocol
* A reserved `violation` predicate and `elpi_validate`
* Also a reserved `derived` predicate for future materialization

## Decision Outcome

Chosen option: "A reserved `violation` predicate and `elpi_validate`", because uniform report.

Rejected: No protocol (every module its own); Also a reserved `derived` predicate for future materialization (premature).

### Consequences

* Good, because CI calls one function and gets `(module, version, severity, code, message, subject_label, subject_pk)`.
* Good, because `subject` is a generated union kind, so violations stay typed in rules.

## More Information

Recorded in the knowledge graph as [[decisions#Validation protocol]].
