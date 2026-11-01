import Marien.Engine
import Marien.Schema

/-!
# Reachability

Which predicates an entry point can call, worked out on the clause AST of the module after
`accumulate` is resolved (the AST of a unit includes the clauses of the modules it accumulates).
A clause of `p` makes `p` call every predicate its body calls: directly, inside `not`, `pi`,
`sigma` and disjunctions, in the bodies of the hypothetical clauses of `=>`, and every predicate
named as an argument (`std.forall L (x\ person.name x _)` calls `person.name`). A call through a
variable predicate (`R X Y`) calls every predicate whose type matches the variable's type, when
the clause head gives it one, and every predicate taking at least that many arguments otherwise.

The reached set is the closure of the entry point under this call relation; `reach_closed`
proves it is closed, so it over-approximates every call the entry point can make. The generated
database predicates in it, and their tables, are what a run of the entry point has to load.
-/

-- @lat: [[components#Rule analyzer]]

namespace Marien.Analysis

open Elpi.Host (TyTerm PredSig)
open Elpi.Host.Ast (Goal Hyp Term Clause)

/-! ### Closure over a finite call graph -/

/-- A call graph: each predicate with the predicates its clauses call. -/
abbrev Graph := List (String × List String)

/-- The predicates `x` calls; none when `x` has no entry. -/
def succ (g : Graph) (x : String) : List String := ((g.find? (·.1 == x)).map (·.2)).getD []

/-- Every name the graph and the start mention. -/
def allNames (g : Graph) (start : List String) : List String :=
  start ++ g.map (·.1) ++ g.flatMap (·.2)

/-- One round: add every successor. -/
def step (g : Graph) (s : List String) : List String := (s ++ s.flatMap (succ g)).eraseDups

/-- Rounds until nothing new is added; when the rounds run out the whole allNames is the answer,
which is closed as well. -/
def iter (g : Graph) (start : List String) : Nat → List String → List String
  | 0, _ => allNames g start
  | n + 1, s =>
    let s' := step g s
    if s'.all (s.contains ·) then s else iter g start n s'

/-- The predicates reachable from `start`, `start` included. A round that adds nothing ends the
iteration, and every other round adds a name of the allNames, so the bound is never reached. -/
def closure (g : Graph) (start : List String) : List String :=
  iter g start ((allNames g start).length + 1) start.eraseDups

theorem succ_mem_names {g : Graph} {start : List String} {x y : String} (h : y ∈ succ g x) :
    y ∈ allNames g start := by
  unfold succ at h
  cases hf : g.find? (·.1 == x) with
  | none => simp [hf] at h
  | some e =>
    simp only [hf, Option.map_some, Option.getD_some] at h
    have he := List.mem_of_find?_eq_some hf
    simp only [allNames, List.mem_append, List.mem_flatMap]
    exact Or.inr ⟨e, he, h⟩

theorem iter_closed (g : Graph) (start : List String) :
    ∀ (n : Nat) (s : List String) (x y : String), x ∈ iter g start n s → y ∈ succ g x →
      y ∈ iter g start n s := by
  intro n
  induction n with
  | zero => intro s x y _ hy; exact succ_mem_names hy
  | succ n ih =>
    intro s x y hx hy
    simp only [iter] at hx ⊢
    by_cases hall : (step g s).all (s.contains ·) = true
    · simp only [hall, ↓reduceIte] at hx ⊢
      have hs : y ∈ step g s := by
        simp only [step, List.mem_eraseDups, List.mem_append, List.mem_flatMap]
        exact Or.inr ⟨x, hx, hy⟩
      have := (List.all_eq_true.mp hall) y hs
      simpa using this
    · simp only [hall, Bool.false_eq_true, ↓reduceIte] at hx ⊢
      exact ih _ x y hx hy

theorem iter_start (g : Graph) (start : List String) :
    ∀ (n : Nat) (s : List String), (∀ x ∈ start, x ∈ s) → ∀ x ∈ start, x ∈ iter g start n s := by
  intro n
  induction n with
  | zero => intro s _ x hx; simp [iter, allNames, hx]
  | succ n ih =>
    intro s hs x hx
    simp only [iter]
    by_cases hall : (step g s).all (s.contains ·) = true
    · simp only [hall, ↓reduceIte]; exact hs x hx
    · simp only [hall, Bool.false_eq_true, ↓reduceIte]
      apply ih _ _ x hx
      intro z hz
      simp only [step, List.mem_eraseDups, List.mem_append]
      exact Or.inl (hs z hz)

/-- The reached set is closed under the call relation: whatever a reached predicate calls is
reached too. -/
theorem reach_closed (g : Graph) (start : List String) :
    ∀ x ∈ closure g start, ∀ y ∈ succ g x, y ∈ closure g start :=
  fun x hx y hy => iter_closed g start _ _ x y hx hy

/-- The start is reached. -/
theorem start_reached (g : Graph) (start : List String) : ∀ x ∈ start, x ∈ closure g start :=
  iter_start g start _ _ (fun x hx => by simpa using hx)

/-! ### Types -/

/-- Whether two types can stand for the same predicate type: a type variable matches anything.
This over-approximates unification (a variable may match two different types at once). -/
partial def tyMatch : TyTerm → TyTerm → Bool
  | .var _, _ | _, .var _ => true
  | .const a, .const b => a == b
  | .app h as, .app h' bs => h == h' && as.length == bs.length && (as.zip bs).all fun (a, b) => tyMatch a b
  | .arrow a b, .arrow c d => tyMatch a c && tyMatch b d
  | _, _ => false

/-- `a₁ -> … -> aₙ -> prop`. -/
def predType (args : List TyTerm) : TyTerm := args.foldr .arrow (.const "prop")

/-- The arguments of a predicate type, when it ends in `prop`. -/
def predArgs? : TyTerm → Option (List TyTerm)
  | .const "prop" => some []
  | .arrow a b => (predArgs? b).map (a :: ·)
  | _ => none

/-! ### What the analyses know about a program -/

/-- A program as the analyses see it. -/
structure Ctx where
  /-- The clauses of the module and of the modules it accumulates, in order. -/
  clauses : Array Clause
  /-- Generated database predicates, with their table. -/
  generated : List (String × String)
  /-- The type of every predicate, as `a₁ -> … -> prop`. -/
  types : List (String × TyTerm)
  /-- Predicates declared with `pred`, with their modes. -/
  sigs : List PredSig
  deriving Inhabited

namespace Ctx

def isGenerated (c : Ctx) (p : String) : Bool := c.generated.any (·.1 == p)

def tableOf? (c : Ctx) (p : String) : Option String := (c.generated.find? (·.1 == p)).map (·.2)

def hasClauses (c : Ctx) (p : String) : Bool := c.clauses.any (·.pred == p)

/-- A name that is a predicate: typed as one, or defined by clauses. -/
def isPred (c : Ctx) (n : String) : Bool := c.types.any (·.1 == n) || c.hasClauses n

def clausesOf (c : Ctx) (p : String) : List Clause := (c.clauses.filter (·.pred == p)).toList

/-- Build the view from the AST of the module's units (signature included) and the generated
predicates. -/
def ofAst (prog : Elpi.Host.Ast.Program) (generated : List (String × String)) : Ctx :=
  let fromSigs := prog.preds.toList.map fun p => (p.name, predType (p.args.toList.map (·.ty)))
  let fromTypes := prog.types.toList.filter fun (_, t) => (predArgs? t).isSome
  { clauses := prog.clauses, generated, types := fromSigs ++ fromTypes, sigs := prog.preds.toList }

end Ctx

/-! ### The call relation -/

/-- Constants of a term. -/
partial def termConsts : Term → List String
  | .const n => [n]
  | .app h args => termConsts h ++ args.flatMap termConsts
  | .lam _ b => termConsts b
  | _ => []

/-- Predicates named in a term (a predicate passed as an argument may be called). -/
def termPreds (c : Ctx) (t : Term) : List String := (termConsts t).filter c.isPred

/-- The types the head of a clause gives its variables, from the predicate's declaration. -/
def headVarTypes (c : Ctx) (cl : Clause) : List (String × TyTerm) :=
  let args := match cl.head with
    | .app _ as => as
    | _ => []
  let tys : List TyTerm :=
    match c.sigs.find? (·.name == cl.pred) with
    | some s => s.args.toList.map (·.ty)
    | none => ((c.types.find? (·.1 == cl.pred)).bind (predArgs? ·.2)).getD []
  (args.zip tys).filterMap fun (a, t) => match a with
    | .var v => if v == "_" then none else some (v, t)
    | _ => none

/-- The predicates a call through variable `v` with `n` arguments may call. -/
def varCallees (c : Ctx) (vars : List (String × TyTerm)) (v : String) (n : Nat) : List String :=
  match vars.find? (·.1 == v) with
  | some (_, t) => (c.types.filter fun (_, pt) => tyMatch t pt).map (·.1)
  | none => (c.types.filter fun (_, pt) => ((predArgs? pt).map (fun as => decide (as.length ≥ n))).getD false).map (·.1)

mutual
/-- The predicates a goal calls, not transitively. -/
partial def goalCallees (c : Ctx) (vars : List (String × TyTerm)) : Goal → List String
  | .conj gs => gs.flatMap (goalCallees c vars)
  | .disj a b => goalCallees c vars a ++ goalCallees c vars b
  | .not g | .pi _ g | .sigma _ g => goalCallees c vars g
  | .impl hs b => hs.flatMap (hypCallees c vars) ++ goalCallees c vars b
  | .call p args => p :: args.flatMap (termPreds c)
  | .builtin _ args => args.flatMap (termPreds c)
  | .other t => match t with
    | .var v => varCallees c vars v 0
    | .app (.var v) args => varCallees c vars v args.length ++ args.flatMap (termPreds c)
    | t => termPreds c t
  | _ => []

partial def hypCallees (c : Ctx) (vars : List (String × TyTerm)) : Hyp → List String
  | .mk _ b => goalCallees c vars b
end

/-- The call graph of the program: every predicate with clauses, and what its clauses call. -/
def callGraph (c : Ctx) : Graph :=
  let preds := (c.clauses.toList.map (·.pred)).eraseDups
  preds.map fun p =>
    (p, ((c.clausesOf p).flatMap fun cl => goalCallees c (headVarTypes c cl) cl.body).eraseDups)

/-- What an entry point reaches. -/
structure Reached where
  /-- Every predicate it can call, itself included. -/
  preds : List String
  /-- The generated database predicates among them, sorted. -/
  generated : List String
  /-- Their tables, sorted. -/
  tables : List String
  deriving Repr, Inhabited, BEq

/-- What the given predicates reach, through the call graph `g` of `c`. -/
def reachFrom (c : Ctx) (g : Graph) (start : List String) : Reached :=
  let preds := closure g start
  let gen := preds.filter c.isGenerated
  { preds, generated := Schema.sortStrings gen.eraseDups
    tables := Schema.sortStrings (gen.filterMap c.tableOf?).eraseDups }

/-- Entry-point reachability. -/
-- @tg: implements:: [[openspec:rule-analysis#Entry-point reachability]]
def reach (c : Ctx) (g : Graph) (entry : String) : Reached := reachFrom c g [entry]

end Marien.Analysis
