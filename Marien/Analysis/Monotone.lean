import Marien.Analysis.Reach

/-!
# Monotonicity and `dynamic`

An entry point is monotone when adding facts to the database can only add answers, so running
it on part of the database gives a subset of its answers on the whole. The check is syntactic
and conservative: an entry point is non-monotone when a clause it reaches contains

* `not G` (or `\+ G`) where `G` reaches a generated database predicate;
* a cut `!` in a clause of a predicate that reaches one (the cut prunes depending on which facts
  come first);
* a call of `forall` or `findall` (any namespace) whose arguments reach one;

or when the entry point is `dynamic`. The verdict names the first such construct in program
order, the position of its clause and the database predicate it reaches.

An entry point is `dynamic` when a goal `C => G` it reaches adds a clause `C` whose head is a
generated database predicate: it then sees facts the database does not hold. A module may mark an
entry point dynamic with `% @marien dynamic <pred>`; nothing clears an inferred mark.
-/

-- @lat: [[components#Rule analyzer]]

namespace Marien.Analysis

open Elpi.Host (TyTerm)
open Elpi.Host.Ast (Goal Hyp Term Clause)

/-! ### Rendering goals for messages -/

mutual
partial def renderTerm : Term → String
  | .const n => n
  | .var v => v
  | .int i => toString i
  | .float f => toString f
  | .str s => s.quote
  | .app h args => " ".intercalate (renderArg h :: args.map renderArg)
  | .lam x b => s!"{x}\\ {renderTerm b}"

partial def renderArg : Term → String
  | t@(.app _ _) | t@(.lam _ _) => s!"({renderTerm t})"
  | t => renderTerm t
end

mutual
partial def renderGoal : Goal → String
  | .true => "true"
  | .fail => "fail"
  | .cut => "!"
  | .conj gs => ", ".intercalate (gs.map renderGoal)
  | .disj a b => s!"({renderGoal a}; {renderGoal b})"
  | .not g => s!"not ({renderGoal g})"
  | .pi x g => s!"pi {x}\\ {renderGoal g}"
  | .sigma x g => s!"sigma {x}\\ {renderGoal g}"
  | .impl hs b => s!"{", ".intercalate (hs.map renderHyp)} => {renderGoal b}"
  | .call p [] | .builtin p [] => p
  | .call p args | .builtin p args => renderTerm (.app (.const p) args)
  | .other t => renderTerm t

partial def renderHyp : Hyp → String
  | .mk h .true => s!"({renderTerm h})"
  | .mk h b => s!"({renderTerm h} :- {renderGoal b})"
end

/-- A clause position as `unit:line:col`. -/
def clausePos (c : Clause) : String := s!"{c.pos.file}:{c.pos.line}:{c.pos.col}"

/-! ### Verdicts -/

/-- A construct that makes an entry point non-monotone. -/
structure Offense where
  /-- `not`, `!`, `forall`, `findall` or `=>`. -/
  construct : String
  /-- The position of the clause that contains it. -/
  pos : String
  /-- A generated database predicate it reaches. -/
  pred : String
  deriving Repr, Inhabited, BEq

def Offense.describe (o : Offense) : String := s!"{o.construct} at {o.pos} reaches {o.pred}"

/-- Whether a goal can reach a generated database predicate, and the first one it reaches. -/
def goalReachesDb (c : Ctx) (g : Graph) (vars : List (String × TyTerm)) (goal : Goal) : Option String :=
  (reachFrom c g (goalCallees c vars goal)).generated.head?

/-- The first database predicate the arguments of a call reach. -/
def argsReachDb (c : Ctx) (g : Graph) (args : List Term) : Option String :=
  (reachFrom c g (args.flatMap (termPreds c))).generated.head?

/-- `forall`/`findall` in any namespace (`std.forall`, `std.findall`, `forall2`, …). -/
def isQuantifier (p : String) : Option String :=
  let last := (p.splitOn ".").getLast?.getD p
  if last.startsWith "forall" then some "forall"
  else if last.startsWith "findall" then some "findall"
  else none

/-- The first non-monotone construct of a goal in a clause of `owner`. -/
partial def goalOffense (c : Ctx) (g : Graph) (vars : List (String × TyTerm)) (owner : Clause) :
    Goal → Option Offense
  | .not inner =>
    match goalReachesDb c g vars inner with
    | some p => some { construct := "not", pos := clausePos owner, pred := p }
    | none => goalOffense c g vars owner inner
  | .cut => ((reachFrom c g [owner.pred]).generated.head?).map fun p =>
      { construct := "!", pos := clausePos owner, pred := p }
  | .conj gs => gs.findSome? (goalOffense c g vars owner)
  | .disj a b => (goalOffense c g vars owner a).orElse fun _ => goalOffense c g vars owner b
  | .pi _ b | .sigma _ b => goalOffense c g vars owner b
  | .impl hs b =>
    (hs.findSome? fun h => goalOffense c g vars owner h.body).orElse fun _ => goalOffense c g vars owner b
  | .call p args | .builtin p args =>
    (isQuantifier p).bind fun q => (argsReachDb c g args).map fun d =>
      { construct := q, pos := clausePos owner, pred := d }
  | _ => none

/-- The goals `C => G` of a goal whose clause `C` has a database predicate head, with that
predicate. -/
partial def dynamicGoals (c : Ctx) : Goal → List (Goal × String)
  | g@(.impl hs b) =>
    (hs.filterMap fun h => (h.pred?.filter c.isGenerated).map (g, ·)) ++
      hs.flatMap (dynamicGoals c ·.body) ++ dynamicGoals c b
  | .conj gs => gs.flatMap (dynamicGoals c)
  | .disj a b => dynamicGoals c a ++ dynamicGoals c b
  | .not g | .pi _ g | .sigma _ g => dynamicGoals c g
  | _ => []

/-- The clauses an entry point reaches, in program order. -/
def reachedClauses (c : Ctx) (r : Reached) : List Clause :=
  c.clauses.toList.filter (r.preds.contains ·.pred)

/-- The first goal that makes an entry point dynamic, as text with its position. -/
def dynamicCause (c : Ctx) (r : Reached) : Option (String × Offense) :=
  (reachedClauses c r).findSome? fun cl =>
    (dynamicGoals c cl.body).head?.map fun (goal, p) =>
      (renderGoal goal, { construct := "=>", pos := clausePos cl, pred := p })

/-- The first construct that makes an entry point non-monotone, ignoring `dynamic`. -/
def firstOffense (c : Ctx) (g : Graph) (r : Reached) : Option Offense :=
  (reachedClauses c r).findSome? fun cl => goalOffense c g (headVarTypes c cl) cl cl.body

end Marien.Analysis
