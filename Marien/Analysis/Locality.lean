import Marien.Analysis.Monotone
import Marien.Encoding.Signature

/-!
# Locality

A declared partition lets a run look at part of the database at a time. The check here decides
whether that can change the answer.

**Anchor partitions** (`% @marien partition violation by person radius 1`). The clause's
subject must be `subj_<kind> A`: the variable `A` is the anchor, and a batch keeps only rows whose
subject is one of its anchors. Every database atom the clause reaches must be *guarded*: a node
atom (`person P`, `person.name P N`, `in_cycle.r P`) on a node at most `radius` edges from the
anchor, an edge atom with an endpoint fewer than `radius` edges away, an edge property atom on
such an edge. Distances follow edge atoms in both directions; each edge atom records the direction from its
nearer endpoint, and the scanner loads the neighbourhood those directions reach.
Helper predicates are inlined (head arguments unify with call arguments). A head variable bound
to a predicate term (`edge_of has_manager` passed for `R`) stands for that term in the inlined
body, so a call `R X Y` is a call of `edge_of has_manager X Y`: this is how the higher-order
combinators of `graph.std` are analysed by their definitions. The template of a `findall` is
checked as a goal whose bindings stay inside. A recursive helper, a call through a variable
predicate bound to no predicate term, any other library call with database predicates as
arguments, a cut or an implication that reaches database facts is not analysed and rejects the
partition; the error names the chain of calls that led to it.

Negation is checked with the bindings it actually sees: inside `not G` only variables bound by
goals before it count as linked, and bindings made inside `G` never leave it.

**Key partitions** (`% @marien partition violation by person.email`). Every database atom must
be the key property `person.email X V` with one value variable `V` shared by the clause, or a
node atom of the key table on a node bound by such an atom outside negation; then all rows a
solution uses share one key value and land in one bucket.
-/

