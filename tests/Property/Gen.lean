import Marien

/-!
# Random workloads

Seeded generators for the differential properties: a schema (one or two node tables with
properties of every mapped type, nullable; rel tables over one table, between two, and with
several FROM/TO pairs), a graph over it (size, degree, cycles, self-edges and repeated property
values driven by the size), and rule modules over its signature.

* A *partition module* has `violation` clauses whose bodies mix property atoms, edge steps
  outgoing and incoming, negation, disjunction, comparisons and helper predicates, around the
  subject `subj_t0 A`, and declares `partition violation by t0 radius R`. Some get one literal
  the locality check must reject: an unguarded atom, a step beyond the radius, a cut, recursion,
  `std.forall` over database facts, a hypothetical database clause, a subject that is not the
  anchor.
* A *narrowing module* has a reasoning predicate `q` built from positive literals,
  disjunction, bounded recursion and negation over local values; some get a literal that makes
  it non-monotone.

Everything is a function of the seed and the size: the same pair always gives the same text
(`Seeds reproduce workloads`). Shrinking regenerates a failing seed at smaller sizes.
-/

namespace Property

/-! ### Seeded randomness -/

/-- xorshift64* state; never zero. -/
structure Rng where
  s : UInt64

def Rng.ofSeed (seed : Nat) : Rng :=
  let x : UInt64 := (seed.toUInt64 + 1) * 0x9E3779B97F4A7C15
  ⟨if x == 0 then 1 else x⟩

abbrev Gen := StateM Rng

def next : Gen UInt64 := modifyGet fun r =>
  let x : UInt64 := r.s
  let x := x ^^^ (x >>> 12)
  let x := x ^^^ (x <<< 25)
  let x := x ^^^ (x >>> 27)
  (x * 0x2545F4914F6CDD1D, ⟨x⟩)

def below (n : Nat) : Gen Nat := do
  if n == 0 then return 0
  return ((← next) >>> 11).toNat % n

def chance (num den : Nat) : Gen Bool := return (← below den) < num

def pick {α : Type} [Inhabited α] (xs : List α) : Gen α := do return xs[← below xs.length]!

def run {α : Type} (seed : Nat) (g : Gen α) : α := (g.run (Rng.ofSeed seed)).1

/-! ### Schemas and graphs -/

inductive PType where
  | int | str | dbl | bool | date | ints
  deriving Repr, Inhabited, BEq

def PType.ddl : PType → String
  | .int => "INT64" | .str => "STRING" | .dbl => "DOUBLE" | .bool => "BOOL" | .date => "DATE"
  | .ints => "INT64[]"

structure NodeT where
  name : String
  props : List (String × PType)
  deriving Repr, Inhabited

structure RelT where
  name : String
  pairs : List (String × String)
  props : List (String × PType)
  deriving Repr, Inhabited

structure GSchema where
  nodes : List NodeT
  rels : List RelT
  deriving Repr, Inhabited

def GSchema.hasT1 (s : GSchema) : Bool := s.nodes.length > 1
def GSchema.hasMulti (s : GSchema) : Bool := s.rels.any (·.name == "R2")

/-- A property value; dates are days since 1970-01-01. -/
inductive PV where
  | null
  | int (i : Int)
  | str (s : String)
  | dbl (f : Float)
  | bool (b : Bool)
  | date (days : Int)
  | ints (xs : List Int)
  deriving Repr, Inhabited

structure GNode where
  table : String
  id : Int
  props : List (String × PV)
  deriving Repr, Inhabited

structure GEdge where
  rel : String
  src : String × Int
  dst : String × Int
  props : List (String × PV)
  deriving Repr, Inhabited

structure GGraph where
  nodes : List GNode
  edges : List GEdge
  deriving Repr, Inhabited

/-- Dates with their day numbers. -/
def dates : List (String × Int) := [("2020-01-01", 18262), ("2021-06-15", 18793), ("1999-12-31", 10956)]

