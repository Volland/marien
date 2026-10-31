---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# Fuel-sliced execution that fails loudly

## Context and Problem Statement

Runaway rules will meet the database. A validation that stops early and reports zero violations is the worst possible lie.

## Considered Options

* Fuel slices with interrupt and deadline checks; exhaustion is an error
* One fuel budget, no interruption
* A separate pool of Lean tasks with cancel tokens

## Decision Outcome

Chosen option: "Fuel slices with interrupt and deadline checks; exhaustion is an error", because cooperative cancellation without extra threads.

Rejected: One fuel budget, no interruption (holds a worker thread); A separate pool of Lean tasks with cancel tokens (a second scheduler).

### Consequences

* Good, because cancellation and deadlines work without threads, and truncated results are impossible except through an explicit `max_solutions`.
* Bad, because LeanElpi must let a query resume after a slice (0.3.3 discards the machine on `outOfFuel`).

## More Information

Recorded in the knowledge graph as [[decisions#Fuel-sliced execution that fails loudly]]. Options: `elpi_fuel`, `elpi_timeout_ms`, `elpi_max_solutions`, `elpi_max_facts`.