-- @lat: [[components#Rule analyzer]]

namespace Marien.Analysis

open Elpi.Host (TyTerm)
open Elpi.Host.Ast (Goal Hyp Term Clause)
open Marien.Encoding

/-! ### Annotations -/

/-- A `% @marien …` line of a module's source. -/
inductive Annotation where
  | anchor (pred kind : String) (radius : Nat) (line : Nat)
  | key (pred prop : String) (line : Nat)
  | dynamic (pred : String) (line : Nat)
  | static (pred : String) (line : Nat)
  deriving Repr, Inhabited, BEq

def Annotation.pred : Annotation → String
  | .anchor p .. | .key p .. | .dynamic p _ | .static p _ => p

/-- The annotations of a source, by line. A `% @marien` line that is none of them is an error. -/
def annotations (src : String) : Except String (List Annotation) := do
  let mut out : List Annotation := []
  let lines := src.splitOn "\n"
  for h : i in [0:lines.length] do
    let line := lines[i].trimAscii.toString
    let some rest := (line.dropPrefix? "%").map (·.toString.trimAscii.toString) | continue
    let some body := (rest.dropPrefix? "@marien").map (·.toString) | continue
    let ws := (body.splitOn " ").filter (· ≠ "")
    let n := i + 1
    match ws with
    | ["partition", p, "by", k, "radius", r] =>
      let some radius := r.toNat? | throw s!"line {n}: radius {r} is not a natural number"
      out := out ++ [.anchor p k radius n]
    | ["partition", p, "by", k] =>
      unless k.contains '.' do
        throw s!"line {n}: write partition {p} by <kind> radius <n> or partition {p} by <table>.<property>"
      out := out ++ [.key p k n]
    | ["dynamic", p] => out := out ++ [.dynamic p n]
    | ["static", p] => out := out ++ [.static p n]
    | _ => throw s!"line {n}: unknown annotation {line}; Marien knows partition, dynamic and static"
  return out

/-! ### Database atoms -/

/-- What a generated predicate's arguments are. -/
inductive Shape where
  /-- `person P`. -/
  | nodeList (table : String)
  /-- `person.name P V`. -/
  | nodeProp (table : String)
  /-- `reports_to P E M`. -/
  | rel (table : String)
  /-- `reports_to.since E V`. -/
  | relProp (table : String)
  /-- `in_cycle.reports_to P`, `component.reports_to P C`: about one node. -/
  | structural (table : String)
  deriving Repr, Inhabited, BEq

/-- The shape of every generated predicate of a signature. -/
def shapes (sig : Signature) : List (String × Shape) :=
  sig.plan.nodes.flatMap (fun n => (n.id, .nodeList n.name) :: n.props.map (·.pred, .nodeProp n.name)) ++
  sig.plan.rels.flatMap fun r =>
    (r.id, .rel r.name) :: r.props.map (·.pred, .relProp r.name) ++
    (match r.selfKind? with
     | some k => [((Origin.structural r.name true).ident, .structural k),
                  ((Origin.structural r.name false).ident, .structural k)]
     | none => [])

/-! ### Clauses with helpers inlined -/

/-- A goal with helper predicates inlined, as the locality checks see it. -/
inductive LG where
  /-- A database atom, with the position of its clause. -/
  | atom (pred : String) (args : List Term) (pos : String)
  | eq (a b : Term)
  | conj (gs : List LG)
  | disj (gs : List LG)
  /-- `not`, `pi`, `sigma`: bindings made inside stay inside. -/
  | scoped (g : LG)
  /-- Something the check cannot analyse that reaches database facts. -/
  | opaque (why : String) (pos : String)
  /-- No database facts. -/
  | skip
  deriving Repr, Inhabited

/-- A fresh number. -/
def fresh : StateM Nat Nat := modifyGet fun n => (n, n + 1)

/-- Variables renamed apart for one clause instance; each `_` becomes its own variable. -/
partial def renameTerm (k : String) : Term → StateM Nat Term
  | .var "_" => do return .var s!"_#{← fresh}"
  | .var v => return .var s!"{v}#{k}"
  | .app h as => do return .app (← renameTerm k h) (← as.mapM (renameTerm k))
  | .lam x b => do return .lam x (← renameTerm k b)
  | t => return t

/-- The head arguments of a clause. -/
def headArgs (cl : Clause) : List Term :=
  match cl.head with
  | .app _ as => as
  | _ => []

/-- A term with a head variable bound in `sub` replaced by its predicate term. -/
def resolve (sub : List (String × Term)) : Term → Term
  | t@(.var v) => ((sub.find? (·.1 == v)).map (·.2)).getD t
  | t@(.app (.var v) as) => match ((sub.find? (·.1 == v)).map (·.2) : Option Term) with
    | some (.const p) => .app (.const p) as
    | some (.app h bs) => .app h (bs ++ as)
    | _ => t
  | t => t

/-- The predicate and arguments of a term used as a goal. -/
def callOf? : Term → Option (String × List Term)
  | .const p => some (p, [])
  | .app (.const p) as => some (p, as)
  | _ => none

/-- Whether a term names a predicate the analysis can inline or load: a generated database
predicate or one with clauses, possibly partially applied. -/
def isPredTerm (c : Ctx) (t : Term) : Bool :=
  match callOf? t with
  | some (p, _) => c.isGenerated p || c.hasClauses p
  | none => false

/-- The calls that led to `p`, for messages. -/
def chain (stack : List String) (p : String) : String := " → ".intercalate (stack.reverse ++ [p])

mutual
/-- Inline a goal of a clause of `owner`, whose variables are renamed with `k`; `sub` maps the
renamed head variables bound to predicate terms. -/
partial def expand (c : Ctx) (g : Graph) (stack : List String) (owner : Clause) (k : String)
    (sub : List (String × Term)) : Goal → StateM Nat LG
  | .true | .fail => return .skip
  | .cut => return match (reachFrom c g [owner.pred]).generated.head? with
    | some p => .opaque s!"a cut in {owner.pred}, which reaches {p}" (clausePos owner)
    | none => .skip
  | .conj gs => return .conj (← gs.mapM (expand c g stack owner k sub))
  | .disj a b => return .disj [← expand c g stack owner k sub a, ← expand c g stack owner k sub b]
  | .not x | .pi _ x | .sigma _ x => return .scoped (← expand c g stack owner k sub x)
  | .impl hs b => do
    let hypDb := hs.findSome? fun h =>
      (h.pred?.filter c.isGenerated).orElse fun _ => goalReachesDb c g [] h.body
    match hypDb with
    | some p => return .opaque s!"an implication whose clauses reach {p}" (clausePos owner)
    | none => expand c g stack owner k sub b
  | .call p args => do expandCall c g stack owner sub p (← args.mapM (renameTerm k))
  | .builtin p args =>
    return match argsReachDb c g args with
      | some d => .opaque s!"{p} is called with arguments that reach {d}" (clausePos owner)
      | none => .skip
  | .other t => do
    match callOf? (resolve sub (← renameTerm k t)) with
    | some (p, args) => expandCall c g stack owner sub p args
    | none =>
      return match goalReachesDb c g (headVarTypes c owner) (.other t) with
        | some d => .opaque s!"a call through a variable predicate may reach {d}" (clausePos owner)
        | none => .skip

/-- Inline a call of `p` with arguments already renamed. -/
partial def expandCall (c : Ctx) (g : Graph) (stack : List String) (owner : Clause)
    (sub : List (String × Term)) (p : String) (args : List Term) : StateM Nat LG := do
  let args := args.map (resolve sub)
  -- an atom inside an inlined helper says which calls led to it
  let pos := if stack.length > 1 then s!"{clausePos owner} ({" → ".intercalate stack.reverse})" else clausePos owner
  if c.isGenerated p then return .atom p args pos
  if p == "=" then
    return match args with
      | [a, b] => .eq a b
      | _ => .skip
  if isQuantifier p == some "findall" then
    if let some (q, as) := args.head?.bind callOf? then
      return .scoped (← expandCall c g stack owner sub q as)
  if c.hasClauses p then
    let some d := (reachFrom c g [p]).generated.head? | return .skip
    if stack.contains p then
      return .opaque s!"the recursive predicate {p} ({chain stack p}) reaches {d}, so its distance from the anchor has no bound" (clausePos owner)
    let alts ← (c.clausesOf p).mapM fun cl => do
      let k' := s!"c{← fresh}"
      let hs ← (headArgs cl).mapM (renameTerm k')
      let sub' := sub ++ (hs.zip args).filterMap fun (h, a) => match h with
        | .var v => if isPredTerm c a then some (v, a) else none
        | _ => none
      let body ← expand c g (p :: stack) cl k' sub' cl.body
      return LG.conj ((hs.zip args).map (fun (h, a) => LG.eq h a) ++ [body])
    return match alts with
      | [a] => a
      | as => .disj as
  match argsReachDb c g args with
  | some d => return .opaque s!"{p} ({chain stack p}) is called with arguments that reach {d}" (clausePos owner)
  | none => return .skip
end

/-! ### Distances from the anchor -/

/-- Linked variables: node variables with their distance from the anchor, and edge variables of
guarded edges. -/
structure Env where
  nodes : List (String × Nat) := []
  edges : List String := []
  deriving Repr, Inhabited, BEq

namespace Env

def dist? (e : Env) (v : String) : Option Nat := (e.nodes.find? (·.1 == v)).map (·.2)

def setDist (e : Env) (v : String) (d : Nat) : Env :=
  match e.dist? v with
  | some d' => if d' ≤ d then e else { e with nodes := (v, d) :: e.nodes.filter (·.1 != v) }
  | none => { e with nodes := (v, d) :: e.nodes }

def addEdge (e : Env) (v : String) : Env :=
  if e.edges.contains v then e else { e with edges := v :: e.edges }

/-- The variables both environments link, at the larger distance. -/
def meet (a b : Env) : Env :=
  { nodes := a.nodes.filterMap fun (v, d) => (b.dist? v).map fun d' => (v, max d d')
    edges := a.edges.filter b.edges.contains }

def restrict (e : Env) (bound : List String) : Env :=
  { nodes := e.nodes.filter (bound.contains ·.1), edges := e.edges.filter bound.contains }

def size (e : Env) : Nat := e.nodes.foldl (fun n (_, d) => n + d + 1) 0 + e.edges.length

end Env

/-- The variable a term stands for: itself, or the one argument of a constructor (an endpoint of
a multi-pair rel table, a subject). -/
def linkVar? : Term → Option String
  | .var v => some v
  | .app (.const _) [.var v] => some v
  | _ => none

/-- Variables of a term. -/
partial def termVars : Term → List String
  | .var v => [v]
  | .app h as => termVars h ++ as.flatMap termVars
  | .lam _ b => termVars b
  | _ => []

/-- Unify two terms structurally for linking: variable with variable, constructor argument with
constructor argument. -/
partial def eqPairs : Term → Term → List (String × String)
  | .app (.const f) as, .app (.const g) bs =>
    if f == g && as.length == bs.length then (as.zip bs).flatMap fun (a, b) => eqPairs a b else []
  | a, b => match linkVar? a, linkVar? b with
    | some x, some y => [(x, y)]
    | _, _ => []

/-- One round of linking through the positive goals of `lg`. -/
partial def propagate (shape : String → Option Shape) (radius : Nat) (env : Env) : LG → Env
  | .atom p args _ => match shape p, args with
    | some (.rel _), [s, e, d] =>
      let sv := linkVar? s
      let dv := linkVar? d
      let ds := sv.bind env.dist?
      let dd := dv.bind env.dist?
      let env := match ds, dv with
        | some x, some y => if x < radius then (env.setDist y (x + 1)) else env
        | _, _ => env
      let env := match dd, sv with
        | some x, some y => if x < radius then (env.setDist y (x + 1)) else env
        | _, _ => env
      let guarded := (ds.map (fun x => decide (x < radius))).getD false || (dd.map (fun x => decide (x < radius))).getD false
      match guarded, linkVar? e with
      | true, some ev => env.addEdge ev
      | _, _ => env
    | _, _ => env
  | .eq a b => (eqPairs a b).foldl (init := env) fun env (x, y) =>
      let env := match env.dist? x with
        | some d => env.setDist y d
        | none => env
      let env := match env.dist? y with
        | some d => env.setDist x d
        | none => env
      if env.edges.contains x then env.addEdge y
      else if env.edges.contains y then env.addEdge x else env
  | .conj gs => gs.foldl (propagate shape radius) env
  | .disj [] => env
  | .disj (b :: bs) =>
    let fix (lg : LG) : Env := (List.range 64).foldl (fun e _ => propagate shape radius e lg) env
    bs.foldl (fun acc b' => acc.meet (fix b')) (fix b)
  | _ => env

/-- Linking until nothing changes. Stopping early only links less, which rejects more. -/
def propagateFix (shape : String → Option Shape) (radius : Nat) (env : Env) (lg : LG) : Env :=
  let rec go : Nat → Env → Env
    | 0, e => e
    | n + 1, e =>
      let e' := propagate shape radius e lg
      if e' == e then e else go n e'
  go 256 env

/-- The variables a goal surely binds when it succeeds: every argument of a database atom, the
other side of an equation whose one side is bound, what both branches of a disjunction bind. -/
partial def boundBy (bound : List String) : LG → List String
  | .atom _ args _ => args.flatMap termVars
  | .eq a b =>
    let va := termVars a
    let vb := termVars b
    if va.all bound.contains then vb else if vb.all bound.contains then va else []
  | .conj gs => gs.foldl (fun acc g => acc ++ boundBy (bound ++ acc) g) []
  | .disj [] => []
  | .disj (b :: bs) => bs.foldl (fun acc b' => acc.filter (boundBy bound b').contains) (boundBy bound b)
  | _ => []

