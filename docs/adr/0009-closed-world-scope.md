---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# Closed-world scope

## Context and Problem Statement

Negation as failure, cut and `forall` over a partial set of facts report missing data as absence, which produces false violations.

## Considered Options

* Always load every reached table in full
* Caller-supplied Cypher scope
* Full tables by default; narrowed scope only for entry points proved monotone

## Decision Outcome

Chosen option: "Full tables by default; narrowed scope only for entry points proved monotone", because checked when the module is saved.

Rejected: Always load every reached table in full (correct by construction); Caller-supplied Cypher scope (fast and silently wrong when too narrow).

### Consequences

* Good, because correctness is enforced by the extension, not remembered by users.
* Bad, because most validation uses negation and therefore runs at full scope or partitioned ([[adr:0016]]).

## More Information

Recorded in the knowledge graph as [[decisions#Closed-world scope]].
