import Lean.Elab.Frontend
import Elpi
import Marien.Encoding.Signature
import Marien.Encoding.Dump
import Marien.Engine

/-!
# Offline codegen

Lean inductives for a schema, so proofs about rules can talk about real Lean types. The tool reads
a schema dump (`CALL elpi_signature(format := 'json')`), calls the same `Signature.ofSchema` the
extension calls at run time, and prints its declarations with `LeanPrinter` instead of
`ElpiPrinter`: one `inductive … deriving Elpi` per kind.

```lean
namespace Schema
inductive «person» where
  | «person» : Int → «person»
  deriving Elpi
inductive «subject» where
  | «subj_person» : «person» → «subject»
  deriving Elpi
end Schema

elpi_program Schema.signature
elpi_accumulate Schema.signature lp%{ … the runtime signature … }%
```

`deriving Elpi` registers the ELPI `kind` and `type` declarations of each inductive. After
emitting, the tool elaborates the module and compares those derived declarations with the
`ElpiPrinter` output, kind for kind and constructor for constructor, on parsed types
(`checkAgreement`), so a printer that drifts from the encoding fails the tool.

The module also accumulates the runtime signature into the program `<namespace>.signature`.
LeanElpi puts derived declarations before accumulated ones, and a `pred person` after a
`type person` replaces the constructor; the runtime text declares each predicate before its
constructor, so accumulating it after the derived types restores the overloading the database
has, and stored rules load against the program unchanged.
-/

