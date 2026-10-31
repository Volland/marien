---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# Schema types at runtime and Lean inductives offline

## Context and Problem Statement

Types should come from the graph schema. The schema lives in the database at runtime, while Lean inductives exist at Lean compile time, and the FFI path typechecks pure ELPI without a Lean `Environment`.

## Considered Options

* Generated ELPI signatures at runtime only
* Lean inductives generated offline only
* Runtime ELPI signatures, plus offline Lean codegen from the same encoding

## Decision Outcome

Chosen option: "Runtime ELPI signatures, plus offline Lean codegen from the same encoding", because both, if one function produces both.

Rejected: Generated ELPI signatures at runtime only (cheap and current, but no Lean proofs about rules); Lean inductives generated offline only (full Lean, but every schema change means recompiling and reloading the extension).

### Consequences

* Good, because rules are typechecked against the current schema when saved and when the schema changes.
* Good, because a rule proved offline is the rule that runs, as both sides come from one encoding function.
* Bad, because the encoding function becomes a contract that both printers must honour (tested and, where practical, proved).

## More Information

Recorded in the knowledge graph as [[decisions#Schema types at runtime and Lean inductives offline]]. The offline tool is change `add-ecosystem`.
