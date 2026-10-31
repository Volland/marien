---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# Call LeanElpi only through its host façade

## Context and Problem Statement

Marien needs from LeanElpi a predicate's signature at bind time, goals built from parameter values, solutions as terms, resumable fuel slices, facts added as terms and the parsed clauses. LeanElpi 0.3.3 has the parts in its engine modules (`Elpi.Core.*`, `Elpi.Runtime.Api`), some internal and some missing. Depending on those modules directly ties Marien to the engine's internals.

## Considered Options

* Import `Elpi.Core.*` and `Elpi.Runtime.Api` directly
* A host façade module in LeanElpi, `Elpi.Host`, with stable types and functions, wrapped once in Marien (`Marien.Engine`)
* New C functions in LeanElpi's `leanelpi.h`

## Decision Outcome

Chosen option: "A host façade module in LeanElpi, `Elpi.Host`, wrapped once in Marien", because Marien links LeanElpi statically and calls Lean directly, so the contract is a Lean API, and one module on each side keeps an engine upgrade to one file.

Rejected: importing the engine modules (every refactor of the engine breaks Marien); C functions (Marien is Lean code in the same library, and text or JSON at that boundary costs a print and a parse per value).

### Consequences

* Good, because `tests/EngineContract.lean` checks every promise of the `engine-host-api` capability against the pinned LeanElpi, so a breaking upgrade fails `lake test`.
* Good, because the façade's proofs (`ResultTerm.json_roundtrip`, `TyTerm.beq_iff_eq`, `addFacts_atomic`) hold for Marien too.
* Bad, because LeanElpi commits to a public AST and result-term type; both are views versioned with its minor version.
* Bad, because until LeanElpi 0.4.0 is released Marien pins the façade by commit.

## More Information

Recorded in the knowledge graph as [[decisions#Call LeanElpi only through its host façade]]. Engine side: lean-elpi change `add-host-api`. Marien side: `Marien/Engine.lean`, change `add-leanelpi-host-api`.
