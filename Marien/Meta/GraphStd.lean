/-!
# graph.std

The combinator library `lib/graph/std.elpi`, built into the extension. Every module may
`accumulate graph.std.`; it resolves to this text, so the analysis reads the library's real
clauses, and no stored module may take its name.

The library's `% @marien local <pred> radius <n>` and `% @marien nonlocal <pred>` lines are
claims about the locality check, tested against it (`tests/M4.lean`), never trusted.
-/

-- @lat: [[components#Graph standard library]]

namespace Marien.Meta.GraphStd

def name : String := "graph.std"

/-- The library's text. tg does not read ELPI comments, so the sections' `implements` edges are
repeated here. -/
-- @tg: implements:: [[openspec:graph-std#Relation combinators]]
-- @tg: implements:: [[openspec:graph-std#Cycle detection]]
-- @tg: implements:: [[openspec:graph-std#Cardinality checks]]
-- @tg: implements:: [[openspec:graph-std#Combinators in violation rules]]
def source : String := include_str "../../lib/graph/std.elpi"

/-- A locality claim of the library: a combinator and the radius it is local within, or `none`
when it is not local. -/
def claims : List (String × Option Nat) :=
  (source.splitOn "\n").filterMap fun line =>
    match (line.trimAscii.toString.splitOn " ").filter (· ≠ "") with
    | ["%", "@marien", "local", p, "radius", r] => r.toNat?.map fun n => (p, some n)
    | ["%", "@marien", "nonlocal", p] => some (p, none)
    | _ => none

end Marien.Meta.GraphStd
