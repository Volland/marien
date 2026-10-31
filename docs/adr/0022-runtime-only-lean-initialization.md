---
status: accepted
date: 2026-10-31
decision-makers: [Volodymyr Pavlyshyn]
---
# Runtime-only Lean initialization

## Context and Problem Statement

Lean 4.35 emits a call to `lean_initialize()` at the start of every module initializer. The toolchain's definition, in `libleancpp`, initializes the runtime and then the whole Lean compiler package (`initialize_Lean`). An extension that only runs LeanElpi's engine core therefore links about 1,200 members of `libLean.a` it never uses: 68 MB dead-stripped, 24 MB gzipped.

## Considered Options

* Link `libleancpp` and accept the size
* Define a runtime-only `lean_initialize` in the runtime bridge and never link `libleancpp`
* Ask Lean upstream for a codegen option that omits the call

## Decision Outcome

Chosen option: "Define a runtime-only `lean_initialize` in the runtime bridge and never link `libleancpp`", because it cuts the extension to 2.7 MB (0.8 MB gzipped) and start-up to about 12 ms with no change to Lean or LeanElpi.

Rejected: linking `libleancpp` (25 times larger, slower start); an upstream codegen option (not available, and we would wait on it).

### Consequences

* Good, because the extension is small and loads fast, and only the Lean modules actually imported are linked.
* Bad, because Lean code in the extension must not use the C++ kernel; the link fails with undefined `lean_*` symbols if it does.
* Bad, because each Lean upgrade must re-check that `lean_initialize` is still the only initialization hook.

## More Information

Recorded in the knowledge graph as [[decisions#Runtime-only Lean initialization]]. Evidence: `spike/RESULT.md`. Implemented in `spike/bridge.c` and carried into M1's runtime bridge. LeanElpi's own `libleanelpi` would shrink the same way.
