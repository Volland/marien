import Marien.Meta.Reflect
import Marien.Engine

/-!
# Staged rule generation

A module may hold meta-rules between the lines `% @marien meta` and `% @marien end`. They define
`pred generate o:string.` over the reflected schema description (`Reflect`), and every solution
of `generate S` is clause text. Stage 1 runs `generate` and concatenates its solutions in order;
stage 2 is the ordinary save: the module's own clauses and the generated text are loaded as one
program after the shallow signature, type-checked and analysed together, so generated code meets
exactly the checks hand-written code meets.

Stage 1 sees the description and nothing else: no signature and no facts, so a meta-rule that
calls a database predicate is refused by name. It runs under `elpi_fuel` and
`elpi_max_generated_bytes`, never under a clock, because a wall-clock cut-off would make the
generated text depend on time. `generate` is a pure function of the description and the source
(`generate_deterministic`), and the description does not depend on catalog order
(`Reflect.ofSchema_perm`), so neither does the generated text (`generate_perm`).

Every clause the generated text defines must be for a predicate the module or the signature
declares (`checkHeads`, `heads_declared`): generated code cannot add entry points nobody wrote.
-/

-- @lat: [[components#Rule generator]]

namespace Marien.Meta.Stage

open Elpi.Host.Ast (Goal Hyp Term)

/-- Stage 1's budgets. -/
structure Limits where
  fuel : Nat := Engine.defaultFuel
  maxBytes : Nat := 1000000
  deriving Repr, Inhabited

/-! ### The meta section -/

/-- A source with its meta section taken apart; both keep every line where it was, so errors in
either point at the line of the module's source. -/
structure Split where
  /-- The module's own clauses: the meta section's lines are blank. -/
  rules : String
  /-- The meta-rules: every line outside the meta section is blank. -/
  metaRules : String
  hasMeta : Bool
  deriving Repr, Inhabited

/-- The words of a `% @marien …` line, if it is one. -/
def marker? (line : String) : Option (List String) := do
  let rest ← (line.trimAscii.toString.dropPrefix? "%").map (·.toString.trimAscii.toString)
  let body ← (rest.dropPrefix? "@marien").map (·.toString)
  return (body.splitOn " ").filter (· ≠ "")

/-- Split a source at its `% @marien meta` … `% @marien end` sections. -/
def split (src : String) : Except String Split := do
  let lines := src.splitOn "\n"
  let mut rules : Array String := #[]
  let mut metaRules : Array String := #[]
  let mut inMeta := false
  let mut opened := 0
  let mut any := false
  for h : i in [0:lines.length] do
    let line := lines[i]
    match marker? line with
    | some ["meta"] =>
      if inMeta then throw s!"line {i + 1}: a meta section is already open (since line {opened}); close it with % @marien end"
      inMeta := true; opened := i + 1; any := true
      rules := rules.push ""; metaRules := metaRules.push ""
    | some ["end"] =>
      unless inMeta do throw s!"line {i + 1}: % @marien end closes no meta section"
      inMeta := false
      rules := rules.push ""; metaRules := metaRules.push ""
    | _ =>
      if inMeta then rules := rules.push ""; metaRules := metaRules.push line
      else rules := rules.push line; metaRules := metaRules.push ""
  if inMeta then throw s!"line {opened}: the meta section is never closed; end it with % @marien end"
  return { rules := "\n".intercalate rules.toList, metaRules := "\n".intercalate metaRules.toList, hasMeta := any }

/-! ### Stage 1 -/

def descUnit : String := "<schema description>"
def metaUnit (name : String) : String := s!"{name} (meta)"
def genUnit (name : String) : String := s!"{name} (generated)"

/-- The generated text, with the line each solution starts on. -/
structure Generated where
  text : String := ""
  /-- For each solution of `generate`, in order, its first line in `text` (from 1). -/
  starts : List Nat := []
  deriving Repr, Inhabited, BEq

/-- The solution of `generate` that produced line `line` of the generated text (from 1). -/
def Generated.solutionAt (g : Generated) (line : Nat) : Nat :=
  (g.starts.filter (· ≤ line)).length

/-- Concatenate solutions, each ending in a newline. -/
def Generated.ofSolutions (sols : List String) : Generated :=
  let pieces := sols.map fun s => if s.endsWith "\n" then s else s ++ "\n"
  let (starts, _) := pieces.foldl (init := ([], 1)) fun (acc, line) p =>
    (acc ++ [line], line + (p.splitOn "\n").length - 1)
  { text := String.join pieces, starts }

/-- Collect the `S` of every solution, in order, within the byte budget. -/
partial def collect (fuel maxBytes : Nat) (q : Engine.Query) (acc : Array String) (bytes : Nat) :
    Except String (List String) :=
  match Engine.slice q 1000000 with
  | .solution bs _ q' =>
    match bs.find? (·.1 == "S") with
    | some (_, .str s) =>
      let bytes := bytes + s.utf8ByteSize
      if bytes > maxBytes then
        .error s!"stage 1: generate produced more than elpi_max_generated_bytes ({maxBytes}) bytes; raise it with CALL elpi_max_generated_bytes=<n>"
      else collect fuel maxBytes q' (acc.push s) bytes
    | _ => .error "stage 1: a solution of generate did not bind S to a string"
  | .paused q' => collect fuel maxBytes q' acc bytes
  | .exhausted => .ok acc.toList
  | .error .outOfFuel =>
    .error s!"stage 1: elpi_fuel ({fuel}) exhausted while running generate; raise it with CALL elpi_fuel=<n>"
  | .error e => .error s!"stage 1: {e}"

/-- A database predicate named in an `undeclared constant` error of the meta-rules. -/
def dbPredIn (isDb : String → Bool) (e : Engine.Error) : Option String :=
  match e with
  | .located ds => ds.findSome? fun d =>
      match d.msg.splitOn "undeclared constant '" with
      | [_, rest] => let n := (rest.splitOn "'").headD ""; if isDb n then some n else none
      | _ => none
  | _ => none

/-- Stage 1: run the meta-rules of module `name` over the description `desc`. `isDb` tells
the database predicates of the signature, for the error that refuses them. -/
-- @tg: implements:: [[openspec:rule-generation#Stage one meta-rules]]
-- @tg: implements:: [[openspec:rule-generation#Generated code depends only on schema and source]]
def generate (desc : String) (isDb : String → Bool) (name metaRules : String) (lim : Limits) :
    Except String Generated := do
  let units := [(descUnit, desc), (metaUnit name, metaRules)]
  let p ← match Engine.compile units with
    | .ok p => pure p
    | .error e => match dbPredIn isDb e with
      | some d => throw s!"stage 1: {d} is a database predicate; meta-rules see the schema description (schema.node, schema.rel, schema.prop, schema.annot, schema.ident, …), not data"
      | none => throw s!"stage 1: {e}"
  match Engine.predSig? p "generate" with
  | some s =>
    unless s.args.size == 1 && s.args[0]!.mode == .o && s.args[0]!.ty == .const "string" do
      throw "stage 1: the meta section must declare pred generate o:string."
  | none => throw "stage 1: the meta section must declare pred generate o:string."
  let q ← (Engine.goal p "generate" #[.out "S"] lim.fuel).mapError (s!"stage 1: {·}")
  return .ofSolutions (← collect lim.fuel lim.maxBytes q #[] 0)

/-- The same description and source give the same generated text: `generate` is a function, with
no `IO` in its type to make it otherwise. -/
theorem generate_deterministic {d₁ d₂ : String} {isDb : String → Bool} {n₁ n₂ m₁ m₂ : String}
    {lim : Limits} (hd : d₁ = d₂) (hn : n₁ = n₂) (hm : m₁ = m₂) :
    generate d₁ isDb n₁ m₁ lim = generate d₂ isDb n₂ m₂ lim := by
  subst hd hn hm; rfl

/-- The generated text of a schema listed in any order is the same. -/
-- @tg: verifies:: [[openspec:rule-generation#Generated code depends only on schema and source#Catalog order does not matter]] {level: unit}
theorem generate_perm {s t : Schema} (encoded : String → Bool) {isDb : String → Bool} {name metaRules : String}
    {lim : Limits} (hn : s.nodes.Perm t.nodes) (hr : s.rels.Perm t.rels) (ha : s.annots.Perm t.annots) :
    generate (Reflect.text s encoded) isDb name metaRules lim = generate (Reflect.text t encoded) isDb name metaRules lim := by
  apply generate_deterministic _ rfl rfl
  unfold Reflect.text
  rw [Reflect.ofSchema_perm encoded hn hr ha]

/-! ### Stage 2 checks -/

/-- The clause heads that are declared nowhere in `allowed`. -/
def undeclared (allowed heads : List String) : List String := heads.filter (!allowed.contains ·)

/-- Every predicate the generated text has clauses for is in `allowed`: the module's own
declarations and the signature's predicates. -/
def checkHeads (allowed heads : List String) : Except String Unit :=
  match undeclared allowed heads with
  | [] => .ok ()
  | h :: _ => .error s!"generated code defines {h}, which neither the module nor the signature declares"

theorem heads_declared {allowed heads : List String} (h : checkHeads allowed heads = .ok ()) :
    ∀ p ∈ heads, p ∈ allowed := by
  intro p hp
  unfold checkHeads at h
  split at h
  · rename_i hnil
    have := List.filter_eq_nil_iff.mp hnil p hp
    simpa using this
  · contradiction

/-- An error of stage 2 with its positions in the generated text traced to the solution of
`generate` that produced them. -/
def locate (name : String) (g : Generated) (e : Engine.Error) : String :=
  match e with
  | .located ds => "\n".intercalate (ds.map fun d =>
      if d.unit == genUnit name then
        s!"{d.unit}:{d.line}:{d.col}: {d.msg} (in the text of solution {g.solutionAt d.line} of generate, stage 1)"
      else s!"{d.unit}:{d.line}:{d.col}: {d.msg}")
  | e => toString e

end Marien.Meta.Stage
