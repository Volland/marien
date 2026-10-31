import Marien.Engine

/-!
# Engine contract tests

One check per scenario of the `engine-host-api` capability, run against the pinned LeanElpi
through `Marien.Engine` only. An engine upgrade that breaks the contract fails `lake test`.
-/

open Marien.Engine

namespace EngineContract

def check (b : Bool) (msg : String) : IO Unit := unless b do throw (IO.userError msg)

def fail {α : Type} (msg : String) : IO α := throw (IO.userError msg)

def load (src : String) : IO Program :=
  match compile [("test", src)] with
  | .ok p => pure p
  | .error e => fail s!"program failed to load: {e}"

def goalOf (p : Program) (pred : String) (args : Array GoalArg) (fuel : Nat := defaultFuel) :
    IO Query :=
  match goal p pred args fuel with
  | .ok q => pure q
  | .error e => fail s!"goal failed to build: {e}"

abbrev Bindings := Array (String × ResultTerm)

/-- Every solution and how the search ended, in slices of `n` steps. -/
partial def runAll (q : Query) (n : Nat) : Array Bindings × String :=
  go q #[]
where
  go (q : Query) (acc : Array Bindings) : Array Bindings × String :=
    match slice q n with
    | .solution bs _ q' => go q' (acc.push bs)
    | .paused q' => go q' acc
    | .exhausted => (acc, "exhausted")
    | .error e => (acc, s!"error: {e}")

def solutions (p : Program) (pred : String) (args : Array GoalArg) : IO (Array Bindings) := do
  let (sols, ending) := runAll (← goalOf p pred args) 1000
  check (ending == "exhausted") s!"{pred} ended with {ending}"
  return sols

def elapsedMs {α : Type} (act : IO α) : IO (α × Nat) := do
  let t0 ← IO.monoMsNow
  let a ← act
  return (a, (← IO.monoMsNow) - t0)

/-! ### Predicate signature lookup -/

