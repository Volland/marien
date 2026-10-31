import Elpi.Host

/-!
# Engine contract

The only door from Marien to LeanElpi. Every other Marien module calls the engine through these
names, so an engine upgrade touches one file, and `tests/EngineContract.lean` checks each promise
below against the pinned release.
-/

-- @lat: [[components#Engine contract]]

namespace Marien.Engine

export Elpi.Host (TyTerm Arg PredSig ResultTerm GoalArg Query Slice Diagnostic Error)

/-- A compiled LeanElpi program. -/
abbrev Program := Elpi.CompiledProgram

/-- The default budget of resolution steps per run. -/
def defaultFuel : Nat := Elpi.defaultFuel

/-- Declared argument types and modes of a predicate; the shim declares output columns from it at
bind time. -/
-- @tg: implements:: [[openspec:engine-host-api#Predicate signature lookup]] {note: "realized in lean-elpi Elpi.Host"}
def predSig? (p : Program) (name : String) : Option PredSig := Elpi.Host.predSig? p name

/-- Compile the generated signature and a module's source as one program, with errors located in
the unit they come from. `accumulate` resolves against `libs`, the stored modules by name. -/
-- @tg: implements:: [[openspec:engine-host-api#Multi-unit load keeps positions]] {note: "realized in lean-elpi Elpi.Host"}
-- @tg: implements:: [[openspec:engine-host-api#Stored modules resolve accumulate]] {note: "realized in lean-elpi Elpi.Host"}
def compile (units : List (String × String)) (libs : List (String × String) := []) :
    Except Error Program :=
  Elpi.Host.loadUnits units libs

/-- The modules a source accumulates, by name, without loading them. -/
def accumulates (name src : String) : Except Error (List String) := Elpi.Host.accumulates name src

/-- Identifiers the signature generator must not produce: keywords and library names. -/
def reservedNames : Std.HashSet String := Elpi.Host.reservedNames

/-- A goal built from parameter values and output variables, never from text. -/
-- @tg: implements:: [[openspec:engine-host-api#Goals built from terms]] {note: "realized in lean-elpi Elpi.Host"}
def goal (p : Program) (pred : String) (args : Array GoalArg) (fuel : Nat := defaultFuel) :
    Except Error Query :=
  Elpi.Host.buildGoal p pred args fuel

/-- A goal typed by a user, for the untyped debug query; errors are located in `<goal>`. -/
-- @tg: implements:: [[openspec:engine-host-api#Goals parsed from text for debugging]] {note: "realized in lean-elpi Elpi.Host"}
def parseGoal (p : Program) (text : String) (fuel : Nat := defaultFuel) : Except Error Query :=
  Elpi.Host.parseGoal p text fuel

/-- Run at most `n` steps; the executor checks interrupts and deadlines between slices. -/
-- @tg: implements:: [[openspec:engine-host-api#Resumable fuel slices]] {note: "realized in lean-elpi Elpi.Host"}
def slice (q : Query) (n : Nat) : Slice := Elpi.Host.runSlice q n

/-- The bindings of a solution as structured terms, and their JSON form for `elpi_query`. -/
-- @tg: implements:: [[openspec:engine-host-api#Structured solution terms]] {note: "realized in lean-elpi Elpi.Host"}
def toJson (t : ResultTerm) : Lean.Json := t.toJson

def fromJson? (j : Lean.Json) : Option ResultTerm := Elpi.Host.ResultTerm.fromJson? j

/-- Facts materialized from the database, added as terms in one batch. -/
-- @tg: implements:: [[openspec:engine-host-api#Bulk fact loading]] {note: "realized in lean-elpi Elpi.Host"}
def addFacts (p : Program) (pred : String) (rows : Array (Array ResultTerm)) : Except Error Program :=
  Elpi.Host.addFacts p pred rows

/-- The clauses of a module, for rule analysis and staging. -/
-- @tg: implements:: [[openspec:engine-host-api#Public clause AST]] {note: "realized in lean-elpi Elpi.Host"}
def clauses (units : List (String × String)) (libs : List (String × String) := [])
    (view : String → Bool := fun _ => true) : Except Error Elpi.Host.Ast.Program :=
  Elpi.Host.ast units libs view

end Marien.Engine