def genSchema : Gen GSchema := do
  let extra : Gen (List (String × PType)) := do
    let mut ps := [("p0", PType.int), ("p1", PType.str)]
    for (n, ty) in [("p2", PType.dbl), ("p3", .bool), ("p4", .date), ("p5", .ints)] do
      if ← chance 1 2 then ps := ps ++ [(n, ty)]
    return ps
  let t0 : NodeT := { name := "T0", props := ← extra }
  let two ← chance 1 2
  let t1Props ← extra
  let nodes := if two then [t0, { name := "T1", props := t1Props }] else [t0]
  let w ← chance 1 2
  let mut rels : List RelT := [{ name := "R0", pairs := [("T0", "T0")], props := if w then [("w", .int)] else [] }]
  if two then
    rels := rels ++ [{ name := "R1", pairs := [("T0", "T1")], props := [] }]
    if ← chance 1 2 then rels := rels ++ [{ name := "R2", pairs := [("T0", "T1"), ("T1", "T0")], props := [] }]
  return { nodes, rels }

def genValue (ty : PType) : Gen PV := do
  if ← chance 1 5 then return .null
  match ty with
  | .int => return .int (← below 5)
  | .str => return .str (← pick ["a", "b", "c"])
  | .dbl => return .dbl ((← below 4).toFloat / 2)
  | .bool => return .bool (← chance 1 2)
  | .date => return .date (← pick dates).2
  | .ints => return .ints ((List.range (1 + (← below 2))).map (Int.ofNat ·))

/-- A graph with up to `3 · size` nodes per table; every node has up to two edges of each rel
table it can start. -/
def genGraph (s : GSchema) (size : Nat) : Gen GGraph := do
  let mut nodes : List GNode := []
  for t in s.nodes do
    let n := 1 + (← below (3 * size + 1))
    for i in [1:n + 1] do
      let mut props := []
      for (p, ty) in t.props do props := props ++ [(p, ← genValue ty)]
      nodes := nodes ++ [{ table := t.name, id := i, props }]
  let idsOf (t : String) := (nodes.filter (·.table == t)).map (·.id)
  let mut edges : List GEdge := []
  for r in s.rels do
    for (a, b) in r.pairs do
      for i in idsOf a do
        for _ in [0:← below 3] do
          let j ← pick (idsOf b)
          let mut props := []
          for (p, ty) in r.props do props := props ++ [(p, ← genValue ty)]
          edges := edges ++ [{ rel := r.name, src := (a, i), dst := (b, j), props }]
  return { nodes, edges }

/-! ### Rendering -/

def PV.cypher : PV → String
  | .null => "NULL"
  | .int i => toString i
  | .str s => s!"'{s}'"
  | .dbl f => toString f
  | .bool b => if b then "true" else "false"
  | .date d => s!"date('{((dates.find? (·.2 == d)).map (·.1)).getD "1970-01-01"}')"
  | .ints xs => s!"[{", ".intercalate (xs.map toString)}]"

def GSchema.ddl (s : GSchema) : List String :=
  s.nodes.map (fun t => s!"CREATE NODE TABLE {t.name}(id INT64 PRIMARY KEY" ++
    String.join (t.props.map fun (p, ty) => s!", {p} {ty.ddl}") ++ ")") ++
  s.rels.map fun r => s!"CREATE REL TABLE {r.name}(" ++
    ", ".intercalate (r.pairs.map (fun (a, b) => s!"FROM {a} TO {b}") ++ r.props.map (fun (p, ty) => s!"{p} {ty.ddl}")) ++ ")"

def propsCypher (ps : List (String × PV)) : String :=
  ", ".intercalate ((ps.filter fun (_, v) => !(v matches .null)).map fun (p, v) => s!"{p}: {v.cypher}")

def GGraph.cypher (g : GGraph) : List String :=
  g.nodes.map (fun n =>
    let ps := propsCypher n.props
    s!"CREATE (:{n.table} \{id: {n.id}{if ps.isEmpty then "" else ", " ++ ps}})") ++
  g.edges.map fun e =>
    let ps := propsCypher e.props
    s!"MATCH (a:{e.src.1} \{id: {e.src.2}}), (b:{e.dst.1} \{id: {e.dst.2}}) CREATE (a)-[:{e.rel}" ++
      (if ps.isEmpty then "" else s!" \{{ps}}") ++ "]->(b)"

