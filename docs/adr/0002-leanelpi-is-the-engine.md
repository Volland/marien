---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# LeanElpi is the engine

## Context and Problem Statement

Marien needs a λProlog engine with higher-order pattern unification, `pi`/`=>`, modes and a typechecker, embeddable in a LadybugDB extension process together with schema-derived types.

## Considered Options

* Upstream ELPI (OCaml) over FFI
* LeanElpi, the native Lean 4 implementation of the ELPI dialect
* A new minimal λProlog core in Lean

## Decision Outcome

Chosen option: "LeanElpi, the native Lean 4 implementation of the ELPI dialect", because one managed runtime, a type bridge, an LF layer, a thread-safe C API, and the same author as Marien.

Rejected: Upstream ELPI (OCaml) over FFI (mature, but puts the OCaml runtime beside Lean and C++ in one process, and types stop at a string boundary); A new minimal λProlog core in Lean (duplicates LeanElpi).

### Consequences

* Good, because schema types, analysis and proofs live in the same language as the engine.
* Good, because engine changes Marien needs (signatures, structured terms, resumable fuel) can be made upstream quickly.
* Bad, because LeanElpi is about 2.4 times slower than ELPI by geometric mean and does not reclaim variables in long runs.

## More Information

Recorded in the knowledge graph as [[decisions#LeanElpi is the engine]]. Engine: https://github.com/Volland/lean-elpi (0.3.3 at the time of writing). Marien requires 0.4, see change `add-leanelpi-host-api`.
