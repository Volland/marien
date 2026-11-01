import Marien.Encoding.Codec
import Marien.Store.Module

/-!
# Validator

`elpi_validate` runs `violation S C X` in every listed module that follows the validation
protocol (`pred violation o:severity, o:string, o:subject.`) and turns each solution into one
report row `(module, version, severity, code, message, subject_label, subject_pk)`.

The executor drives the search; this module decides which modules take part and in what order,
decodes a solution into a row with the subject codec, asks `violation_message` for the message
when the module declares it (the code is the message otherwise), and keeps only rows at or above
the minimum severity (`filter_sound`).
-/

-- @lat: [[components#Validator]]

namespace Marien.Exec

open Marien.Encoding Marien.Encoding.Codec Marien.Store
open Marien.Engine (ResultTerm Program)

/-! ### Severities -/

inductive Severity where
  | error
  | warning
  | info
  deriving Repr, Inhabited, BEq, DecidableEq

namespace Severity

/-- `error > warning > info`. -/
def rank : Severity → Nat
  | .error => 2
  | .warning => 1
  | .info => 0

def name : Severity → String
  | .error => "error"
  | .warning => "warning"
  | .info => "info"

def ofName? : String → Option Severity
  | "error" => some .error
  | "warning" => some .warning
  | "info" => some .info
  | _ => none

/-- The severity a term names. -/
def ofTerm? : ResultTerm → Option Severity
  | .const n => ofName? n
  | _ => none

end Severity

/-- Whether a row of severity `s` passes the threshold `min`. -/
def keep (min s : Severity) : Bool := decide (min.rank ≤ s.rank)

/-- The rows at or above `min`, in their order. -/
def filterSeverity {α : Type} (min : Severity) (rows : List (Severity × α)) : List (Severity × α) :=
  rows.filter (keep min ·.1)

/-- The severity filter keeps exactly the rows at or above the threshold. -/
-- @tg: verifies:: [[openspec:validation#Uniform validation report#Severity filter]] {level: unit}
theorem filter_sound {α : Type} (min : Severity) (rows : List (Severity × α)) (x : Severity × α) :
    x ∈ filterSeverity min rows ↔ x ∈ rows ∧ min.rank ≤ x.1.rank := by
  simp [filterSeverity, keep]

/-! ### Which modules take part -/

/-- The modules `elpi_validate` runs: the listed ones in the listed order (every module by name
when the list is omitted), skipping those that do not declare `violation`. A listed module that
does not exist is an error. -/
def validationOrder (stored : List Stored) (requested : Option (List String)) :
    Except String (List String) := do
  let names := requested.getD (Schema.sortStrings (stored.map (·.name)))
  let mods ← names.mapM fun n => match stored.find? (·.name == n) with
    | some m => pure m
    | none => throw s!"no module named {n}"
  return (mods.filter (Derived.ofStored · |>.validates)).map (·.name)

/-! ### Rows -/

/-- What a report row needs besides the solution. -/
structure ReportCtx where
  module : String
  version : Nat
  subjects : List SubjectCase
  /-- The module declares `violation_message`. -/
  hasMessage : Bool
  minSeverity : Severity
  /-- Resolution steps for each `violation_message` call. -/
  fuel : Nat := 0
  deriving Inhabited

/-- A primary key (or edge id) as report text. -/
partial def keyText : Value → String
  | .int i => toString i
  | .float b => toString (Float.ofBits b)
  | .str s => s
  | .bool b => if b then "true" else "false"
  | .list xs => "[" ++ ", ".intercalate (xs.map keyText) ++ "]"
  | .struct fs => "{" ++ ", ".intercalate (fs.map keyText) ++ "}"
  | .null => ""

/-- The message of a violation: the first answer of `violation_message code subject M`, or the
code when the module does not declare it or it has no answer. -/
partial def message (p : Program) (ctx : ReportCtx) (code : String) (subject : ResultTerm) :
    Except String String := do
  if !ctx.hasMessage then return code
  let q ← (Engine.goal p "violation_message" #[.value (.str code), .value subject, .out "M"] ctx.fuel).mapError
    (s!"violation_message: {·}")
  let rec loop (q : Engine.Query) : Except String String :=
    match Engine.slice q ctx.fuel with
    | .solution bs _ _ => match bs.find? (·.1 == "M") with
      | some (_, .str m) => .ok m
      | _ => .ok code
    | .paused q' => loop q'
    | .exhausted => .ok code
    | .error .outOfFuel =>
      .error s!"elpi_fuel ({ctx.fuel}) exhausted in violation_message; raise it with CALL elpi_fuel=<n>"
    | .error e => .error s!"violation_message: {e}"
  loop q

/-- The report row of a solution of `violation S C X`, or `none` when its severity is below the
threshold. -/
-- @tg: implements:: [[openspec:validation#Uniform validation report]] {confidence: partial, note: "one row per solution; the executor and the shim run the modules"}
def reportRow (p : Program) (ctx : ReportCtx) (bindings : Array (String × ResultTerm)) :
    Except String (Option (Array String)) := do
  let get (v : String) : Except String ResultTerm :=
    match bindings.find? (·.1 == v) with
    | some (_, t) => .ok t
    | none => .error s!"violation solution without {v}"
  let some sev := Severity.ofTerm? (← get "S")
    | throw s!"violation gave a severity that is not error, warning or info"
  if !keep ctx.minSeverity sev then return none
  let code ← match ← get "C" with
    | .str c => pure c
    | t => throw s!"violation gave the code {t}, which is not a string"
  let subj ← get "X"
  let some (label, key) := decodeSubject ctx.subjects subj
    | throw s!"violation gave the subject {subj}, which is not a subject of an existing table"
  let msg ← message p ctx code subj
  return some #[ctx.module, toString ctx.version, sev.name, code, msg, label, keyText key]

end Marien.Exec