-- @lat: [[components#Offline codegen]]

namespace Marien.Offline

open Lean Elab
open Marien.Encoding

/-! ### The kinds of a signature -/

/-- A kind and its constructors, in declaration order. -/
structure Inductive where
  kind : String
  ctors : List (String × List ATy)
  deriving Repr, Inhabited, BEq

/-- The kind an argument type names directly: a record's own field kinds are dependencies of the
record's inductive, not of its users. -/
def etyKinds : ETy → List String
  | .list e => etyKinds e
  | .record c _ => [c]
  | _ => []

def atyKinds : ATy → List String
  | .val t => etyKinds t
  | .kind k => [k]

/-- The kind/constructor skeleton of a declaration list: every kind with the constructors
declared for it, in declaration order. Predicates are not part of it. -/
def skeleton (ds : List Decl) : List Inductive :=
  let kinds := (ds.filterMap fun | .kind k => some k | _ => none).eraseDups
  kinds.map fun k => { kind := k, ctors := ds.flatMap fun
    | .ctor cs args r => if r == k then cs.map (·, args) else []
    | _ => [] }

/-- The kinds in an order Lean can declare them: each after the kinds its constructors use. The
encoding has no recursive or mutually recursive kinds; one would be reported. -/
def declOrder (is : List Inductive) : Except String (List Inductive) := Id.run do
  let mut done : List String := []
  let mut out : List Inductive := []
  let mut todo := is
  while !todo.isEmpty do
    let ready (i : Inductive) := i.ctors.all fun (_, args) =>
      args.all fun a => (atyKinds a).all done.contains
    match todo.find? ready with
    | some i =>
      done := done ++ [i.kind]
      out := out ++ [i]
      todo := todo.filter (·.kind != i.kind)
    | none => return .error s!"kinds {", ".intercalate (todo.map (·.kind))} depend on each other or on an undeclared kind"
  return .ok out

/-! ### `LeanPrinter`

The printer maps each argument type to a Lean type (`LTy`), then renders it. `derive_eq_elpi`
proves, against a model of what `deriving Elpi` does with those Lean types, that every derived
constructor gets the argument types the `ElpiPrinter` writes; the agreement check and the
property test check the real `deriving Elpi`. -/

/-- The Lean types the printer writes. -/
inductive LTy where
  | int
  | float
  | string
  | bool
  | list (elem : LTy)
  /-- An inductive the module declares, by its ELPI kind name. -/
  | ind (name : String)
  deriving Repr, Inhabited, BEq

def etyLty : ETy → LTy
  | .int => .int
  | .float => .float
  | .string => .string
  | .bool => .bool
  | .list e => .list (etyLty e)
  | .record c _ => .ind c

def atyLty : ATy → LTy
  | .val t => etyLty t
  | .kind k => .ind k

/-- A Lean identifier for a generated ELPI name: always quoted, since names contain `.`. -/
def quoteName (n : String) : String := "«" ++ n ++ "»"

def LTy.render : LTy → String
  | .int => "Int"
  | .float => "Float"
  | .string => "String"
  | .bool => "Bool"
  | .list e => s!"List ({LTy.render e})"
  | .ind n => quoteName n

/-- An ELPI type, positions erased: what LeanElpi's parser reads, compared by the agreement
check. -/
inductive PTy where
  | con (n : String) (args : List PTy)
  | var (n : String)
  | arrow (a b : PTy)
  deriving BEq, Inhabited

/-- A model of `deriving Elpi`'s `elpiTypeOf` on the types the printer writes: `Int` is `int`,
`List α` is `list α`, and a derived inductive is its kind, the short name with the first letter
lowered (`Elpi.lowerFirst`). -/
def LTy.derive : LTy → PTy
  | .int => .con "int" []
  | .float => .con "float" []
  | .string => .con "string" []
  | .bool => .con "bool" []
  | .list e => .con "list" [LTy.derive e]
  | .ind n => .con (Elpi.lowerFirst n) []

/-- The type the `ElpiPrinter` writes for a property value, as LeanElpi parses it. -/
def etyPty : ETy → PTy
  | .int => .con "int" []
  | .float => .con "float" []
  | .string => .con "string" []
  | .bool => .con "bool" []
  | .list e => .con "list" [etyPty e]
  | .record c _ => .con c []

def atyPty : ATy → PTy
  | .val t => etyPty t
  | .kind k => .con k []

theorem etyDerive_lty :
    (t : ETy) → (∀ k ∈ etyKinds t, Elpi.lowerFirst k = k) → (etyLty t).derive = etyPty t
  | .list e, h => by
    simp only [etyLty, LTy.derive, etyPty, etyDerive_lty e (by simpa [etyKinds] using h)]
  | .record c _, h => by simp only [etyLty, LTy.derive, etyPty, h c (by simp [etyKinds])]
  | .int, _ | .float, _ | .string, _ | .bool, _ => rfl

/-- A kind and its constructors as `deriving Elpi` declares them for the inductive the printer
writes (model): each constructor keeps its name (one quoted name component) and gets the derived
types of its Lean argument types; the result is the kind. -/
def Inductive.derived (i : Inductive) : List (String × List PTy × PTy) :=
  i.ctors.map fun (c, args) => (c, args.map fun a => (atyLty a).derive, .con (Elpi.lowerFirst i.kind) [])

/-- The same constructors as the `ElpiPrinter` declares them. -/
def Inductive.runtime (i : Inductive) : List (String × List PTy × PTy) :=
  i.ctors.map fun (c, args) => (c, args.map atyPty, .con i.kind [])

/-- Generated names start with a lower-case letter (`Origin.valid`), so lowering the first
letter keeps them. -/
def Inductive.lowerNames (i : Inductive) : Prop :=
  Elpi.lowerFirst i.kind = i.kind ∧ ∀ c ∈ i.ctors, ∀ a ∈ c.2, ∀ k ∈ atyKinds a, Elpi.lowerFirst k = k

/-- The kind/constructor skeleton the Lean module derives is the one the runtime declares. -/
-- @tg: verifies:: [[openspec:offline-codegen#Lean inductives from the schema#Derived ELPI types match the runtime kinds]] {level: unit}
theorem LeanPrinter.derive_eq_elpi (i : Inductive) (h : i.lowerNames) : i.derived = i.runtime := by
  obtain ⟨hk, hc⟩ := h
  unfold Inductive.derived Inductive.runtime
  rw [hk]
  apply List.map_congr_left
  intro ⟨c, args⟩ hmem
  simp only [Prod.mk.injEq, true_and, and_true]
  apply List.map_congr_left
  intro a ha
  cases a with
  | val t => exact etyDerive_lty t (fun k hk' => hc _ hmem _ ha k (by simpa [atyKinds] using hk'))
  | kind k => simp only [atyLty, LTy.derive, atyPty, hc _ hmem _ ha k (by simp [atyKinds])]

/-- Lean declares `k.rec`, `k.below` and `k.ibelow` for every inductive `k`, so a constructor
cannot have those names. Every other auxiliary name has an upper-case letter, which generated
names never have. -/
def leanAuxNames : List String := ["rec", "below", "ibelow"]

def inductiveText (i : Inductive) : String :=
  let ctors := i.ctors.map fun (c, args) =>
    s!"  | {quoteName c} : " ++ String.join (args.map fun a => (atyLty a).render ++ " → ") ++ quoteName i.kind
  "\n".intercalate ([s!"inductive {quoteName i.kind} where"] ++ ctors ++ ["  deriving Elpi"])

structure Options where
  /-- The namespace of the inductives; the program is `<ns>.signature`. -/
  ns : String := "Schema"
  /-- Where the dump came from, for the header comment. -/
  source : String := "<dump>"
  deriving Inhabited

/-- The Lean module of a signature. -/
-- @tg: implements:: [[openspec:offline-codegen#Lean inductives from the schema]]
def LeanPrinter.module (o : Options) (sig : Signature) (hash : String) : Except String String := do
  let kinds ← declOrder (skeleton sig.allDecls)
  for i in kinds do
    if i.ctors.isEmpty then
      throw s!"kind {i.kind} has no constructors, which `deriving Elpi` cannot express (the schema encodes no tables)"
    for (c, _) in i.ctors do
      if leanAuxNames.contains c then
        throw s!"constructor {c} of kind {i.kind} clashes with the Lean auxiliary {i.kind}.{c}; rename the table"
  let prog := s!"{o.ns}.signature"
  return "\n".intercalate [
    "import Elpi",
    "",
    "/-!",
    s!"# Schema types of {o.source}",
    "",
    s!"Generated by `lake exe marien-codegen` from a schema dump with hash {hash}; do not edit.",
    s!"One inductive per ELPI kind of the signature, `deriving Elpi`. The program `{prog}`",
    "holds the runtime signature, so rules stored in the database load against it unchanged.",
    "-/",
    "",
    s!"namespace {o.ns}",
    "",
    "\n\n".intercalate (kinds.map inductiveText),
    "",
    s!"end {o.ns}",
    "",
    s!"elpi_program {prog}",
    s!"elpi_accumulate {prog} lp%\{",
    sig.text ++ "}%",
    ""]

/-- The `LeanPrinter` as a `SignaturePrinter`: the module with the default options, or the
error text when the signature cannot be printed. -/
def LeanPrinter : SignaturePrinter :=
  ⟨"lean", fun sig => match LeanPrinter.module {} sig "" with
    | .ok t => t
    | .error e => s!"-- {e}\n"⟩

/-! ### Elaboration and the agreement check -/

/-- The environment of the last imports, so a process imports LeanElpi once: importing resets
the flag `enableInitializersExecution` sets, and the import is the slow part. -/
initialize headerCache : IO.Ref (Option (String × Environment)) ← IO.mkRef none

/-- Elaborate a module's text in an environment built from its imports; the environment, or
the error messages. The search path must reach LeanElpi's `.olean` files (`lake exe` and
`lake env` set it), and the caller must have run `enableInitializersExecution` before the first
call. -/
def elaborate (text : String) (fileName := "<generated>") : IO (Except String Environment) := do
  let inputCtx := Parser.mkInputContext text fileName
  let (header, parserState, messages) ← Parser.parseHeader inputCtx
  let key := toString ((HeaderSyntax.imports header).map (·.module))
  let env ← match ← headerCache.get with
    | some (k, env) => if k == key then pure (some env) else pure none
    | none => pure none
  let env ← match env with
    | some env => pure env
    | none =>
      let (env, messages) ← processHeader header {} messages inputCtx (trustLevel := 1024)
      if messages.hasErrors then
        return .error (String.join (← messages.toList.mapM (·.toString)))
      headerCache.set (some (key, env))
      pure env
  let s ← IO.processCommands inputCtx parserState (Command.mkState env messages {})
  let msgs := s.commandState.messages
  if msgs.hasErrors then
    let errs := msgs.toList.filter (·.severity == .error)
    return .error ("\n".intercalate (← errs.mapM (·.toString)))
  return .ok s.commandState.env

partial def PTy.ofSTy : Elpi.STy → PTy
  | .con n xs _ => .con n (xs.map PTy.ofSTy)
  | .var n _ => .var n
  | .arrow a b _ => .arrow (PTy.ofSTy a) (PTy.ofSTy b)

partial def PTy.render : PTy → String
  | .con n [] | .var n => n
  | .con n xs => "(" ++ " ".intercalate (n :: xs.map PTy.render) ++ ")"
  | .arrow a b => (match a with | .arrow .. => "(" ++ a.render ++ ")" | _ => a.render) ++ " -> " ++ b.render

/-- Kinds and constructor types of an ELPI text: `kind` and `type` declarations, everything
else dropped. -/
def kindsAndTypes (label src : String) : Except String (List String × List (String × PTy)) := do
  let ds ← (Elpi.Parser.parseProgram label src).mapError (s!"{label}: " ++ ·.toString)
  let mut kinds : List String := []
  let mut types : List (String × PTy) := []
  for d in ds do
    match d with
    | .kind ns _ _ => kinds := kinds ++ ns
    | .type ns ty _ => types := types ++ ns.map (·, PTy.ofSTy ty)
    | _ => pure ()
  return (kinds.eraseDups, types)

/-- The ELPI declarations `deriving Elpi` registered for the inductives under `ns`. -/
def derivedText (env : Environment) (ns : String) : String :=
  let pre := ns.toName
  "\n".intercalate <| (Elpi.derivedEntries env).toList.flatMap fun e =>
    if pre.isPrefixOf e.leanName then e.decls else []

/-- The first difference between the runtime kinds and constructors and the derived ones, kind
for kind and constructor for constructor with the same argument types; `none` when they agree. -/
-- @tg: implements:: [[openspec:offline-codegen#Offline and runtime signatures agree]]
def checkAgreement (runtime derived : String) : Except String (Option String) := do
  let (rk, rt) ← kindsAndTypes "<runtime signature>" runtime
  let (dk, dt) ← kindsAndTypes "<derived signature>" derived
  if let some k := rk.find? (!dk.contains ·) then
    return some s!"kind {k} is in the runtime signature but not derived by the Lean module"
  if let some k := dk.find? (!rk.contains ·) then
    return some s!"kind {k} is derived by the Lean module but not in the runtime signature"
  for (c, ty) in rt do
    match dt.find? (·.1 == c) with
    | none => return some s!"constructor {c} of kind {resultKind ty} is in the runtime signature but not derived by the Lean module"
    | some (_, ty') =>
      unless ty == ty' do
        return some s!"kind {resultKind ty}, constructor {c}: the runtime type is {ty.render}, the Lean module derives {ty'.render}"
  if let some (c, ty) := dt.find? fun (c, _) => !rt.any (·.1 == c) then
    return some s!"constructor {c} of kind {resultKind ty} is derived by the Lean module but not in the runtime signature"
  return none
where
  go : PTy → String
    | .arrow _ b => go b
    | t => t.render
  resultKind (t : PTy) : String := go t

/-! ### The tool -/

/-- What the tool produced. -/
structure Output where
  module : String
  /-- The derived ELPI declarations of the elaborated module. -/
  derived : String
  runtime : String

/-- The module for a dump, elaborated and checked against the runtime signature. -/
def run (o : Options) (dump : String) (printer : Options → Signature → String → Except String String := LeanPrinter.module) :
    IO (Except String Output) := do
  let schema ← match Dump.parse dump with
    | .ok s => pure s
    | .error e => return .error s!"{o.source}: {e}"
  let sig ← match Signature.ofSchema (Engine.reservedNames.contains ·) schema with
    | .ok s => pure s
    | .error e => return .error (toString e)
  let module ← match printer o sig (Schema.hash schema) with
    | .ok m => pure m
    | .error e => return .error e
  let env ← match ← elaborate module with
    | .ok env => pure env
    | .error e => return .error s!"the generated module does not build:\n{e}"
  let derived := derivedText env o.ns
  let runtime := ElpiPrinter.print sig
  match checkAgreement runtime derived with
  | .error e => return .error e
  | .ok (some d) => return .error s!"the Lean module and the runtime signature disagree: {d}"
  | .ok none => return .ok { module, derived, runtime }

end Marien.Offline