/-- The goals of a conjunction with inlined conjunctions spliced in: `(A, (B, C))` is `A, B, C`. -/
partial def flatConj (gs : List LG) : List LG :=
  gs.flatMap fun | .conj hs => flatConj hs | g => [g]

/-- `bound` closed under equations already unified: once one side of `a = b` is bound, so is
the other, whichever was bound first. -/
def closeEqs (eqs : List (Term × Term)) (bound : List String) : List String :=
  let step (b : List String) : List String := eqs.foldl (init := b) fun b (x, y) =>
    let vx := termVars x
    let vy := termVars y
    if vx.all b.contains then b ++ vy.filter (!b.contains ·)
    else if vy.all b.contains then b ++ vx.filter (!b.contains ·) else b
  (List.range (eqs.length + 1)).foldl (fun b _ => step b) bound

/-- Why an anchor partition is rejected. -/
structure Rejection where
  msg : String
  deriving Repr, Inhabited

/-- Check the goals of `lg` against the linked variables `env`, of which `bound` are bound when
`lg` starts; the directions each edge atom is guarded through. -/
partial def guard (shape : String → Option Shape) (radius : Nat) (bound : List String) (env : Env) :
    LG → Except String (List (String × String))
  | .atom p args pos =>
    let near (t : Term) : Bool := ((linkVar? t).bind env.dist? |>.map (fun x => decide (x ≤ radius))).getD false
    let unguarded := s!"{p} at {pos} is not within radius {radius} of the anchor"
    match shape p, args with
    | some (.nodeList _), x :: _ | some (.nodeProp _), x :: _ | some (.structural _), x :: _ =>
      if near x then .ok [] else .error unguarded
    | some (.rel t), [s, _, d] =>
      -- the scan follows the edge from its nearer endpoint (the source on a tie); the endpoint
      -- that got its distance from this atom is never the nearer one, so every distance is one
      -- the neighbourhood scan reaches
      match (linkVar? s).bind env.dist?, (linkVar? d).bind env.dist? with
      | some ds, dd =>
        if ds < radius && (dd.map (fun x => decide (ds ≤ x))).getD true then .ok [(t, "outgoing")]
        else match dd with
          | some dd => if dd < radius then .ok [(t, "incoming")] else .error unguarded
          | none => .error unguarded
      | none, some dd => if dd < radius then .ok [(t, "incoming")] else .error unguarded
      | none, none => .error unguarded
    | some (.relProp _), e :: _ =>
      if ((linkVar? e).map env.edges.contains).getD false then .ok [] else .error unguarded
    | _, _ => .error unguarded
  | .eq _ _ | .skip => .ok []
  | .opaque why pos => .error s!"{why} (clause at {pos})"
  | .scoped x =>
    let inner := propagateFix shape radius (env.restrict bound) x
    guard shape radius bound inner x
  | .disj bs => do
    let r := env.restrict bound
    let mut out := []
    for b in bs do out := out ++ (← guard shape radius bound (propagateFix shape radius r b) b)
    return out
  | .conj gs => do
    let gs := flatConj gs
    let final := propagateFix shape radius env (.conj gs)
    let mut bnd := bound
    let mut eqs : List (Term × Term) := []
    let mut out := []
    for x in gs do
      match x with
      | .atom .. | .eq .. => out := out ++ (← guard shape radius bnd final x)
      | _ => out := out ++ (← guard shape radius bnd (final.restrict bnd) x)
      if let .eq a b := x then eqs := eqs ++ [(a, b)]
      bnd := closeEqs eqs (bnd ++ boundBy bnd x)
    return out

