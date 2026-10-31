import Marien.Engine
import Marien.Encoding.Signature
import Marien.Store.Literal

/-!
# Module store

Modules live in the system tables `_elpi_module` and `_elpi_accumulates`. Every write is checked
here, at bind time of the calling table function, and comes back as Cypher statements that the
shim returns from `rewriteFunc`, so a write runs in the caller's transaction or not at all.

`save` parses the module, loads it after the generated signature with its accumulated modules
as libraries, type-checks it, extracts its derived metadata from the clause AST and checks its
`accumulate` dependencies; only then does it produce the statement that stores it. Sources are
embedded as escaped literals (`Literal.quote`), proved to round-trip and to stay inside their
literal.

The shim hands over the stored modules (name, version, source) read from `_elpi_module` in the
caller's transaction; everything else is pure.
-/

-- @lat: [[components#Module store]]

namespace Marien.Store

open Lean (Json ToJson toJson)
open Marien.Encoding
open Elpi.Host.Ast (Goal Hyp Term)

/-- A module as stored in `_elpi_module`. -/
structure Stored where
  name : String
  version : Nat
  source : String
  /-- The `derived` JSON written by the save. -/
  derived : String := ""
  deriving Repr, Inhabited

/-- Name of the unit holding the generated signature; not a valid module name. -/
def signatureUnit : String := "<signature>"

/-- Metadata extracted from a module's clause AST, stored as JSON in `_elpi_module.derived`. -/
structure Derived where
  /-- Predicates the module declares with `pred`. -/
  declares : List String
  /-- Predicates the module has clauses for. -/
  defines : List String
  /-- Generated predicates its clauses mention, directly or through accumulated modules. -/
  callsGenerated : List String
  /-- Modules it accumulates, in order. -/
  accumulates : List String
  /-- Predicates declared with `pred` and modes: the entry points. -/
  entries : List String
  deriving Repr, Inhabited, BEq

namespace Derived

def toJson (d : Derived) : Json :=
  Json.mkObj [("declares", Lean.toJson d.declares), ("defines", Lean.toJson d.defines),
    ("calls_generated", Lean.toJson d.callsGenerated), ("accumulates", Lean.toJson d.accumulates),
    ("entries", Lean.toJson d.entries)]

def ofJson? (j : Json) : Except String Derived := do
  return { declares := ← j.getObjValAs? (List String) "declares"
           defines := ← j.getObjValAs? (List String) "defines"
           callsGenerated := ← j.getObjValAs? (List String) "calls_generated"
           accumulates := ← j.getObjValAs? (List String) "accumulates"
           entries := ← j.getObjValAs? (List String) "entries" }

end Derived

/-! ### Errors -/

def errorText (e : Engine.Error) : String := toString e

/-! ### Mentioned names -/

mutual
partial def termNames : Term → List String
  | .const n => [n]
  | .app h args => termNames h ++ args.flatMap termNames
  | .lam _ b => termNames b
  | _ => []

partial def goalNames : Goal → List String
  | .conj gs => gs.flatMap goalNames
  | .disj a b => goalNames a ++ goalNames b
  | .not g | .pi _ g | .sigma _ g => goalNames g
  | .impl hs b => hs.flatMap hypNames ++ goalNames b
  | .call p args | .builtin p args => p :: args.flatMap termNames
  | .other t => termNames t
  | _ => []

partial def hypNames : Hyp → List String
  | .mk h b => termNames h ++ goalNames b
end

/-! ### Dependencies -/

/-- The modules each stored module accumulates, from its source. -/
def edgesOf (stored : List Stored) : List (String × List String) :=
  stored.map fun s => (s.name, (Engine.accumulates s.name s.source).toOption.getD [])

/-- A path `start → … → start` through the accumulate edges, if one exists. -/
partial def findCycle (edges : List (String × List String)) (start : String) : Option (List String) :=
  let next (n : String) : List String := ((edges.find? (·.1 == n)).map (·.2)).getD []
  let rec go (path : List String) (n : String) (fuel : Nat) : Option (List String) :=
    match fuel with
    | 0 => none
    | fuel + 1 =>
      (next n).findSome? fun m =>
        if m == start then some (path ++ [m])
        else if path.contains m then none
        else go (path ++ [m]) m fuel
  go [start] start (edges.length + 1)

/-- Modules in an order where each comes after the modules it accumulates; ties by name. -/
partial def topoOrder (edges : List (String × List String)) : Except String (List String) :=
  let names := edges.map (·.1)
  let rec go (done : List String) (todo : List String) : Except String (List String) :=
    if todo.isEmpty then .ok done
    else
      let ready := todo.filter fun n =>
        (((edges.find? (·.1 == n)).map (·.2)).getD []).all fun d => done.contains d || !names.contains d
      match Schema.sortStrings ready with
      | [] => .error s!"modules {", ".intercalate todo} accumulate each other"
      | r :: _ => go (done ++ [r]) (todo.erase r)
  go [] names

/-! ### Statements -/

/-- Create the system tables if they are missing. -/
-- @tg: implements:: [[openspec:rule-storage#Module system tables]]
def initStatements : List String :=
  ["CREATE NODE TABLE IF NOT EXISTS _elpi_module(name STRING PRIMARY KEY, version INT64, " ++
     "source STRING, generated STRING, schema_hash STRING, status STRING, derived STRING, " ++
     "saved_at TIMESTAMP)",
   "CREATE REL TABLE IF NOT EXISTS _elpi_accumulates(FROM _elpi_module TO _elpi_module)",
   "RETURN 'ok' AS result"]

/-- Store a checked module: one statement that bumps the version, writes the row and replaces
its outgoing accumulate edges. -/
def saveStatement (name source schemaHash derived : String) (deps : List String)
    (warnings : List String := []) : String :=
  let q := Literal.quote
  let depsPart :=
    if deps.isEmpty then ""
    else s!"UNWIND [{", ".intercalate (deps.map q)}] AS dep MATCH (d:_elpi_module \{name: dep}) " ++
      "CREATE (m)-[:_elpi_accumulates]->(d) WITH DISTINCT m "
  s!"MERGE (m:_elpi_module \{name: {q name}}) SET m.version = coalesce(m.version, 0) + 1, " ++
  s!"m.source = {q source}, m.generated = '', m.schema_hash = {q schemaHash}, m.status = 'ok', " ++
  s!"m.derived = {q derived}, m.saved_at = current_timestamp() " ++
  "WITH m OPTIONAL MATCH (m)-[e:_elpi_accumulates]->() DELETE e WITH DISTINCT m " ++
  depsPart ++ s!"RETURN m.name AS name, m.version AS version, CAST([{", ".intercalate (warnings.map q)}] AS STRING[]) AS warnings"

/-! ### Save -/

/-- A module that passed every check, with the statement that stores it. -/
structure Checked where
  name : String
  derived : Derived
  schemaHash : String
  warnings : List String
  statement : String
  deriving Inhabited

/-- Check a module against the schema and the stored modules, and build its save statement.
Nothing is written unless this succeeds. -/
-- @tg: implements:: [[openspec:rule-storage#Save checks before storing]]
-- @tg: implements:: [[openspec:rule-storage#Derived module metadata]]
-- @tg: implements:: [[openspec:rule-storage#Accumulate dependencies]]
def check (schema : Schema) (stored : List Stored) (name source : String) :
    Except String Checked := do
  if name.isEmpty || name == signatureUnit then throw s!"'{name}' is not a module name"
  let sig ← (Signature.ofSchema (Engine.reservedNames.contains ·) schema).mapError
    (s!"signature: {·}")
  let direct ← (Engine.accumulates name source).mapError errorText
  for d in direct do
    unless stored.any (·.name == d) do
      throw s!"module {name} accumulates {d}, which is not stored"
  let edges := (name, direct) :: (edgesOf stored).filter (·.1 != name)
  if let some cyc := findCycle edges name then
    throw s!"module {name} would make an accumulate cycle: {" → ".intercalate cyc}"
  let units := [(signatureUnit, sig.text), (name, source)]
  let libs := (stored.filter (·.name != name)).map fun s => (s.name, s.source)
  let own ← (Engine.clauses units libs (· == name)).mapError errorText
  let all ← (Engine.clauses units libs (· != signatureUnit)).mapError errorText
  let generated := sig.preds.map (·.1)
  let mentioned := all.clauses.toList.flatMap fun c => termNames c.head ++ goalNames c.body
  let declares := own.preds.toList.map (·.name)
  let derived : Derived :=
    { declares
      defines := (own.clauses.toList.map (·.pred)).eraseDups
      callsGenerated := Schema.sortStrings (generated.filter mentioned.contains).eraseDups
      accumulates := direct
      entries := declares }
  let hash := Schema.hash schema
  return { name, derived, schemaHash := hash, warnings := sig.warnings
           statement := saveStatement name source hash derived.toJson.compress direct sig.warnings }

/-- `elpi_save`: the statements storing one checked module. -/
def save (schema : Schema) (stored : List Stored) (name source : String) :
    Except String (List String × List String) := do
  let c ← check schema stored name source
  return ([c.statement], c.warnings)

/-! ### Drop, export and import -/

/-- `elpi_drop`: delete a module nothing accumulates. -/
-- @tg: implements:: [[openspec:rule-storage#Drop protects dependents]]
def drop (stored : List Stored) (name : String) : Except String (List String) := do
  unless stored.any (·.name == name) do throw s!"no module named {name}"
  let dependents := (edgesOf stored).filterMap fun (n, ds) =>
    if n != name && ds.contains name then some n else none
  unless dependents.isEmpty do
    throw s!"cannot drop {name}: {", ".intercalate dependents} accumulate{if dependents.length == 1 then "s" else ""} it"
  let q := Literal.quote name
  return [s!"MATCH (m:_elpi_module \{name: {q}}) DETACH DELETE m RETURN {q} AS dropped"]

/-- `elpi_export`: every module after the modules it accumulates. -/
-- @tg: implements:: [[openspec:rule-storage#Export and import]]
def exportOrder (stored : List Stored) : Except String (List Stored) := do
  let order ← topoOrder (edgesOf stored)
  return order.filterMap fun n => stored.find? (·.name == n)

/-- `elpi_import`: save a bundle `[{name, source}, …]` in dependency order, all or nothing. -/
def importBundle (schema : Schema) (stored : List Stored) (bundle : String) :
    Except String (List String × List String) := do
  let j ← Json.parse bundle
  let items ← match j with
    | .arr xs => xs.toList.mapM fun x => do
        return ((← x.getObjValAs? String "name"), (← x.getObjValAs? String "source"))
    | _ => throw "the bundle must be a JSON array of {name, source} objects"
  let mods : List Stored := items.map fun (n, s) => { name := n, version := 0, source := s }
  let order ← topoOrder (edgesOf mods)
  let mut known := stored
  let mut stmts : List String := []
  let mut warnings : List String := []
  for n in order do
    let some m := mods.find? (·.name == n) | continue
    let c ← (check schema known m.name m.source).mapError (s!"module {n}: {·}")
    stmts := stmts ++ [c.statement]
    warnings := warnings ++ c.warnings
    known := m :: known.filter (·.name != n)
  return (stmts ++ [s!"RETURN {order.length} AS imported"], warnings.eraseDups)

end Marien.Store
