import M4
import GraphStd.Reference
import Property.Gen

/-!
# graph.std against its reference

On random finite relations, every combinator of `graph.std`, run by LeanElpi, has the answer set
of its Lean reference (`GraphStd.Reference`); the ones that promise it also give each answer once.
-/

open Marien Property GraphStd.Reference
open M1 (check fail ok)

namespace GraphStd.Tests

/-- A relation over nodes `1..n`, `n` from 2 to 6, with up to 9 edges (loops and parallel edges
included). -/
def relation (seed : Nat) : Nat × Rel := run seed do
  let n := 2 + (← below 5)
  let m ← below 10
  let es ← (List.range m).mapM fun _ => do return (1 + (← below n), 1 + (← below n))
  return (n, es)

def p (i : Nat) : String := s!"(person {i})"

def same (what : String) (got : List String) (want : List String) (once : Bool := true) : IO Unit := do
  let s := Schema.sortStrings
  check (s got.eraseDups == s want.eraseDups) s!"{what}: got {s got}, want {s want}"
  if once then check (got.length == got.eraseDups.length) s!"{what}: repeated answers {s got}"

-- @tg: verifies:: [[openspec:graph-std#Relation combinators]] {level: unit, note: "answer sets against the Lean references on random relations"}
-- @tg: verifies:: [[openspec:graph-std#Cycle detection]] {level: unit}
-- @tg: verifies:: [[openspec:graph-std#Cardinality checks]] {level: unit}
def agreeOnRandomRelations : IO Unit := do
  for seed in List.range 60 do
    let (n, r) := relation (seed + 1)
    let nodes := (List.range n).map (· + 1)
    let facts := M4.edges "knows" "person" r ++ M4.people nodes
    let ctx := s!"seed {seed + 1}, edges {r}"
    for x in nodes do
      same s!"closure from {x} ({ctx})" (← M4.answers facts s!"closure (edge_of knows) {p x} Y")
        ((closure r x).map fun y => s!"Y={p y}")
    same s!"acyclic_witness ({ctx})" (← M4.answers facts "acyclic_witness (edge_of knows) X")
      ((onCycle r).map fun x => s!"X={p x}")
    for (lo, hi, hiText) in [(1, some 1, "1"), (0, some 2, "2"), (2, none, "-1")] do
      same s!"card_witness {lo} {hiText} ({ctx})"
        (← M4.answers facts s!"card_witness person (edge_of knows) {lo} {hiText} X N")
        ((cardOutside r nodes lo hi).map fun (x, k) => s!"X={p x} N={k}")
    same s!"functional_witness ({ctx})" (once := false) (← M4.answers facts "functional_witness (edge_of knows) X Y1 Y2")
      ((functional r).map fun (x, a, b) => s!"X={p x} Y1={p a} Y2={p b}")
    same s!"symmetric_witness ({ctx})" (once := false) (← M4.answers facts "symmetric_witness (edge_of knows) X Y")
      ((asymmetric r).map fun (a, b) => s!"X={p a} Y={p b}")

def all : List (String × IO Unit) := [("graph.std agrees with its reference", agreeOnRandomRelations)]

end GraphStd.Tests