/-- The catalog JSON of `Marien.Schema.parse`. -/
def GSchema.json (s : GSchema) : String :=
  let prop (p : String × PType) := s!"\{\"name\": \"{p.1}\", \"type\": \"{p.2.ddl}\"}"
  let node (t : NodeT) := s!"\{\"name\": \"{t.name}\", \"key\": \"id\", \"properties\": [" ++
    ", ".intercalate (prop ("id", .int) :: t.props.map prop) ++ "]}"
  let rel (r : RelT) := s!"\{\"name\": \"{r.name}\", \"pairs\": [" ++
    ", ".intercalate (r.pairs.map fun (a, b) => s!"[\"{a}\", \"{b}\"]") ++ "], \"properties\": [" ++
    ", ".intercalate (r.props.map prop) ++ "]}"
  s!"\{\"nodes\": [{", ".intercalate (s.nodes.map node)}], \"rels\": [{", ".intercalate (s.rels.map rel)}]}"

/-! ### Rule bodies -/

/-- Variables a body has bound: node variables with their kind and distance from the anchor,
and value variables by type. -/
structure Vars where
  nodes : List (String × String × Nat) := []
  ints : List String := []
  strs : List String := []
  fresh : Nat := 0
  deriving Inhabited

def freshVar (v : Vars) (p : String) : String × Vars := (s!"{p}{v.fresh}", { v with fresh := v.fresh + 1 })

/-- A property atom on a bound node: binds a value variable or compares with a constant. -/
def propLit (s : GSchema) (v : Vars) : Gen (String × Vars) := do
  let (x, k, _) ← pick v.nodes
  let _ := s
  if ← chance 1 2 then
    if ← chance 1 2 then
      let (n, v) := freshVar v "V"
      return (s!"{k}.p0 {x} {n}", { v with ints := n :: v.ints })
    else return (s!"{k}.p0 {x} {← below 5}", v)
  else
    if ← chance 1 2 then
      let (n, v) := freshVar v "S"
      return (s!"{k}.p1 {x} {n}", { v with strs := n :: v.strs })
    else return (s!"{k}.p1 {x} \"{← pick ["a", "b", "c"]}\"", v)

