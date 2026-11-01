import Property.Gen

/-!
# Rejections and their counterexamples

The checks are conservative, so some rejected modules would have run correctly anyway. For a
sample of rejected modules this searches for a graph on which the run the check refused gives a
different answer than full scope, and reports how often it finds one: the measure of how
conservative the analyses are. A missing counterexample never fails the build.

The refused runs cannot go through the extension (it refuses them), so they run here, on
Marien's executor, with facts taken straight from the generated graph:

* a rejected partition runs anchor by anchor, each anchor alone with every node within the
  declared radius along every rel table in both directions (the most generous neighbourhood);
* a narrowed run of a non-monotone entry point loads only the scope's rows.
-/

namespace Property

open Marien Marien.Encoding Marien.Encoding.Codec Marien.Store Marien.Exec

def PV.value : PV → Value
  | .null => .null
  | .int i => .int i
  | .str s => .str s
  | .dbl f => .float f.toBits
  | .bool b => .bool b
  | .date d => .int d
  | .ints xs => .list (xs.map .int)

def propValue (ps : List (String × PV)) (p : String) : Value := ((ps.find? (·.1 == p)).map (·.2.value)).getD .null

/-- The columns of a scan from the graph, with the nodes `keep` allows and the edges between
them (`Executor.addBatch`'s layout). -/
def columnsOf (g : GGraph) (keep : String → Int → Bool) : Scan → Option (Array (Array Value))
  | .node ns =>
    let rows := g.nodes.filter fun n => n.table == ns.plan.name && keep n.table n.id
    some (#[(rows.map (Value.int ·.id)).toArray] ++ (ns.props.map fun p => (rows.map (propValue ·.props p.name)).toArray).toArray)
  | .rel rs =>
    let rows := g.edges.zipIdx.filter fun (e, _) =>
      e.rel == rs.plan.name && rs.plan.pairs.contains (e.src.1, e.dst.1) && keep e.src.1 e.src.2 && keep e.dst.1 e.dst.2
    some (#[(rows.map (Value.str ·.1.src.1)).toArray, (rows.map (Value.int ·.1.src.2)).toArray,
            (rows.map (Value.int ·.2)).toArray, (rows.map (Value.str ·.1.dst.1)).toArray,
            (rows.map (Value.int ·.1.dst.2)).toArray] ++
          (rs.props.map fun p => (rows.map (propValue ·.1.props p.name)).toArray).toArray)
  | .structural .. => none

def load (s : Session) (g : GGraph) (keep : String → Int → Bool) : Except String Session := do
  let mut s := s
  for i in [0:s.scans.size] do
    if let some cols := columnsOf g keep s.scans[i]! then s ← addBatch s i cols
  return s

partial def collect (r : Run) (acc : Array String := #[]) : Except String (Array String) :=
  match step r with
  | .solution items r' => collect r' (acc.push ("|".intercalate items.toList))
  | .paused r' => collect r' acc
  | .done _ => .ok acc
  | .error e => .error e

def fuel : Nat := 2000000

/-- Rows of a session over the rows `keep` allows. -/
def rowsOf (s : Session) (g : GGraph) (keep : String → Int → Bool) : Except String (List String) := do
  let s ← load s g keep
  return (← collect (← startGoal s fuel 100000 1000000)).toList

/-- Whether `a` is a sub-multiset of `b`. -/
def subMultiset (a b : List String) : Bool := a.all fun x => a.count x ≤ b.count x

def sameMultiset (a b : List String) : Bool := subMultiset a b && subMultiset b a

/-- The nodes within `radius` edges of node `a` of `T0`, along every edge in both directions. -/
def around (g : GGraph) (a : Int) (radius : Nat) : List (String × Int) := Id.run do
  let mut seen := [("T0", a)]
  let mut frontier := [("T0", a)]
  for _ in [0:radius] do
    let mut next := []
    for n in frontier do
      for e in g.edges do
        for m in (if e.src == n then [e.dst] else []) ++ (if e.dst == n then [e.src] else []) do
          unless seen.contains m do
            seen := m :: seen
            next := m :: next
    frontier := next
  return seen

/-- Does the partitioned run of `full` (the module without its annotation) differ from full
scope on `g`? Report rows are compared as `severity|code|key`. -/
def partitionDiffers (sc : Schema) (st : List Stored) (g : GGraph) (radius : Nat) : Except String Bool := do
  let (s, _) ← prepareValidate {} sc st "full" 10000000 .info
  let key (row : String) : String := match row.splitOn "|" with
    | [_, _, sev, code, _, _, k] => s!"{sev}|{code}|{k}"
    | _ => row
  let full := (← rowsOf s g fun _ _ => true).map key
  let mut part := []
  for n in g.nodes.filter (·.table == "T0") do
    let near := around g n.id radius
    let b := { s with partition := some (.anchor "T0" radius []) }.forBatch #[.int n.id]
    part := part ++ (← rowsOf b g fun t i => near.contains (t, i)).map key
  return !sameMultiset full part

/-- Does the narrowed run of `q` on `scope` give a row that full scope does not? -/
def narrowingAdds (sc : Schema) (st : List Stored) (g : GGraph) (scope : List (String × List Int)) :
    Except String Bool := do
  let (s, _) ← prepareRun {} sc st "narrow" "q" [] 10000000
  let full ← rowsOf s g fun _ _ => true
  let keep (t : String) (i : Int) : Bool := match scope.find? (·.1 == t) with
    | some (_, ks) => ks.contains i
    | none => true
  return !subMultiset (← rowsOf s g keep) full

/-- What a rejection says, shortened to its reason. -/
def reasonOf (err : String) : String :=
  let has (p : String) := (err.splitOn p).length > 1
  if has "subject must be the anchor" then "subject not the anchor"
  else if has "not within radius" then "unguarded or beyond the radius"
  else if has "recursive predicate" then "recursion"
  else if has "a cut" then "cut"
  else if has "is called with arguments" then "library call over the database"
  else if has "cannot partition" then "dynamic"
  else if has "implication" then "implication"
  else "other"

structure Tally where
  sampled : Nat := 0
  found : Nat := 0
  /-- Per reason: rejections, counterexamples found, a seed. -/
  reasons : List (String × Nat × Nat × Nat) := []

def Tally.add (t : Tally) (reason : String) (found : Bool) (seed : Nat) : Tally :=
  let f := if found then 1 else 0
  let reasons := match t.reasons.find? (·.1 == reason) with
    | some (_, n, k, s) => t.reasons.map fun r => if r.1 == reason then (reason, n + 1, k + f, s) else r
    | none => t.reasons ++ [(reason, 1, f, seed)]
  { sampled := t.sampled + 1, found := t.found + f, reasons }

def Tally.report (t : Tally) (what : String) : String :=
  let pct := if t.sampled == 0 then 0 else t.found * 100 / t.sampled
  s!"{what}: {t.sampled} rejections sampled, {t.found} with a counterexample ({pct}%)\n" ++
  String.join (t.reasons.map fun (r, n, k, s) => s!"  {r}: {k}/{n} (example seed {s})\n")

/-- Sample `count` rejected partitions and `count` rejected narrowings, trying `graphs` graphs
for each. -/
-- @tg: implements:: [[openspec:differential-testing#Rejection counterexample property]]
def rejections (count size graphs : Nat) : String := Id.run do
  let mut parts : Tally := {}
  let mut narrows : Tally := {}
  let mut seed := 1
  while (parts.sampled < count || narrows.sampled < count) && seed < 50 * count do
    let w := workload seed size
    match Schema.parse w.schema.json with
    | .error _ => pure ()
    | .ok sc =>
      let graphsFor := (List.range graphs).map fun k => run (seed * 1000 + k) (genGraph w.schema size)
      if parts.sampled < count then
        match Store.check sc [] "part" w.partition.source, Store.check sc [] "full" w.partition.body with
        | .error e, .ok c =>
          let st := [{ name := "full", version := 1, source := w.partition.body, derived := c.derived.toJson.compress }]
          let found := graphsFor.any fun g => (partitionDiffers sc st g w.partition.radius).toOption.getD false
          parts := parts.add (reasonOf e) found seed
        | _, _ => pure ()
      if narrows.sampled < count then
        match Store.check sc [] "narrow" w.narrowing.source with
        | .ok c =>
          match c.derived.verdict? "q" with
          | some v =>
            unless v.monotone do
              let st := [{ name := "narrow", version := 1, source := w.narrowing.source, derived := c.derived.toJson.compress }]
              let found := graphsFor.any fun g =>
                (narrowingAdds sc st g (run (seed * 7 + 1) (genScope w.schema g))).toOption.getD false
              narrows := narrows.add ((v.offense.map (·.construct)).getD "dynamic") found seed
          | none => pure ()
        | .error _ => pure ()
    seed := seed + 1
  return parts.report "partition" ++ narrows.report "narrowing"

end Property
