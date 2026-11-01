import Marien.Analysis.Locality

/-!
# Verdicts

What the rule analyzer stores with a module for each entry point: what it reaches, whether it is
monotone or `dynamic` and why, and its accepted partition. `analyze` runs at save time and on
every recheck, so the verdicts always describe the compiled code; a declared partition that the
checks reject fails the save.
-/

-- @lat: [[components#Rule analyzer]]

namespace Marien.Analysis

open Lean (Json)
open Marien.Encoding

/-- An accepted partition. -/
inductive PartitionPlan where
  /-- Anchors of node table `table`; `dirs` are the rel tables and the directions
  (`outgoing`, `incoming`) the neighbourhood follows. -/
  | anchor (table : String) (radius : Nat) (dirs : List (String × String))
  /-- Buckets of node table `table` by property `prop`. -/
  | key (table prop : String)
  deriving Repr, Inhabited, BEq

/-- The verdict of one entry point. -/
structure EntryVerdict where
  pred : String
  /-- Generated database predicates it reaches. -/
  reached : List String
  /-- Their tables. -/
  tables : List String
  monotone : Bool
  dynamic : Bool
  /-- The first construct that makes it non-monotone. -/
  offense : Option Offense := none
  /-- The goal that makes it dynamic. -/
  dynamicGoal : Option String := none
  partition : Option PartitionPlan := none
  deriving Repr, Inhabited, BEq

namespace PartitionPlan

def toJson : PartitionPlan → Json
  | .anchor t r ds => Json.mkObj [("kind", "anchor"), ("table", t), ("radius", r),
      ("directions", Json.arr (ds.map fun (rel, d) => Json.arr #[rel, d]).toArray)]
  | .key t p => Json.mkObj [("kind", "key"), ("table", t), ("prop", p)]

def ofJson? (j : Json) : Except String PartitionPlan := do
  match ← j.getObjValAs? String "kind" with
  | "anchor" =>
    let ds ← j.getObjValAs? (List (List String)) "directions"
    return .anchor (← j.getObjValAs? String "table") (← j.getObjValAs? Nat "radius")
      (ds.filterMap fun | [a, b] => some (a, b) | _ => none)
  | "key" => return .key (← j.getObjValAs? String "table") (← j.getObjValAs? String "prop")
  | k => throw s!"unknown partition kind {k}"

/-- For the shim: `["anchor", table, radius, rel₁, dir₁, …]` or `["key", table, prop]`. -/
def describe : PartitionPlan → Array String
  | .anchor t r ds => #["anchor", t, toString r] ++ (ds.flatMap fun (rel, d) => [rel, d]).toArray
  | .key t p => #["key", t, p]

end PartitionPlan

namespace EntryVerdict

def toJson (v : EntryVerdict) : Json :=
  let opt {α} (f : α → Json) : Option α → Json := fun o => (o.map f).getD Json.null
  Json.mkObj [("pred", v.pred), ("reached", Lean.toJson v.reached), ("tables", Lean.toJson v.tables),
    ("monotone", v.monotone), ("dynamic", v.dynamic),
    ("offense", opt (fun o => Json.mkObj [("construct", o.construct), ("pos", o.pos), ("pred", o.pred)]) v.offense),
    ("dynamic_goal", opt Json.str v.dynamicGoal), ("partition", opt PartitionPlan.toJson v.partition)]

def ofJson? (j : Json) : Except String EntryVerdict := do
  let opt {α} (k : String) (f : Json → Except String α) : Except String (Option α) :=
    match j.getObjVal? k with
    | .ok .null | .error _ => .ok none
    | .ok x => some <$> f x
  return { pred := ← j.getObjValAs? String "pred", reached := ← j.getObjValAs? (List String) "reached"
           tables := ← j.getObjValAs? (List String) "tables", monotone := ← j.getObjValAs? Bool "monotone"
           dynamic := ← j.getObjValAs? Bool "dynamic"
           offense := ← opt "offense" fun o => do
             return { construct := ← o.getObjValAs? String "construct", pos := ← o.getObjValAs? String "pos"
                      pred := ← o.getObjValAs? String "pred" }
           dynamicGoal := ← opt "dynamic_goal" fun s => s.getStr?
           partition := ← opt "partition" PartitionPlan.ofJson? }

/-- Why the entry point is not monotone, for errors. -/
def whyNotMonotone (v : EntryVerdict) : String :=
  match v.offense, v.dynamicGoal with
  | some o, _ => if o.construct == "=>" then
      s!"it is dynamic because of {v.dynamicGoal.getD "=>"} at {o.pos}, which adds {o.pred}"
    else s!"{o.construct} at {o.pos} reaches {o.pred}"
  | none, _ => "it is marked dynamic"

end EntryVerdict

/-- The position of the argument of type `subject`. -/
def subjectArg? (c : Ctx) (pred : String) : Option Nat :=
  (c.sigs.find? (·.name == pred)).bind fun s => s.args.toList.findIdx? (·.ty == .const "subject")

/-- Analyse every entry point; `own` are the module's annotations. Rejected partitions are errors;
the warnings name inferred `dynamic` marks a `% @marien static` cannot clear. -/
-- @tg: implements:: [[openspec:rule-analysis#Dynamic inference]]
-- @tg: implements:: [[openspec:rule-analysis#Monotonicity check]]
def analyze (c : Ctx) (sig : Signature) (entries : List String) (own : List Annotation) :
    Except String (List EntryVerdict × List String) := do
  let g := callGraph c
  let shp := shapes sig
  for a in own do
    unless entries.contains a.pred do
      throw s!"annotation for {a.pred}: the module has no entry point {a.pred}"
  let mut out : List EntryVerdict := []
  let mut warnings : List String := []
  for e in entries do
    let r := reach c g e
    let dyn := dynamicCause c r
    let marked := own.any fun | .dynamic p _ => p == e | _ => false
    let isDynamic := dyn.isSome || marked
    let offense := (firstOffense c g r).orElse fun _ => dyn.map (·.2)
    if let some (goal, o) := dyn then
      if own.any (fun | .static p _ => p == e | _ => false) then
        warnings := warnings ++ [s!"{e} stays dynamic: {goal} at {o.pos} adds {o.pred}; % @marien static cannot clear it"]
    let mut v : EntryVerdict :=
      { pred := e, reached := r.generated, tables := r.tables, monotone := offense.isNone && !isDynamic
        dynamic := isDynamic, offense, dynamicGoal := dyn.map (·.1) }
    for a in own.filter (·.pred == e) do
      let partitionOf (what : String) : Except String Unit := do
        if let some (goal, o) := dyn then
          throw s!"cannot partition {e} by {what}: it is dynamic because of {goal} at {o.pos}"
        if marked then throw s!"cannot partition {e} by {what}: it is marked dynamic"
      match a with
      | .anchor _ kind radius line =>
        partitionOf kind
        let some n := sig.plan.nodes.find? (·.id == kind)
          | throw s!"line {line}: {kind} is not a node table of the signature"
        let some k := subjectArg? c e
          | throw s!"line {line}: {e} has no subject argument to anchor"
        let dirs ← (anchorCheck c g shp e k n.name n.id radius).mapError
          (s!"partition {e} by {kind} radius {radius} is rejected: {·}")
        v := { v with partition := some (.anchor n.name radius dirs) }
      | .key _ prop line =>
        partitionOf prop
        let some (n, p) := sig.plan.nodes.findSome? fun n => (n.props.find? (·.pred == prop)).map (n, ·)
          | throw s!"line {line}: {prop} is not a node property of the signature"
        (keyCheck c g shp e n.name prop).mapError (s!"partition {e} by {prop} is rejected: {·}")
        v := { v with partition := some (.key n.name p.name) }
      | _ => pure ()
    out := out ++ [v]
  return (out, warnings)

end Marien.Analysis
