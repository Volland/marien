## Why

Marien calls LeanElpi from Lean, inside the same library ([[decisions#Logic in Lean behind a thin C++ shim]]), and needs four things LeanElpi 0.3.3 does not offer as a public API. First, the types and modes of an entry predicate, so the shim can declare output columns at bind time ([[constraints#Output columns are fixed at bind time]]). Second, solutions as structured terms rather than printed text. Third, a query that can pause after a fuel slice and resume ([[constraints#Out of fuel discards the search]]). Fourth, the parsed clauses, which the rule analysis of M3 and the staging of M4 inspect. Fifth, a way to add millions of facts from the database as terms, without printing and parsing them ([[decisions#Materialize facts per call]]). This change states that contract from the consumer's side. The engine work lands in the lean-elpi repository as its own change, released as LeanElpi 0.4. Marien pins that release.

**Milestone:** M0.

**Depends on:** `spike-lean-runtime-in-ladybug`, whose go decision confirms that Marien links LeanElpi statically and calls its Lean API directly.

## What Changes

- A requirement set, `engine-host-api`, describing the LeanElpi 0.4 Lean API that Marien relies on: predicate signatures, goals built from terms, structured solutions, resumable fuel slices, a public clause AST, bulk loading of facts as terms, and loading from several source units.
- A matching change proposal in lean-elpi (`add-host-api`) implementing it. Its tests become the evidence for this spec.
- Marien's `lakefile.lean` pins `lean-elpi` at the 0.4 tag. A compatibility test in `tests/EngineContract.lean` checks every requirement here against the pinned release, so an engine upgrade that breaks the contract fails Marien's CI.

## Capabilities

### New Capabilities
- `engine-host-api`: the LeanElpi Lean API contract Marien consumes.

## Impact

**Motivating decisions:**
- [[decisions#Typed entry points and an untyped debug query]] ([[adr:0008]]): needs signatures and structured results.
- [[decisions#Fuel-sliced execution that fails loudly]] ([[adr:0014]]): needs a resumable fuel slice.
- [[decisions#Closed-world scope]] ([[adr:0009]]) and [[decisions#Staged rule generation over a reflected schema]] ([[adr:0010]]): need the clause AST.
- [[decisions#LeanElpi is the engine]] ([[adr:0002]]).

**Binding constraints:**
- [[constraints#Output columns are fixed at bind time]]
- [[constraints#Out of fuel discards the search]]
- [[constraints#Clause type variables are rigid]]

**Components touched:** [[components#Runtime bridge]], [[components#Executor]], [[components#Rule analyzer]].

**Requirements added:**
- [[openspec:engine-host-api#Predicate signature lookup]]
- [[openspec:engine-host-api#Goals built from terms]]
- [[openspec:engine-host-api#Structured solution terms]]
- [[openspec:engine-host-api#Resumable fuel slices]]
- [[openspec:engine-host-api#Public clause AST]]
- [[openspec:engine-host-api#Bulk fact loading]]
- [[openspec:engine-host-api#Multi-unit load keeps positions]]

**Change register:** [[changes#add-leanelpi-host-api]]
