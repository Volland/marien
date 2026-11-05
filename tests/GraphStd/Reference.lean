/-!
# Reference implementations of graph.std

What each combinator of `lib/graph/std.elpi` means, on a finite relation given as a list of
edges between numbered nodes. The property tests (`GraphStd.Tests`) compare the library's answer
sets on random relations with these.
-/

namespace GraphStd.Reference

abbrev Rel := List (Nat × Nat)

/-- The distinct targets of `x`. -/
def succs (r : Rel) (x : Nat) : List Nat := ((r.filter (·.1 == x)).map (·.2)).eraseDups

/-- Every node reachable from `x` in one or more steps, breadth first; each node is expanded
once, so `r.length + 1` rounds per frontier node are enough. -/
def closure (r : Rel) (x : Nat) : List Nat :=
  let rec go : Nat → List Nat → List Nat → List Nat
    | 0, _, seen => seen
    | _ + 1, [], seen => seen
    | fuel + 1, n :: rest, seen =>
      let new := (succs r n).filter (!seen.contains ·)
      go fuel (rest ++ new) (seen ++ new)
  go ((r.length + 1) * (r.length + 1)) [x] []

def sources (r : Rel) : List Nat := (r.map (·.1)).eraseDups

/-- The nodes on a cycle. -/
def onCycle (r : Rel) : List Nat := (sources r).filter fun x => (closure r x).contains x

/-- Nodes among `nodes` whose number of distinct targets is outside `[lo, hi]` (`hi = none`: no
upper bound), with that number. -/
def cardOutside (r : Rel) (nodes : List Nat) (lo : Nat) (hi : Option Nat) : List (Nat × Nat) :=
  nodes.filterMap fun x =>
    let n := (succs r x).length
    if decide (n < lo) || (hi.map fun h => decide (n > h)).getD false then some (x, n) else none

/-- Sources with two distinct targets, in both orders. -/
def functional (r : Rel) : List (Nat × Nat × Nat) :=
  (sources r).flatMap fun x => (succs r x).flatMap fun a => ((succs r x).filter (· != a)).map (x, a, ·)

/-- Edges whose reverse is missing. -/
def asymmetric (r : Rel) : List (Nat × Nat) := (r.filter fun (a, b) => !r.contains (b, a)).eraseDups

end GraphStd.Reference
