import Marien.Encoding.Codec
import Marien.Store.Module
import Marien.Store.Cache

/-!
# Executor

One call of `elpi_query`:

1. `prepare` finds the compiled module in the handle cache, or compiles it after the generated
   signature with its accumulated modules, and works out which tables to scan from the module's
   derived metadata (every table whose generated predicates the module mentions).
2. The shim scans those tables in the calling transaction and hands each column batch to
   `addBatch`, which turns rows into facts with the value codec and checks `elpi_max_facts`
   before adding them.
3. `start` parses the goal, and `step` runs it one slice of at most `elpi_slice_steps`
   resolution steps at a time. Between slices the shim checks LadybugDB's interrupt flag and
   the `elpi_timeout_ms` deadline.

Facts are added to a copy of the cached program, so every call solves in a fresh store and
nothing of it outlives the call. Exhausting `elpi_fuel` or `elpi_max_facts` is an error, never a
partial answer; only `elpi_max_solutions` stops a search early, and says so.
-/

-- @lat: [[components#Executor]]

namespace Marien.Exec

open Marien.Encoding
open Marien.Store
open Marien.Engine (ResultTerm Program Query)

/-! ### What to scan -/

/-- A node table to scan: its key, and the property columns the facts need. -/
structure NodeScan where
  plan : NodePlan
  /-- The module mentions the predicate listing every node. -/
  listNodes : Bool
  /-- Mentioned property predicates; the scanner reads these columns, in this order. -/
  props : List PropPlan
  deriving Inhabited

/-- A rel table to scan: endpoints, internal ids and the property columns the facts need. -/
structure RelScan where
  plan : RelPlan
  listEdges : Bool
  props : List PropPlan
  deriving Inhabited

inductive Scan where
  | node (s : NodeScan)
  | rel (s : RelScan)
  deriving Inhabited

namespace Scan

def table : Scan → String
  | .node s => s.plan.name
  | .rel s => s.plan.name

/-- For the shim: `["node", table, column…]`, or `["rel", table, n, from₁, to₁, …, column…]`
with the `n` encoded FROM/TO pairs (pairs to a table left out of the signature are not scanned). -/
def describe : Scan → Array String
  | .node s => #["node", s.plan.name] ++ (s.props.map (·.name)).toArray
  | .rel s => #["rel", s.plan.name, toString s.plan.pairs.length] ++
      (s.plan.pairs.flatMap fun (a, b) => [a, b]).toArray ++ (s.props.map (·.name)).toArray

end Scan

/-- The scans for the generated predicates a module mentions. Tables it does not mention are
not scanned. -/
-- @tg: implements:: [[openspec:rule-execution#Full-scope materialization]]
def scansFor (sig : Signature) (mentioned : List String) : Array Scan :=
  let nodes := sig.plan.nodes.filterMap fun n =>
    let props := n.props.filter (mentioned.contains ·.pred)
    let listNodes := mentioned.contains n.id
    if listNodes || !props.isEmpty then some (Scan.node { plan := n, listNodes, props }) else none
  let rels := sig.plan.rels.filterMap fun r =>
    let props := r.props.filter (mentioned.contains ·.pred)
    let listEdges := mentioned.contains r.id
    if listEdges || !props.isEmpty then some (Scan.rel { plan := r, listEdges, props }) else none
  (nodes ++ rels).toArray

/-! ### Preparing a call -/

/-- A compiled module with what its runs need; the handle cache stores these. -/
structure Compiled where
  program : Program
  sig : Signature
  /-- Generated predicates the module mentions, from its derived metadata. -/
  mentioned : List String
  deriving Inhabited

abbrev HandleCache := Cache Compiled

/-- The words of a goal text that could be identifiers. -/
def goalWords (goal : String) : List String :=
  let word (c : Char) : Bool := c.isAlphanum || c == '_' || c == '.' || c == '-'
  let (ws, cur) := goal.toList.foldl (init := ([], [])) fun (ws, cur) c =>
    if word c then (ws, c :: cur) else if cur.isEmpty then (ws, []) else (String.ofList cur.reverse :: ws, [])
  (if cur.isEmpty then ws else String.ofList cur.reverse :: ws).reverse

/-- The state of one call while facts are loaded. -/
structure Session where
  compiled : Compiled
  /-- The tables this call scans. -/
  scans : Array Scan
  program : Program
  facts : Nat := 0
  maxFacts : Nat
  deriving Inhabited

/-- The modules `name` accumulates, transitively, with the hash of their source. -/
partial def depHashes (stored : List Stored) (name : String) : List (String × String) :=
  let edges := edgesOf stored
  let rec go (todo : List String) (seen : List String) : List String :=
    match todo with
    | [] => seen
    | n :: rest =>
      let next := (((edges.find? (·.1 == n)).map (·.2)).getD []).filter (!seen.contains ·)
      go (rest ++ next) (seen ++ next)
  let names := go [name] []
  Schema.sortStrings names |>.filterMap fun n =>
    (stored.find? (·.name == n)).map fun m => (n, Schema.hex16 (Schema.fnv1a64 m.source))

/-- Find or compile the module and start a session. Besides the tables the module mentions, the
call scans the tables of generated predicates named in `goal`, so a debug query may ask about
any of them. -/
def prepare (cache : HandleCache) (schema : Schema) (stored : List Stored) (name : String)
    (maxFacts : Nat) (goal : String := "") : Except String (Session × HandleCache) := do
  let some m := stored.find? (·.name == name) | throw s!"no module named {name}"
  let key : CacheKey :=
    { name, version := m.version, sourceHash := Schema.hex16 (Schema.fnv1a64 m.source),
      schemaHash := Schema.hash schema, deps := depHashes stored name }
  let (hit, cache) := cache.find? key
  let (compiled, cache) ← match hit with
    | some c => pure (c, cache)
    | none => do
      let sig ← (Signature.ofSchema (Engine.reservedNames.contains ·) schema).mapError (s!"signature: {·}")
      let derived ← (do Derived.ofJson? (← Lean.Json.parse m.derived)).mapError fun e =>
        s!"module {name} has no readable metadata ({e}); save it again"
      let libs := (stored.filter (·.name != name)).map fun s => (s.name, s.source)
      let program ← (Engine.compile [(signatureUnit, sig.text), (name, m.source)] libs).mapError errorText
      let c : Compiled := { program, sig, mentioned := derived.callsGenerated }
      pure (c, cache.insert key c)
  let scans := scansFor compiled.sig (compiled.mentioned ++ goalWords goal)
  return ({ compiled, scans, program := compiled.program, maxFacts }, cache)

/-! ### Facts from column batches -/

private def colOf (cols : Array (Array Value)) (i : Nat) (table what : String) :
    Except String (Array Value) :=
  match cols[i]? with
  | some c => .ok c
  | none => .error s!"table {table}: the scanner sent no {what} column"

private def nodeTerm (sig : Signature) (table : String) (key : Value) : Except String ResultTerm := do
  let some n := sig.plan.nodes.find? (·.name == table) | throw s!"{table} is not an encoded node table"
  (Codec.node n.id n.keyTy key).mapError (s!"table {table}, primary key: {·}")

private def endpoint (sig : Signature) (r : RelPlan) (src : Bool) (table : String) (key : Value) :
    Except String ResultTerm := do
  let t ← nodeTerm sig table key
  if r.multi then return .app (Origin.endpointCtor r.name src table).ident #[t] else return t

private def strOf : Value → String
  | .str s => s
  | _ => ""

private def idOf : Value → Int
  | .int i => i
  | _ => 0

/-- Check the fact budget, then add the facts. -/
private def addAll (s : Session) (table : String) (batches : List (String × Array (Array ResultTerm))) :
    Except String Session := do
  let n := batches.foldl (· + ·.2.size) 0
  if s.facts + n > s.maxFacts then
    throw s!"elpi_max_facts ({s.maxFacts}) exceeded while loading table {table}; raise it with CALL elpi_max_facts=<n>"
  let mut p := s.program
  for (pred, rows) in batches do
    unless rows.isEmpty do
      p ← (Engine.addFacts p pred rows).mapError errorText
  return { s with program := p, facts := s.facts + n }

/-- Add one column batch of scan `i`. A node batch is `[keys, props…]`; a rel batch is
`[src tables, src keys, internal ids, dst tables, dst keys, props…]`, props in the scan's order.
A NULL property gives no fact. -/
def addBatch (s : Session) (i : Nat) (cols : Array (Array Value)) : Except String Session := do
  let sig := s.compiled.sig
  let some scan := s.scans[i]? | throw s!"no scan {i}"
  match scan with
  | .node ns =>
    let t := ns.plan.name
    let keys ← colOf cols 0 t "key"
    let nodes ← keys.mapM (nodeTerm sig t)
    let mut batches : List (String × Array (Array ResultTerm)) := []
    if ns.listNodes then batches := [(ns.plan.id, nodes.map (#[·]))]
    for h : j in [0:ns.props.length] do
      let p := ns.props[j]
      let col ← colOf cols (j + 1) t p.name
      let mut rows : Array (Array ResultTerm) := #[]
      for k in [0:col.size] do
        match col[k]! with
        | .null => pure ()
        | v => rows := rows.push #[nodes[k]!, ← (Codec.encodeChecked p.ty v).mapError (s!"table {t}, property {p.name}: {·}")]
      batches := batches ++ [(p.pred, rows)]
    addAll s t batches
  | .rel rs =>
    let r := rs.plan
    let srcT ← colOf cols 0 r.name "source table"
    let srcK ← colOf cols 1 r.name "source key"
    let ids ← colOf cols 2 r.name "internal id"
    let dstT ← colOf cols 3 r.name "target table"
    let dstK ← colOf cols 4 r.name "target key"
    let edges := ids.map fun v => Codec.edge r.id (idOf v)
    let mut batches : List (String × Array (Array ResultTerm)) := []
    if rs.listEdges then
      let mut rows : Array (Array ResultTerm) := #[]
      for k in [0:edges.size] do
        rows := rows.push #[← endpoint sig r true (strOf srcT[k]!) srcK[k]!, edges[k]!,
                            ← endpoint sig r false (strOf dstT[k]!) dstK[k]!]
      batches := [(r.id, rows)]
    for h : j in [0:rs.props.length] do
      let p := rs.props[j]
      let col ← colOf cols (j + 5) r.name p.name
      let mut rows : Array (Array ResultTerm) := #[]
      for k in [0:col.size] do
        match col[k]! with
        | .null => pure ()
        | v => rows := rows.push #[edges[k]!, ← (Codec.encodeChecked p.ty v).mapError (s!"table {r.name}, property {p.name}: {·}")]
      batches := batches ++ [(p.pred, rows)]
    addAll s r.name batches

/-! ### Solving in slices -/

/-- A running query. -/
structure Run where
  query : Query
  fuel : Nat
  sliceSteps : Nat
  maxSolutions : Nat
  solutions : Nat := 0

/-- One slice's outcome. -/
inductive Step where
  /-- A solution: each named variable with the JSON form of its binding. -/
  | solution (bindings : Array (String × String)) (next : Run)
  /-- The slice ran out; check interrupt and deadline, then step again. -/
  | paused (next : Run)
  /-- The search ended: `true` when it ran to completion, `false` when `elpi_max_solutions`
  stopped it. -/
  | done (exhausted : Bool)
  | error (msg : String)

private def located (e : Engine.Error) : String :=
  match e with
  | .located ds => "\n".intercalate (ds.map fun d =>
      if d.unit == "<goal>" then s!"goal, column {d.col}: {d.msg}" else s!"{d.unit}:{d.line}:{d.col}: {d.msg}")
  | e => toString e

/-- Parse the goal against the session's program, with its facts. -/
-- @tg: implements:: [[openspec:rule-execution#Untyped debug query]]
-- @tg: implements:: [[openspec:rule-execution#Fresh store per call]]
def start (s : Session) (goal : String) (fuel sliceSteps maxSolutions : Nat) : Except String Run := do
  let q ← (Engine.parseGoal s.program goal fuel).mapError located
  return { query := q, fuel, sliceSteps := max sliceSteps 1, maxSolutions }

/-- Run one slice. -/
-- @tg: implements:: [[openspec:rule-execution#Fuel-sliced execution]]
-- @tg: implements:: [[openspec:rule-execution#Execution limits are errors]]
def step (r : Run) : Step :=
  if r.solutions ≥ r.maxSolutions then .done false
  else
    let ⟨q, fuel, n, maxSol, sols⟩ := r
    match Engine.slice q n with
    | .solution bs _ q' =>
      .solution (bs.map fun (v, t) => (v, (Engine.toJson t).compress))
        { query := q', fuel, sliceSteps := n, maxSolutions := maxSol, solutions := sols + 1 }
    | .paused q' => .paused { query := q', fuel, sliceSteps := n, maxSolutions := maxSol, solutions := sols }
    | .exhausted => .done true
    | .error .outOfFuel =>
      .error s!"elpi_fuel ({fuel}) exhausted: the query needs more resolution steps; raise it with CALL elpi_fuel=<n>"
    | .error e => .error e.toString

end Marien.Exec
