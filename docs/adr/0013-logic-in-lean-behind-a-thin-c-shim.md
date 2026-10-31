---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# Logic in Lean behind a thin C++ shim

## Context and Problem Statement

LadybugDB loads C++ shared libraries; the encoding must be shared with offline Lean codegen; two self-contained Lean libraries in one process means two runtimes.

## Considered Options

* Thin C++ shim, all logic in a Lean `Marien` package, LeanElpi linked statically into one library
* Logic in C++, LeanElpi as a solver through `leanelpi.h`
* Mixed

## Decision Outcome

Chosen option: "Thin C++ shim, all logic in a Lean `Marien` package, LeanElpi linked statically into one library", because one runtime.

Rejected: Logic in C++, LeanElpi as a solver through `leanelpi.h` (two implementations of the encoding); Mixed (split ownership).

### Consequences

* Good, because the runtime signature and the offline inductives come from one function, and clause analysis is natural in Lean.
* Good, because Lean proofs can cover the encoding and analyses.
* Bad, because the published `libleanelpi` cannot be used; symbols must be hidden except the init entry point; each foreign thread is initialized once as in LeanElpi's `ensure_thread`.

## More Information

Recorded in the knowledge graph as [[decisions#Logic in Lean behind a thin C++ shim]].