/-- An edge step from a bound node closer than `radius`, outgoing or incoming; the other end
becomes bound one further away. `far` allows a step from any distance. -/
def stepLit (s : GSchema) (radius : Nat) (v : Vars) (far : Bool := false) : Gen (Option (String × Vars)) := do
  let starts := v.nodes.filter fun (_, _, d) => far || d < radius
  if starts.isEmpty then return none
  let (x, k, d) ← pick starts
  let (y, v) := freshVar v "X"
  let mut opts : List (String × String) := []
  if k == "t0" then
    opts := opts ++ [(s!"r0 {x} _ {y}", "t0"), (s!"r0 {y} _ {x}", "t0")]
    if s.hasT1 then opts := opts ++ [(s!"r1 {x} _ {y}", "t1")]
    if s.hasMulti then opts := opts ++ [(s!"r2 (r2.src.t0 {x}) _ (r2.dst.t1 {y})", "t1")]
  else
    opts := opts ++ [(s!"r1 {y} _ {x}", "t0")]
    if s.hasMulti then opts := opts ++ [(s!"r2 (r2.src.t1 {x}) _ (r2.dst.t0 {y})", "t0")]
  let (lit, k') ← pick opts
  return some (lit, { v with nodes := (y, k', d + 1) :: v.nodes })

/-- One literal of a local body. -/
def localLit (s : GSchema) (radius : Nat) (v : Vars) : Gen (String × Vars) := do
  match ← below 10 with
  | 0 | 1 | 2 => propLit s v
  | 3 | 4 | 5 => return (← stepLit s radius v).getD (← propLit s v)
  | 6 | 7 =>
    -- negation: bindings made inside stay inside
    let (inner, _) ← if ← chance 1 2 then propLit s v else return (← stepLit s radius v).getD (← propLit s v)
    return (s!"not ({inner})", v)
  | 8 =>
    match v.ints with
    | n :: _ => return (s!"{n} > {← below 4}", v)
    | [] => propLit s v
  | _ =>
    let (x, k, _) ← pick v.nodes
    return (s!"({k}.p0 {x} {← below 3} ; {k}.p0 {x} {← below 5})", v)

/-- What makes a partition or a monotonicity check fail. -/
inductive Bad where
  | unguarded | far | cut | recursion | quantifier | hypothetical | subject | negation
  deriving Repr, Inhabited, BEq

def Bad.name : Bad → String
  | .unguarded => "unguarded atom" | .far => "beyond the radius" | .cut => "cut"
  | .recursion => "recursion" | .quantifier => "forall" | .hypothetical => "hypothetical clause"
  | .subject => "subject not the anchor" | .negation => "negation over the database"

/-- The helper predicates a module may call. -/
def helpers : String :=
  "type near t0 -> prop.\nnear X :- r0 X _ Y, t0.p0 Y _.\n" ++
  "type first t0 -> prop.\nfirst X :- t0.p0 X _, !.\n" ++
  "type reach t0 -> t0 -> int -> prop.\nreach X Y N :- N > 0, r0 X _ Y.\n" ++
  "reach X Y N :- N > 0, r0 X _ Z, M is N - 1, reach Z Y M.\n"

def badLit (b : Bad) (v : Vars) : String :=
  -- the latest bound node of t0 (the anchor at least): the helpers take t0
  let x := ((v.nodes.find? (·.2.1 == "t0")).map (·.1)).getD "A"
  match b with
  | .unguarded => "t0.p1 Z _"
  | .far => s!"r0 {x} _ F1, r0 F1 _ F2, r0 F2 _ F3, t0.p0 F3 _"
  | .cut => s!"first {x}"
  | .recursion => s!"reach {x} _ 2"
  | .quantifier => s!"std.forall [1, 2] (n\\ t0.p0 {x} _)"
  | .hypothetical => s!"(r0 {x} (r0 0) {x}) => near {x}"
  | .subject => "true"
  | .negation => s!"not (r0 {x} _ _)"

/-! ### Modules -/

/-- A partition module: its source without the annotation, the annotation, its radius, and the
literal meant to be rejected, if any. -/
structure PartitionModule where
  body : String
  annotation : String
  radius : Nat
  bad : Option Bad
  deriving Inhabited

def PartitionModule.source (m : PartitionModule) : String := m.body ++ m.annotation

def genPartitionModule (s : GSchema) (size : Nat) : Gen PartitionModule := do
  let radius := 1 + (← below 2)
  let bad ← if ← chance 1 4 then
      some <$> pick [Bad.unguarded, .far, .cut, .recursion, .quantifier, .hypothetical, .subject]
    else pure none
  let nclauses := 1 + (← below 3)
  let mut clauses : List String := []
  for c in [0:nclauses] do
    let mut v : Vars := { nodes := [("A", "t0", 0)], fresh := 1 }
    -- the anchor is bound first
    let (first, v') ← propLit s v
    v := v'
    let mut lits := [first]
    for _ in [0:1 + (← below (2 + size / 3))] do
      let (l, v') ← localLit s radius v
      lits := lits ++ [l]
      v := v'
    if c == 0 then
      if let some b := bad then
        unless b == .subject do lits := lits ++ [badLit b v]
    let sev ← pick ["error", "warning", "info"]
    clauses := clauses ++ [s!"violation {sev} \"c{c}\" (subj_t0 A) :- {", ".intercalate lits}."]
  if bad == some .subject then clauses := clauses ++ ["violation info \"fixed\" (subj_t0 (t0 1))."]
  let body := "pred violation o:severity, o:string, o:subject.\n" ++ helpers ++ "\n".intercalate clauses ++ "\n"
  return { body, annotation := s!"% @marien partition violation by t0 radius {radius}\n", radius, bad }

/-- A narrowing module: reasoning predicate `q`, and the literal that makes it non-monotone. -/
structure NarrowingModule where
  source : String
  bad : Option Bad
  deriving Inhabited

def genNarrowingModule (s : GSchema) (size : Nat) : Gen NarrowingModule := do
  let bad ← if ← chance 1 4 then some <$> pick [Bad.negation, .cut, .quantifier, .hypothetical] else pure none
  let mut clauses : List String := []
  for c in [0:1 + (← below 3)] do
    let mut v : Vars := { nodes := [("A", "t0", 0)], fresh := 1 }
    let (first, v') ← propLit s v
    v := v'
    let mut lits := [first]
    for _ in [0:← below (2 + size / 3)] do
      match ← below 4 with
      | 0 => match ← stepLit s 9 v with
        | some (l, v') => lits := lits ++ [l]; v := v'
        | none => pure ()
      | 1 => let (l, v') ← propLit s v; lits := lits ++ [l]; v := v'
      | 2 => match v.ints with
        | n :: _ => lits := lits ++ [s!"not ({n} = {← below 5})"]
        | [] => pure ()
      | _ =>
        let (x, k, _) ← pick v.nodes
        lits := lits ++ [s!"({k}.p0 {x} {← below 3} ; {k}.p1 {x} \"a\")"]
    -- the second argument: an edge neighbour, a bounded-recursion reach or A itself
    let target ← match ← below 3 with
      | 0 => pure s!"r0 A _ B"
      | 1 => pure s!"reach A B 2"
      | _ => pure "B = A"
    lits := lits ++ [target]
    if c == 0 then
      if let some b := bad then lits := lits ++ [badLit b v]
    clauses := clauses ++ [s!"q A B :- {", ".intercalate lits}."]
  return { source := "pred q o:t0, o:t0.\n" ++ helpers ++ "\n".intercalate clauses ++ "\n", bad }

/-- A narrowed scope over the graph: some keys of each node table, as a Cypher map. -/
def genScope (s : GSchema) (g : GGraph) : Gen (List (String × List Int)) := do
  let mut out := []
  for t in s.nodes do
    if t.name == "T0" || (← chance 1 2) then
      let mut ks := []
      for n in g.nodes.filter (·.table == t.name) do
        if ← chance 1 2 then ks := ks ++ [n.id]
      out := out ++ [(t.name, ks)]
  return out

def scopeCypher (sc : List (String × List Int)) : String :=
  "{" ++ ", ".intercalate (sc.map fun (t, ks) => s!"{t}: [{", ".intercalate (ks.map toString)}]") ++ "}"

/-! ### Workloads -/

/-- One generated case, as the runner reads it. -/
structure Workload where
  schema : GSchema
  graph : GGraph
  partition : PartitionModule
  narrowing : NarrowingModule
  scope : List (String × List Int)
  deriving Inhabited

-- @tg: implements:: [[openspec:differential-testing#Random workload generation]]
def workload (seed size : Nat) : Workload := run seed do
  let schema ← genSchema
  let graph ← genGraph schema size
  let partition ← genPartitionModule schema size
  let narrowing ← genNarrowingModule schema size
  let scope ← genScope schema graph
  return { schema, graph, partition, narrowing, scope }

/-- The lines of a text, blank ones left out. -/
def lines (s : String) : List String := (s.splitOn "\n").filter (· ≠ "")

/-- The text the runner reads: `CYPHER` lines, then each module between `MODULE <name>` and
`END`, then `SCOPE <map>`. -/
def Workload.text (w : Workload) : String :=
  let cy := (w.schema.ddl ++ w.graph.cypher).map ("CYPHER " ++ ·)
  "\n".intercalate (cy ++
    ["MODULE full"] ++ lines w.partition.body ++ ["END", "MODULE part"] ++ lines w.partition.source ++
    ["END", "MODULE narrow"] ++ lines w.narrowing.source ++ ["END", "SCOPE " ++ scopeCypher w.scope]) ++ "\n"

/-- The size of a case, for shrinking: nodes and edges. -/
def Workload.measure (w : Workload) : Nat := w.graph.nodes.length + w.graph.edges.length

/-- Shrinking a failing seed: among the smaller sizes at which its case still fails, the one
whose case is smallest; the original size when none is smaller. -/
def shrink (seed size : Nat) (fails : Nat → Bool) : Nat :=
  let m (n : Nat) := (workload seed n).measure
  let best := ((List.range size).filter fails).foldl (init := none) fun acc n =>
    match acc with
    | some b => if m n < m b then some n else some b
    | none => some n
  match best with
  | some n => if m n ≤ m size then n else size
  | none => size

end Property
