import M1
import Marien.Ffi

/-!
# M2 unit tests

The Lean layers of typed validation without a database: typed entry points, the validation
protocol and report, the subject codec, reached-table hashes, lazy recheck and `elpi_recheck`.
Scenarios that need LadybugDB (transactions, rollback, the shim's columns, loading the library)
are integration tests in `tests/integration/`.
-/

open Marien Marien.Encoding Marien.Encoding.Codec Marien.Store Marien.Exec
open Marien.Engine (ResultTerm)
open M1 (check fail ok contains int str saveTo)

namespace M2

/-- People with a title, departments, and who reports to whom. -/
def orgJson (extraPersonProps : String := "") (reportsTo := true) (invoice := false) : String :=
  "{\"nodes\": [
    {\"name\": \"Person\", \"key\": \"id\", \"properties\": [
      {\"name\": \"id\", \"type\": \"INT64\"}, {\"name\": \"name\", \"type\": \"STRING\"},
      {\"name\": \"title\", \"type\": \"STRING\"}" ++ extraPersonProps ++ "]},
    {\"name\": \"Dept\", \"key\": \"code\", \"properties\": [{\"name\": \"code\", \"type\": \"STRING\"}]}" ++
    (if invoice then ",\n{\"name\": \"Invoice\", \"key\": \"no\", \"properties\": [{\"name\": \"no\", \"type\": \"INT64\"}]}" else "") ++ ",
    {\"name\": \"_elpi_module\", \"key\": \"name\", \"properties\": [{\"name\": \"name\", \"type\": \"STRING\"}]}],
   \"rels\": [" ++
    (if reportsTo then "{\"name\": \"ReportsTo\", \"pairs\": [[\"Person\", \"Person\"]], \"properties\": []}," else "") ++
    "{\"name\": \"_elpi_accumulates\", \"pairs\": [[\"_elpi_module\", \"_elpi_module\"]], \"properties\": []}]}"

def schemaOf (j : String) : IO Schema := ok (Schema.parse j) "schema"

def org : IO Schema := schemaOf (orgJson)

def orgSrc : String :=
  "pred manager_of i:person, o:person, o:string.
manager_of P M T :- reports_to P _ M, person.title M T.
type helper person -> prop.
helper _.
pred violation o:severity, o:string, o:subject.
violation error \"no-manager\" (subj_person P) :- person.name P _, not (reports_to P _ _).
violation warning \"no-title\" (subj_person P) :- person P, not (person.title P _).
"

def hrSrc : String :=
  "pred violation o:severity, o:string, o:subject.
violation info \"reviewed\" (subj_person (person 7)).
pred violation_message i:string, i:subject, o:string.
violation_message \"reviewed\" _ \"person 7 was reviewed\".
"

def pathsSrc : String := "pred path o:person, o:person.\npath A B :- reports_to A _ B.\n"

/-- Persons 3 (CEO), 7 (reports to 3) and 9 (no manager, no title); `title` is the given text
for person 3. -/
def load (s : Session) (title3 : String := "CEO") : IO Session := do
  let mut s := s
  for i in [0:s.scans.size] do
    match s.scans[i]! with
    | .node ns =>
      if ns.plan.name == "Person" then
        let cols := ns.props.map fun p => match p.name with
          | "name" => #[str "ceo", str "ann", str "bob"]
          | "title" => #[str title3, str "Engineer", .null]
          | _ => #[.null, .null, .null]
        s ← ok (addBatch s i (#[#[int 3, int 7, int 9]] ++ cols.toArray)) "person batch"
    | .rel rs =>
      if rs.plan.name == "ReportsTo" then
        s ← ok (addBatch s i #[#[str "Person"], #[int 7], #[int 100], #[str "Person"], #[int 3]]) "reports_to batch"
    | .structural .. => pure ()
  return s

/-- Every solution's items, to the end. -/
partial def runItems (r : Run) : IO (Array (Array String)) :=
  go r #[]
where
  go (r : Run) (acc : Array (Array String)) : IO (Array (Array String)) :=
    match step r with
    | .solution items r' => go r' (acc.push items)
    | .paused r' => go r' acc
    | .done _ => pure acc
    | .error e => throw (IO.userError e)

def stored : IO (List Stored) := do
  let sc ← org
  let st ← saveTo sc [] "org" orgSrc
  saveTo sc st "hr" hrSrc

def runSession (sc : Schema) (st : List Stored) (pred : String) (params : List (String × Value))
    (title3 : String := "CEO") : IO (Session × Array (Array String)) := do
  let (s, _) ← ok (prepareRun {} sc st "org" pred params 1000000) "prepareRun"
  let s ← load s title3
  return (s, ← runItems (← ok (startGoal s 1000000 1000 1000000) "start"))

/-! ### Typed entry points -/

-- @tg: verifies:: [[openspec:rule-execution#Typed entry points#Output columns are typed at bind time]] {level: unit}
def columnsAtBind : IO Unit := do
  let sc ← org
  let (s, _) ← ok (prepareRun {} sc (← stored) "org" "manager_of" [("in1", int 7)] 1000000) "prepareRun"
  let cols := Marien.Ffi.sessionColumns s
  check (cols == #[#["out2", "INT64"], #["out3", "STRING"]]) s!"{cols}"

-- @tg: verifies:: [[openspec:rule-execution#Typed entry points#Node results come back as primary keys]] {level: unit}
def nodeResults : IO Unit := do
  let (_, rows) ← runSession (← org) (← stored) "manager_of" [("in1", int 7)]
  check (rows == #[#["i3", "sCEO"]]) s!"{rows}"

-- @tg: verifies:: [[openspec:rule-execution#Typed entry points#Bad parameters fail the bind]] {level: unit}
def badParameters : IO Unit := do
  let sc ← org
  let st ← stored
  let expectErr (params : List (String × Value)) (parts : List String) : IO Unit :=
    match prepareRun {} sc st "org" "manager_of" params 1000000 with
    | .ok _ => fail s!"{params.map (·.1)} must fail"
    | .error e => check (parts.all (contains e ·)) e
  expectErr [("in1", str "seven")] ["in1", "person"]
  expectErr [] ["missing", "in1"]
  expectErr [("in1", int 7), ("in2", int 1)] ["in2"]

-- @tg: verifies:: [[openspec:rule-execution#Typed entry points#Predicates without modes are rejected]] {level: unit}
def withoutModes : IO Unit := do
  match prepareRun {} (← org) (← stored) "org" "helper" [] 1000000 with
  | .ok _ => fail "helper has no modes"
  | .error e => check (contains e "no mode declaration") e

-- @tg: verifies:: [[openspec:rule-execution#Typed entry points#Strings round-trip without printing]] {level: unit}
def stringsRoundTrip : IO Unit := do
  let hostile := "say \"hi\"\\\nnext line"
  let (_, rows) ← runSession (← org) (← stored) "manager_of" [("in1", int 7)] hostile
  check (rows == #[#["i3", "s" ++ hostile]]) s!"{rows}"

/-! ### Validation -/

def report (sc : Schema) (st : List Stored) (name : String) (min : Severity := .info) :
    IO (Array (Array String)) := do
  let (s, _) ← ok (prepareValidate {} sc st name 1000000 min) "prepareValidate"
  let s ← load s
  runItems (← ok (startGoal s 1000000 1000 1000000) "start")

-- @tg: verifies:: [[openspec:validation#Violation protocol#Module with violation takes part]] {level: unit}
def violationTakesPart : IO Unit := do
  let rows ← report (← org) (← stored) "org"
  let errors := rows.filter (·[2]! == "error")
  check (errors.map (·[6]!) == #["3", "9"]) s!"{rows}"
  check (errors.all fun r => r[0]! == "org" && r[1]! == "1" && r[3]! == "no-manager" &&
    r[4]! == "no-manager" && r[5]! == "Person") s!"{errors}"

-- @tg: verifies:: [[openspec:validation#Violation protocol#Wrong signature is rejected]] {level: unit}
def wrongSignature : IO Unit := do
  match Store.check (← org) [] "bad" "pred violation o:string.\nviolation \"x\".\n" with
  | .ok _ => fail "must be rejected"
  | .error e => check (contains e "type error" && contains e "violation o:severity, o:string, o:subject") e

-- @tg: verifies:: [[openspec:validation#Violation protocol#Reasoning modules are skipped]] {level: unit}
def reasoningSkipped : IO Unit := do
  let sc ← org
  let st ← saveTo sc (← stored) "paths" pathsSrc
  let order ← ok (validationOrder st none) "order"
  check (order == ["hr", "org"]) s!"{order}"

-- @tg: verifies:: [[openspec:validation#Subject union kind#One constructor per table]] {level: unit}
def oneConstructorPerTable : IO Unit := do
  let sig ← ok (Signature.ofSchema M1.reserved (← org)) "signature"
  let t := sig.text
  for c in ["kind subject type.", "type subj_person person -> subject.", "type subj_dept dept -> subject.",
            "type subj_reports_to reports_to -> subject.", "type error, warning, info severity."] do
    check (contains t c) s!"missing {c}"
  check (!contains t "subj__elpi") "no constructor for a system table"

-- @tg: verifies:: [[openspec:validation#Subject union kind#Subject decodes to label and key]] {level: unit}
def subjectDecodes : IO Unit := do
  let sig ← ok (Signature.ofSchema M1.reserved (← org)) "signature"
  let t : ResultTerm := .app "subj_person" #[.app "person" #[.int 42]]
  match decodeSubject (subjectCases sig) t with
  | some (label, key) => check (label == "Person" && keyText key == "42") s!"{label} {keyText key}"
  | none => fail "subj_person (person 42) must decode"
  let e : ResultTerm := .app "subj_reports_to" #[.app "reports_to" #[.int 100]]
  check ((decodeSubject (subjectCases sig) e).map (·.1) == some "ReportsTo") "edge subject"

-- @tg: verifies:: [[openspec:validation#Uniform validation report#Report across modules]] {level: unit}
def reportAcrossModules : IO Unit := do
  let sc ← org
  let st ← stored
  let order ← ok (validationOrder st none) "order"
  check (order == ["hr", "org"]) s!"{order}"
  let hr ← report sc st "hr"
  check (hr == #[#["hr", "1", "info", "reviewed", "person 7 was reviewed", "Person", "7"]]) s!"{hr}"
  -- a listed order is kept
  let listed ← ok (validationOrder st (some ["org", "hr"])) "listed"
  check (listed == ["org", "hr"]) "listed order"

-- @tg: verifies:: [[openspec:validation#Uniform validation report#Severity filter]] {level: unit}
def severityFilter : IO Unit := do
  let rows ← report (← org) (← stored) "org" .error
  check (rows.size == 2 && rows.all (·[2]! == "error")) s!"{rows}"
  let all ← report (← org) (← stored) "org" .info
  check (all.size == 3) s!"{all}"

-- @tg: verifies:: [[openspec:validation#Uniform validation report#A failing module fails the call]] {level: unit}
def failingModule : IO Unit := do
  let sc ← org
  let st ← saveTo sc (← stored) "loop" "pred violation o:severity, o:string, o:subject.\npred spin.\nspin :- spin.\nviolation error \"x\" (subj_person (person 1)) :- spin.\n"
  let (s, _) ← ok (prepareValidate {} sc st "loop" 1000000 .info) "prepare"
  let r ← ok (startGoal s 5000 1000 1000000) "start"
  match ← (runItems r).toBaseIO with
  | .ok _ => fail "must run out of fuel"
  | .error e => check (contains (toString e) "elpi_fuel") (toString e)

/-! ### Schema evolution -/

def orgHash (sc : Schema) (st : List Stored) : IO String := do
  let some m := st.find? (·.name == "org") | fail "org"
  return Schema.reachedHash (Derived.ofStored m).reached sc

-- @tg: verifies:: [[openspec:schema-evolution#Reached-table schema hash#Unrelated DDL keeps the hash]] {level: unit}
def unrelatedDdl : IO Unit := do
  let st ← stored
  let some m := st.find? (·.name == "org") | fail "org"
  check ((Derived.ofStored m).reached == ["Person", "ReportsTo"]) s!"{(Derived.ofStored m).reached}"
  check ((← orgHash (← org) st) == (← orgHash (← schemaOf (orgJson (invoice := true))) st)) "Invoice is unrelated"

-- @tg: verifies:: [[openspec:schema-evolution#Reached-table schema hash#Reached DDL changes the hash]] {level: unit}
def reachedDdl : IO Unit := do
  let st ← stored
  let email := ", {\"name\": \"email\", \"type\": \"STRING\"}"
  check ((← orgHash (← org) st) != (← orgHash (← schemaOf (orgJson email)) st)) "email changes Person"

-- @tg: verifies:: [[openspec:schema-evolution#Lazy recheck on run#Compatible change recompiles in memory]] {level: unit}
def compatibleChange : IO Unit := do
  let st ← stored
  let (_, c1) ← ok (prepareRun {} (← org) st "org" "manager_of" [("in1", int 7)] 1000000) "first"
  let changed ← schemaOf (orgJson ", {\"name\": \"email\", \"type\": \"STRING\"}")
  let (s, c2) ← ok (prepareRun c1 changed st "org" "manager_of" [("in1", int 7)] 1000000) "after DDL"
  check (c2.misses == c1.misses + 1) "the new hash misses the cache: recompiled"
  let s ← load s
  let rows ← runItems (← ok (startGoal s 1000000 1000 1000000) "start")
  check (rows == #[#["i3", "sCEO"]]) s!"{rows}"

-- @tg: verifies:: [[openspec:schema-evolution#Lazy recheck on run#Breaking change fails the run]] {level: unit}
def breakingChange : IO Unit := do
  let st ← stored
  let (_, c1) ← ok (prepareRun {} (← org) st "org" "manager_of" [("in1", int 7)] 1000000) "first"
  match prepareRun c1 (← schemaOf (orgJson (reportsTo := false))) st "org" "manager_of" [("in1", int 7)] 1000000 with
  | .ok _ => fail "dropping ReportsTo must fail the run"
  | .error e => check (contains e "reports_to" && contains e "org:") e

-- @tg: verifies:: [[openspec:schema-evolution#Broken module status#Recheck marks a module broken]] {level: unit}
def recheckBroken : IO Unit := do
  let st ← stored
  let stmts ← ok (Store.recheck (← schemaOf (orgJson (reportsTo := false))) st (some ["org"])) "recheck"
  check (stmts.length == 1) "one statement"
  let q := stmts.head!
  check (contains q "new: 'broken'" && contains q "reports_to" && contains q "old: 'stale'") q

-- @tg: verifies:: [[openspec:schema-evolution#Explicit recheck#Recheck persists regenerated modules]] {level: unit}
def recheckPersists : IO Unit := do
  let st ← stored
  -- the stored hash, as elpi_save wrote it
  let sc ← org
  let st := st.map fun m => { m with schemaHash := Schema.reachedHash (Derived.ofStored m).reached sc }
  let changed ← schemaOf (orgJson ", {\"name\": \"email\", \"type\": \"STRING\"}")
  let r := recheckOne changed st ((st.find? (·.name == "org")).get!)
  check (r.oldStatus == "stale" && r.newStatus == "ok") s!"{repr r}"
  check (r.schemaHash == (← orgHash changed st)) "the new hash is the recomputed one"
  -- an unchanged module stays ok
  let same := recheckOne sc st ((st.find? (·.name == "org")).get!)
  check (same.oldStatus == "ok" && same.newStatus == "ok") s!"{repr same}"

-- @tg: verifies:: [[openspec:schema-evolution#Broken module status#Saving clears broken]] {level: unit}
def savingClearsBroken : IO Unit := do
  let c ← ok (Store.check (← org) [] "org" orgSrc) "save"
  check (contains c.statement "m.status = 'ok', m.error = ''") c.statement

/-- Accumulated modules' generated predicates are scanned for the module that accumulates them. -/
def accumulatedFacts : IO Unit := do
  let sc ← org
  let st ← saveTo sc [] "base" "pred boss o:person.\nboss M :- reports_to _ _ M.\n"
  let st ← saveTo sc st "top" "accumulate base.\npred top_boss o:person.\ntop_boss M :- boss M.\n"
  let some m := st.find? (·.name == "top") | fail "top"
  let d := Derived.ofStored m
  check (d.callsGenerated.contains "reports_to" && d.reached.contains "ReportsTo") s!"{repr d}"

def all : List (String × IO Unit) :=
  [("output columns typed at bind", columnsAtBind), ("node results as keys", nodeResults),
   ("bad parameters", badParameters), ("predicates without modes", withoutModes),
   ("strings round-trip", stringsRoundTrip), ("violation takes part", violationTakesPart),
   ("wrong violation signature", wrongSignature), ("reasoning modules skipped", reasoningSkipped),
   ("one subject constructor per table", oneConstructorPerTable), ("subject decodes", subjectDecodes),
   ("report across modules", reportAcrossModules), ("severity filter", severityFilter),
   ("failing module", failingModule), ("unrelated DDL", unrelatedDdl), ("reached DDL", reachedDdl),
   ("compatible change", compatibleChange), ("breaking change", breakingChange),
   ("recheck marks broken", recheckBroken), ("recheck persists", recheckPersists),
   ("saving clears broken", savingClearsBroken), ("accumulated facts", accumulatedFacts)]

end M2
