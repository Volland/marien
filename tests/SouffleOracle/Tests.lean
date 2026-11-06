import SouffleOracle.Translate
import M1

/-!
# Soufflé oracle: classifier and translator unit tests

The fragment classifier skips what it cannot translate exactly, with the reason; the end-to-end
comparison against Marien is `tests/oracle/souffle/run.sh`.
-/

open Property Oracle
open M1 (check fail contains)

namespace OracleTests

def schema : GSchema := (workload 3 4).schema

def skips (src entry : String) (answer : Answer) (reason : String) : IO Unit :=
  match translate schema src entry answer with
  | .ok p => fail s!"translated instead of skipped:\n{p.text}"
  | .error e => check (contains e reason) s!"skipped for {e}, expected {reason}"

def violationDecl : String := "pred violation o:severity, o:string, o:subject.\n"

-- @tg: verifies:: [[openspec:differential-testing#Soufflé oracle#Out-of-fragment modules are skipped]] {level: unit}
def outOfFragment : IO Unit := do
  skips (violationDecl ++ "violation error \"p\" (subj_t0 A) :- t0 A, pi x\\ (t0.p0 A x).\n") "violation" .violation "pi"
  skips ("accumulate graph.std.\n" ++ violationDecl ++
    "violation error \"c\" (subj_t0 X) :- card_witness t0 r0 1 2 X N.\n") "violation" .violation "accumulate"
  skips (violationDecl ++ "violation error \"c\" (subj_t0 X) :- t0 X, closure r0 X Y.\n") "violation" .violation
    "neither a module nor a database predicate"
  skips (violationDecl ++ "violation error \"c\" (subj_t0 X) :- t0 X, !.\n") "violation" .violation "cut"
  skips (violationDecl ++ "violation error \"c\" (subj_t0 X) :- (r0 X (r0 0) X) => t0 X.\n") "violation" .violation "=>"
  skips (violationDecl ++ "violation error \"c\" (subj_r0 E) :- r0 _ E _.\n") "violation" .violation "not a node"
  skips (violationDecl ++ "violation error \"c\" (subj_t0 X) :- t0 X, P X.\n") "violation" .violation "higher-order"
  -- recursion through a negation is not stratified
  skips ("pred p o:t0.\np X :- t0 X, not (p X).\n") "p" (.nodes 1) "stratified"

def unreachedIgnored : IO Unit := do
  -- the helpers with a cut and with recursion are not reached, so the module translates
  match translate schema ((workload 1 4).partition.body) "violation" .violation with
  | .ok p => check (p.outputs.length ≥ 1) "one proof relation per clause branch"
  | .error e => fail s!"skipped: {e}"

def proofRelations : IO Unit := do
  let src := violationDecl ++
    "violation error \"c\" (subj_t0 A) :- t0.p0 A V, (V > 1 ; t0.p1 A \"a\"), not (r0 A _ _).\n"
  match translate schema src "violation" .violation with
  | .error e => fail e
  | .ok p =>
    check (p.outputs.length == 2) s!"one proof relation per disjunct: {repr p.outputs}"
    check (contains p.text "!neg") s!"the negation is an auxiliary relation:\n{p.text}"
    check (contains p.text "neg2(c0_A) :- p_t0_p0(c0_A, c0_V)") s!"over the variables bound before it:\n{p.text}"

def unfolding : IO Unit := do
  let src := violationDecl ++ "pred near o:t0.\nnear X :- r0 X _ Y, t0.p0 Y _.\n" ++
    "violation warning \"n\" (subj_t0 A) :- t0 A, near A.\n"
  match translate schema src "violation" .violation with
  | .error e => fail e
  | .ok p =>
    check (p.outputs.length == 1) s!"near is unfolded into the clause: {repr p.outputs}"
    check (!contains p.text "d_near") s!"no relation for a predicate called positively:\n{p.text}"

def scenario : IO Unit := do
  match translate schema scenarioRule "violation" .violation with
  | .error e => fail s!"the scenario rule is in the fragment: {e}"
  | .ok _ => pure ()

def all : List (String × IO Unit) :=
  [("out-of-fragment modules are skipped", outOfFragment), ("unreached clauses are ignored", unreachedIgnored),
   ("proof relations", proofRelations), ("positive calls are unfolded", unfolding),
   ("the scenario rule translates", scenario)]

end OracleTests