-- @tg: verifies:: [[openspec:engine-host-api#Predicate signature lookup#Declared predicate]] {level: integration}
def declaredPredicate : IO Unit := do
  let p ← load "kind dept type.\nkind person type.\npred violation i:dept, o:person, o:string."
  let some s := predSig? p "violation" | fail "violation must be declared"
  check ((s.args.map (·.ty)).toList == [.const "dept", .const "person", .const "string"]) "argument types"
  check (s.args.map (·.mode) == #[.i, .o, .o]) "modes i, o, o"

-- @tg: verifies:: [[openspec:engine-host-api#Predicate signature lookup#Polymorphic predicate]] {level: integration}
def polymorphicPredicate : IO Unit := do
  let p ← load "pred closure i:(A -> A -> prop), i:A, o:A."
  let some s := predSig? p "closure" | fail "closure must be declared"
  check (s.args[0]!.ty == .arrow (.var "A") (.arrow (.var "A") (.const "prop"))) s!"first argument is {s.args[0]!.ty}"

-- @tg: verifies:: [[openspec:engine-host-api#Predicate signature lookup#Unknown predicate]] {level: integration}
def unknownPredicate : IO Unit := do
  let p ← load "kind person type."
  check (predSig? p "nothing_here").isNone "an undeclared name has no signature"

/-! ### Goals built from terms -/

-- @tg: verifies:: [[openspec:engine-host-api#Goals built from terms#Input values are not parsed as source]] {level: integration}
def notParsed : IO Unit := do
  let p ← load "kind person type.\ntype person int -> person.\npred name_of i:string, o:person.\nname_of S (person N) :- N is size S."
  let evil := "x\" , evil Y"
  let q ← goalOf p "name_of" #[.value (.str evil), .out "P"]
  check ((q.names.map (·.1)).toList == ["P"]) "the only query variable is P"
  let (sols, _) := runAll q 1000
  check (sols == #[#[("P", .app "person" #[.int evil.length])]]) "one string literal equal to the text"

-- @tg: verifies:: [[openspec:engine-host-api#Goals built from terms#Ill-typed argument]] {level: integration}
def illTypedArgument : IO Unit := do
  let p ← load "kind person type.\ntype person int -> person.\npred manages i:person, o:person."
  match goal p "manages" #[.value (.int 3), .out "Q"] with
  | .error (.argument "manages" 1 _) => pure ()
  | .error e => fail s!"expected an error naming argument 1, got {e}"
  | .ok _ => fail "an integer where a person is declared must be rejected"

/-! ### Structured solution terms -/

-- @tg: verifies:: [[openspec:engine-host-api#Structured solution terms#Constructor application]] {level: integration}
def constructorApplication : IO Unit := do
  let p ← load "kind person type.\ntype person int -> person.\npred boss o:person.\nboss (person 42)."
  check ((← solutions p "boss" #[.out "P"]) == #[#[("P", .app "person" #[.int 42])]]) "P = person 42"

-- @tg: verifies:: [[openspec:engine-host-api#Structured solution terms#Unbound output]] {level: integration}
def unboundOutput : IO Unit := do
  let p ← load "kind person type.\npred anyone o:person.\nanyone _."
  check ((← solutions p "anyone" #[.out "P"]) == #[#[("P", .unbound)]]) "P is the unbound marker"

/-- The engine proves the round trip for every term. -/
theorem jsonRoundTrip (t : ResultTerm) : fromJson? (toJson t) = some t :=
  Elpi.Host.ResultTerm.json_roundtrip t

-- @tg: verifies:: [[openspec:engine-host-api#Structured solution terms#JSON form round-trips]] {level: proof, note: "theorem Elpi.Host.ResultTerm.json_roundtrip, restated as jsonRoundTrip"}
def jsonRoundTrips : IO Unit := do
  let ts : List ResultTerm :=
    [.app "person" #[.int 42, .list #[.str "a\"b", .ofFloat (-0.0)]], .unbound, .lam, .opaque "h" "7"]
  for t in ts do
    match Lean.Json.parse (toJson t).compress with
    | .ok j => check (fromJson? j == some t) s!"{t} round-trips through text"
    | .error e => fail e

/-! ### Resumable fuel slices -/

def slicesProgram : String := "
pred between i:int, i:int, o:int.
between L H L :- L =< H.
between L H X :- L < H, L1 is L + 1, between L1 H X.
pred hit o:int.
hit X :- between 1 150000 X, 0 is X mod 5000."

-- @tg: verifies:: [[openspec:engine-host-api#Resumable fuel slices#Slices equal one run]] {level: integration}
def slicesEqualOneRun : IO Unit := do
  let p ← load slicesProgram
  let (want, wantEnd) := runAll (← goalOf p "hit" #[.out "X"]) defaultFuel
  check (want.size == 30 && wantEnd == "exhausted") s!"one run: {want.size} solutions, {wantEnd}"
  for n in [1, 1000, 99991] do
    let (got, gotEnd) := runAll (← goalOf p "hit" #[.out "X"]) n
    check (got == want && gotEnd == wantEnd) s!"slices of {n} differ from one run"

-- @tg: verifies:: [[openspec:engine-host-api#Resumable fuel slices#Pausing does not copy the store]] {level: integration}
def pausingDoesNotCopy : IO Unit := do
  let p ← load "pred make i:int.\nmake 0.\nmake N :- N > 0, M is N - 1, sigma X\\ make M.\npred run o:int.\nrun 1 :- make 300000."
  let mut single := 1000000
  let mut sliced := 1000000
  for _ in [0:3] do
    let q ← goalOf p "run" #[.out "R"]
    let (_, t1) ← elapsedMs (IO.lazyPure fun _ => (runAll q defaultFuel).1.size)
    let q' ← goalOf p "run" #[.out "R"]
    let (_, t2) ← elapsedMs (IO.lazyPure fun _ => (runAll q' 1000).1.size)
    single := min single t1
    sliced := min sliced t2
  -- within 10%, plus 20 ms for the clock's granularity
  check (sliced * 10 ≤ single * 11 + 200) s!"slices of 1000 took {sliced} ms, one run {single} ms"

/-! ### Public clause AST -/

def orgDecls : String := "kind person type.
pred person.name o:person, o:string.
pred reports_to o:person, o:person, o:person.
pred check i:person.
check _.
"

def clausesOf (src : String) : IO Elpi.Host.Ast.Program :=
  match clauses [("org-rules", src)] with
  | .ok a => pure a
  | .error e => fail s!"{e}"

-- @tg: verifies:: [[openspec:engine-host-api#Public clause AST#Negation and cut are visible]] {level: integration}
def negationAndCut : IO Unit := do
  let a ← clausesOf (orgDecls ++ "pred v o:person.\nv P :- person.name P _, !, not (reports_to P _ _).")
  match (a.clauses.find? (·.pred == "v")).map Elpi.Host.Ast.Clause.body with
  | some (Elpi.Host.Ast.Goal.conj [.call "person.name" _, .cut, .not (.call "reports_to" _)]) => pure ()
  | b => fail s!"unexpected body {repr b}"

-- @tg: verifies:: [[openspec:engine-host-api#Public clause AST#Hypothetical clause is visible]] {level: integration}
def hypotheticalClause : IO Unit := do
  let a ← clausesOf (orgDecls ++ "pred w i:person.\nw X :- (reports_to X E Y :- true) => check X.")
  match (a.clauses.find? (·.pred == "w")).map Elpi.Host.Ast.Clause.body with
  | some (Elpi.Host.Ast.Goal.impl [h] _) => check (h.pred? == some "reports_to") "the hypothesis is about reports_to"
  | b => fail s!"unexpected body {repr b}"

/-! ### Bulk fact loading -/

def personDecls : String := "kind person type.\ntype person int -> person.\npred person.name o:person, o:string."

def nameRows (n : Nat) : Array (Array ResultTerm) :=
  (Array.range n).map fun k => #[.app "person" #[.int (Int.ofNat k)], .str s!"n{k}"]

-- @tg: verifies:: [[openspec:engine-host-api#Bulk fact loading#Facts from terms answer queries]] {level: integration}
def factsAnswerQueries : IO Unit := do
  let p ← load personDecls
  let some p' := (addFacts p "person.name" (nameRows 100000)).toOption | fail "loading failed"
  let sols ← solutions p' "person.name" #[.value (.app "person" #[.int 77]), .out "N"]
  check (sols == #[#[("N", .str "n77")]]) s!"one solution N = \"n77\", got {sols.size}"

-- @tg: verifies:: [[openspec:engine-host-api#Bulk fact loading#Loading is linear]] {level: integration}
def loadingIsLinear : IO Unit := do
  let p ← load personDecls
  let small := nameRows 100000
  let large := nameRows 1000000
  let (r1, t1) ← elapsedMs (IO.lazyPure fun _ => (addFacts p "person.name" small).toOption.isSome)
  let (r2, t2) ← elapsedMs (IO.lazyPure fun _ => (addFacts p "person.name" large).toOption.isSome)
  check (r1 && r2) "both batches load"
  check (t2 ≤ 15 * max t1 10) s!"10⁶ facts took {t2} ms, 10⁵ took {t1} ms"

-- @tg: verifies:: [[openspec:engine-host-api#Bulk fact loading#Ill-typed fact is rejected]] {level: integration}
def illTypedFact : IO Unit := do
  let p ← load personDecls
  match addFacts p "person.name" (nameRows 10 |>.push #[.str "x", .int 1]) with
  | .error (.fact "person.name" 11 1 _) => pure ()
  | .error e => fail s!"expected an error naming row 11, argument 1, got {e}"
  | .ok _ => fail "an ill-typed fact must reject the batch"

/-! ### Multi-unit load keeps positions -/

-- @tg: verifies:: [[openspec:engine-host-api#Multi-unit load keeps positions#Error position inside the module]] {level: integration}
def errorPosition : IO Unit := do
  let signature := "\n".intercalate ((List.range 199).map (s!"kind k{·} type.") ++ ["kind person type."])
  -- line 3, column 10 (columns count from 0): the 7 is not a person
  match compile [("signature", signature), ("org-rules", "pred ok i:person.\nok _.\nok _:- ok 7.\n")] with
  | .error (.located (d :: _)) =>
    check (d.unit == "org-rules" && d.line == 3 && d.col == 10) s!"error at {d.unit}:{d.line}:{d.col}"
  | .error e => fail s!"expected a located error, got {e}"
  | .ok _ => fail "the module must be rejected"

/-! ### Stored modules resolve accumulate -/

def graphBase : String := "pred edge o:int.\nedge 1.\nedge 2.\n"

-- @tg: verifies:: [[openspec:engine-host-api#Stored modules resolve accumulate#Module accumulates a stored module]] {level: integration}
def moduleAccumulates : IO Unit := do
  let rules := "accumulate graph-base.\npred two o:int.\ntwo N :- edge N, N > 1.\n"
  match compile [("org-rules", rules)] [("graph-base", graphBase)] with
  | .error e => fail s!"the stored module must resolve: {e}"
  | .ok p =>
    let sols ← solutions p "two" #[.out "N"]
    check (sols.size == 1) "org-rules calls edge"
  match accumulates "org-rules" rules with
  | .ok names => check (names == ["graph-base"]) s!"accumulated names {names}"
  | .error e => fail s!"{e}"

-- @tg: verifies:: [[openspec:engine-host-api#Stored modules resolve accumulate#Missing stored module is named]] {level: integration}
def missingStoredModule : IO Unit := do
  match compile [("org-rules", "accumulate graph-base.\n")] with
  | .error (.located (d :: _)) =>
    check (d.unit == "org-rules" && d.line == 1) s!"located at {d.unit}:{d.line}"
    check ((d.msg.splitOn "graph-base").length > 1) s!"names the module: {d.msg}"
  | _ => fail "a missing module must fail"

/-! ### Goals parsed from text for debugging -/

-- @tg: verifies:: [[openspec:engine-host-api#Goals parsed from text for debugging#Text goal binds its variables]] {level: integration}
def textGoal : IO Unit := do
  let p ← load graphBase
  match parseGoal p "edge X, X > 1" with
  | .error e => fail s!"{e}"
  | .ok q =>
    let (sols, ending) := runAll q 1000
    check (ending == "exhausted") ending
    check (sols.map (·.map fun (n, t) => s!"{n}={t}") == #[#["X=2"]]) s!"solutions {sols.size}"

-- @tg: verifies:: [[openspec:engine-host-api#Goals parsed from text for debugging#Syntax error column]] {level: integration}
def textGoalSyntaxError : IO Unit := do
  let p ← load graphBase
  match parseGoal p "edge X,, ok" with
  | .error (.located (d :: _)) => check (d.unit == "<goal>" && d.line == 1 && d.col == 7) s!"{d.unit}:{d.line}:{d.col}"
  | _ => fail "the goal must be rejected"

/-- Every contract check, by name. -/
def all : List (String × IO Unit) :=
    [("declared predicate", declaredPredicate), ("polymorphic predicate", polymorphicPredicate),
     ("unknown predicate", unknownPredicate), ("input values are not parsed", notParsed),
     ("ill-typed argument", illTypedArgument), ("constructor application", constructorApplication),
     ("unbound output", unboundOutput), ("JSON round-trips", jsonRoundTrips),
     ("slices equal one run", slicesEqualOneRun), ("pausing does not copy", pausingDoesNotCopy),
     ("negation and cut", negationAndCut), ("hypothetical clause", hypotheticalClause),
     ("facts answer queries", factsAnswerQueries), ("loading is linear", loadingIsLinear),
     ("ill-typed fact", illTypedFact), ("error position", errorPosition),
     ("module accumulates a stored module", moduleAccumulates),
     ("missing stored module", missingStoredModule), ("text goal", textGoal),
     ("text goal syntax error", textGoalSyntaxError)]

end EngineContract