/-- An entry clause, renamed and with helpers inlined. -/
def expandClause (c : Ctx) (g : Graph) (cl : Clause) (k : String) : StateM Nat (List Term × LG) := do
  let hs ← (headArgs cl).mapM (renameTerm k)
  let body ← expand c g [cl.pred] cl k [] cl.body
  return (hs, body)

/-- The anchor partition of `entry` by node table `table` (kind `kindId`) within `radius`: the
recorded directions per rel table, or why it is rejected. `subjectArg` is the position of the
entry point's `subject` argument. -/
-- @tg: implements:: [[openspec:rule-analysis#Locality check]]
def anchorCheck (c : Ctx) (g : Graph) (shp : List (String × Shape)) (entry : String) (subjectArg : Nat)
    (table kindId : String) (radius : Nat) : Except String (List (String × String)) := do
  let shape (p : String) : Option Shape := (shp.find? (·.1 == p)).map (·.2)
  let subjCtor := (Origin.subject table).ident
  let mut dirs : List (String × String) := []
  let mut n := 0
  for cl in c.clausesOf entry do
    let ((hs, body), n') := (expandClause c g cl s!"e{n}").run n
    n := n'
    let anchor ← match hs[subjectArg]? with
      | some (.app (.const f) [.var a]) =>
        if f == subjCtor then pure a
        else throw s!"the subject must be the anchor: the clause at {clausePos cl} reports {f} …, not {subjCtor} of a {kindId}"
      | some t => throw s!"the subject must be the anchor: the clause at {clausePos cl} reports {renderTerm t}, not {subjCtor} A with A a variable"
      | none => throw s!"the clause at {clausePos cl} has no subject argument"
    let env : Env := { nodes := [(anchor, 0)] }
    dirs := dirs ++ (← guard shape radius [] env body)
  return dirs.eraseDups

/-! ### Key partitions -/

/-- Atoms of an inlined goal, each with whether it is outside negation and disjunction. -/
partial def atomsOf (top : Bool) : LG → List (String × List Term × String × Bool)
  | .atom p args pos => [(p, args, pos, top)]
  | .conj gs => gs.flatMap (atomsOf top)
  | .disj bs => bs.flatMap (atomsOf false)
  | .scoped x => atomsOf false x
  | _ => []

partial def eqsOf : LG → List (String × String)
  | .eq a b => eqPairs a b
  | .conj gs | .disj gs => gs.flatMap eqsOf
  | .scoped x => eqsOf x
  | _ => []

partial def opaqueOf : LG → Option (String × String)
  | .opaque why pos => some (why, pos)
  | .conj gs | .disj gs => gs.findSome? opaqueOf
  | .scoped x => opaqueOf x
  | _ => none

/-- The class of a variable under equations: the smallest name it is equated with. -/
def classOf (eqs : List (String × String)) (v : String) : String :=
  let rec go : Nat → List String → List String
    | 0, s => s
    | n + 1, s =>
      let s' := (s ++ eqs.filterMap (fun (a, b) => if s.contains a then some b else if s.contains b then some a else none)).eraseDups
      if s'.length == s.length then s else go n s'
  ((Schema.sortStrings (go (eqs.length + 1) [v])).head?).getD v

/-- The key partition of `entry` by the property predicate `keyPred` of node table `table`. -/
-- @tg: implements:: [[openspec:partitioning#Key partitions]] {confidence: partial, note: "the save-time join check"}
def keyCheck (c : Ctx) (g : Graph) (shp : List (String × Shape)) (entry table keyPred : String) :
    Except String Unit := do
  let shape (p : String) : Option Shape := (shp.find? (·.1 == p)).map (·.2)
  let mut n := 0
  for cl in c.clausesOf entry do
    let ((_, body), n') := (expandClause c g cl s!"e{n}").run n
    n := n'
    if let some (why, pos) := opaqueOf body then throw s!"{why} (clause at {pos})"
    let eqs := eqsOf body
    let cls := classOf eqs
    let atoms := atomsOf true body
    let keyAtoms := atoms.filter (·.1 == keyPred)
    let positive := keyAtoms.filter (·.2.2.2)
    let values := positive.filterMap fun (_, args, _, _) => (args[1]? >>= linkVar?).map cls
    let joined := positive.filterMap fun (_, args, _, _) => (args[0]? >>= linkVar?).map cls
    for (p, args, pos, _) in atoms do
      if p == keyPred then
        match (args[1]? >>= linkVar?).map cls with
        | some v => unless values.contains v && values.all (· == v) do
            throw s!"{p} at {pos} does not share one key value with the other {keyPred} atoms"
        | none => throw s!"{p} at {pos} has a key value that is not a variable"
      else
        let onJoined := ((args[0]? >>= linkVar?).map (joined.contains ∘ cls)).getD false
        match shape p with
        | some (.nodeList t) | some (.nodeProp t) =>
          unless t == table && onJoined do
            throw s!"{p} at {pos} is not joined to {keyPred} through its key value"
        | _ => throw s!"{p} at {pos} is not joined to {keyPred} through its key value"

end Marien.Analysis
