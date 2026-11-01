import M1
import Property.Model

/-! Unit tests of the workload generator: seeds reproduce workloads, shrinking keeps a failing
case and never grows it, and generated modules are valid modules. -/

open Marien Marien.Store Property
open M1 (check fail ok contains)

namespace PropertyTests

-- @tg: verifies:: [[openspec:differential-testing#Random workload generation#Seeds reproduce workloads]] {level: unit}
def seedsReproduce : IO Unit := do
  for seed in [1, 2, 99] do
    check ((workload seed 5).text == (workload seed 5).text) s!"seed {seed} gives the same text twice"
  check ((workload 1 5).text != (workload 2 5).text) "different seeds, different workloads"

-- @tg: verifies:: [[openspec:differential-testing#Random workload generation#Failures are shrunk]] {level: unit}
def failuresShrunk : IO Unit := do
  -- a property that fails on cases more than half as large as the original
  let size := 12
  let big := (workload 7 size).measure
  let fails (n : Nat) : Bool := 2 * (workload 7 n).measure > big
  check (fails size) "the original case fails"
  let n := shrink 7 size fails
  check (fails n) s!"the shrunk case (size {n}) still fails"
  check ((workload 7 n).measure ≤ (workload 7 size).measure) "and is no larger"

/-- Every generated module that the analyzer does not reject saves. -/
def modulesAreValid : IO Unit := do
  for seed in [1:40] do
    let w := workload seed 4
    let sc ← ok (Schema.parse w.schema.json) "schema"
    let _ ← ok (Store.check sc [] "full" w.partition.body) s!"seed {seed}: full\n{w.partition.body}"
    match w.narrowing.bad with
    | none => let _ ← ok (Store.check sc [] "narrow" w.narrowing.source) s!"seed {seed}: narrow\n{w.narrowing.source}"
    | some _ => pure ()

def all : List (String × IO Unit) :=
  [("seeds reproduce workloads", seedsReproduce), ("failures are shrunk", failuresShrunk),
   ("generated modules are valid", modulesAreValid)]

end PropertyTests
