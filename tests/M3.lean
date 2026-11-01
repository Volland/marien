import M2

/-!
# M3 unit tests

The rule analyzer at save time (reachability, monotonicity, `dynamic`, locality of anchor and
key partitions), the narrowed-scope check at bind time, the verdicts recomputed by the lazy
recheck, and the partition planner's batches and buckets. Partitioned and narrowed runs over a
real graph are integration tests in `tests/integration/`.
-/

open Marien Marien.Encoding Marien.Store Marien.Exec Marien.Analysis
open M1 (check fail ok contains int str saveTo)
open M2 (orgJson schemaOf org)

namespace M3

def saveErr (sc : Schema) (st : List Stored) (name src : String) : IO String :=
  match Store.check sc st name src with
  | .ok _ => fail s!"saving {name} must fail"
  | .error e => pure e

def verdictOf (st : List Stored) (name pred : String) : IO EntryVerdict := do
  let some m := st.find? (·.name == name) | fail s!"no module {name}"
  let some v := (Derived.ofStored m).verdict? pred | fail s!"{name} has no verdict for {pred}"
  return v

/-! ### Reachability -/

-- @tg: verifies:: [[openspec:rule-analysis#Entry-point reachability#Reachability through accumulate]] {level: unit}
def throughAccumulate : IO Unit := do
  let sc ← org
  let st ← saveTo sc [] "base" "pred manages o:person, o:person.\nmanages P M :- reports_to P _ M.\n"
  let st ← saveTo sc st "org" ("accumulate base.\npred violation o:severity, o:string, o:subject.\n" ++
    "violation error \"manages-self\" (subj_person P) :- manages P P.\n")
  let v ← verdictOf st "org" "violation"
  check (v.reached.contains "reports_to" && v.tables.contains "ReportsTo") s!"{repr v}"

-- @tg: verifies:: [[openspec:rule-analysis#Entry-point reachability#Variable predicates are over-approximated]] {level: unit}
def variablePredicates : IO Unit := do
  let sc ← org
  let st ← saveTo sc [] "org" ("pred manages o:person, o:person.\nmanages P M :- reports_to P _ M.\n" ++
    "pred check i:(person -> person -> prop), o:person, o:person.\ncheck R P M :- R P M.\n")
  let v ← verdictOf st "org" "check"
  -- manages has the type of R, so check may call it, and so reaches reports_to
  check (v.reached.contains "reports_to") s!"{repr v}"
  -- person.name has another type
  check (!v.reached.contains "person.name") s!"{repr v}"

-- @tg: verifies:: [[openspec:rule-analysis#Entry-point reachability#Unreached tables are excluded]] {level: unit}
def unreachedExcluded : IO Unit := do
  let sc ← schemaOf (orgJson (invoice := true))
  let st ← saveTo sc [] "org" (M2.orgSrc ++ "pred late o:invoice.\nlate I :- invoice I.\n")
  let v ← verdictOf st "org" "violation"
  check (!v.tables.contains "Invoice" && !v.reached.contains "invoice") s!"{repr v}"
  -- and a validation does not scan it
  let (s, _) ← ok (prepareValidate {} sc st "org" 1000000 .info) "prepareValidate"
  check (!s.scans.any (·.table == "Invoice")) "Invoice is not scanned"

/-! ### Monotonicity -/

-- @tg: verifies:: [[openspec:rule-analysis#Monotonicity check#Negation over database facts is not monotone]] {level: unit}
def negationOverDb : IO Unit := do
  let sc ← org
  let st ← saveTo sc [] "org" ("pred violation o:severity, o:string, o:subject.\n" ++
    "violation error \"no-manager\" (subj_person P) :- person.name P _, not (reports_to P _ _).\n")
  let v ← verdictOf st "org" "violation"
  check (!v.monotone) "not monotone"
  let some o := v.offense | fail "an offense"
  check (o.construct == "not" && o.pred == "reports_to" && o.pos == "org:2:0") s!"{repr o}"

-- @tg: verifies:: [[openspec:rule-analysis#Monotonicity check#Negation over local facts stays monotone]] {level: unit}
def negationOverLocal : IO Unit := do
  let sc ← org
  let st ← saveTo sc [] "org" ("pred colleague o:person, o:person.\n" ++
    "colleague A B :- reports_to A _ M, reports_to B _ M, not (std.mem [1, 2] 3).\n")
  let v ← verdictOf st "org" "colleague"
  check (v.monotone && v.offense.isNone) s!"{repr v}"

-- @tg: verifies:: [[openspec:rule-analysis#Monotonicity check#Cut is treated like negation]] {level: unit}
def cutLikeNegation : IO Unit := do
  let sc ← org
  let st ← saveTo sc [] "org" ("pred first o:person.\nfirst P :- person.name P _, !.\n" ++
    "pred top o:person.\ntop P :- first P.\n")
  let v ← verdictOf st "org" "top"
  check (!v.monotone && (v.offense.map (·.construct)) == some "!") s!"{repr v}"

/-! ### Dynamic -/

def dynamicSrc : String :=
  "pred check o:person.\ncheck P :- reports_to P _ _.\n" ++
  "pred vio o:person.\nvio P :- person P, (reports_to P (reports_to 0) P) => check P.\n"

-- @tg: verifies:: [[openspec:rule-analysis#Dynamic inference#Hypothetical database clause makes an entry point dynamic]] {level: unit}
def hypotheticalDynamic : IO Unit := do
  let sc ← org
  let st ← saveTo sc [] "org" dynamicSrc
  let v ← verdictOf st "org" "vio"
  check (v.dynamic && !v.monotone) s!"{repr v}"
  check ((v.dynamicGoal.map (contains · "=> check P")).getD false) s!"{repr v.dynamicGoal}"

-- @tg: verifies:: [[openspec:rule-analysis#Dynamic inference#Users cannot clear dynamic]] {level: unit}
def cannotClearDynamic : IO Unit := do
  let sc ← org
  let c ← ok (Store.check sc [] "org" (dynamicSrc ++ "% @marien static vio\n")) "save"
  let some v := c.derived.verdict? "vio" | fail "verdict"
  check v.dynamic "still dynamic"
  check (c.warnings.any fun w => contains w "vio stays dynamic" && contains w "=> check P") s!"{c.warnings}"

/-! ### Locality -/

def noManager : String :=
  "pred violation o:severity, o:string, o:subject.\n" ++
  "violation error \"no-manager\" (subj_person P) :- person.name P _, not (reports_to P _ _).\n" ++
  "% @marien partition violation by person radius 1\n"

-- @tg: verifies:: [[openspec:rule-analysis#Locality check#Outgoing edge within radius is accepted]] {level: unit}
def outgoingAccepted : IO Unit := do
  let st ← saveTo (← org) [] "org" noManager
  let v ← verdictOf st "org" "violation"
  check (v.partition == some (.anchor "Person" 1 [("ReportsTo", "outgoing")])) s!"{repr v.partition}"

-- @tg: verifies:: [[openspec:rule-analysis#Locality check#Unanchored atom is rejected]] {level: unit}
def unanchoredRejected : IO Unit := do
  let e ← saveErr (← org) [] "org"
    (noManager ++ "violation error \"bob\" (subj_person P) :- person.name P _, person.name Q \"Bob\".\n")
  check (contains e "rejected" && contains e "person.name at org:4:0") e

-- @tg: verifies:: [[openspec:rule-analysis#Locality check#Radius is enforced]] {level: unit}
def radiusEnforced : IO Unit := do
  let src := noManager ++
    "violation error \"grand\" (subj_person P) :- reports_to P _ M, reports_to M _ G, person.name G _.\n"
  let e ← saveErr (← org) [] "org" src
  check (contains e "reports_to at org:4:0 is not within radius 1") e
  -- radius 2 sees the grand-manager
  let st ← saveTo (← org) [] "org" (src.replace "radius 1" "radius 2")
  let v ← verdictOf st "org" "violation"
  check (v.partition == some (.anchor "Person" 2 [("ReportsTo", "outgoing")])) s!"{repr v.partition}"

-- @tg: verifies:: [[openspec:rule-analysis#Locality check#Subject must be the anchor]] {level: unit}
def subjectIsAnchor : IO Unit := do
  -- the subject of every clause is the anchor; one about a fixed person or an edge is not
  let e ← saveErr (← org) [] "org" (noManager ++ "violation info \"seven\" (subj_person (person 7)).\n")
  check (contains e "the subject must be the anchor") e
  let e ← saveErr (← org) [] "org"
    (noManager ++ "violation info \"edge\" (subj_reports_to E) :- reports_to _ E _.\n")
  check (contains e "the subject must be the anchor") e

/-! ### Key partitions -/

def emailOrg : IO Schema := schemaOf (orgJson ", {\"name\": \"email\", \"type\": \"STRING\"}")

def dupEmail : String :=
  "pred violation o:severity, o:string, o:subject.\n" ++
  "violation error \"dup-email\" (subj_person P) :- person.email P E, person.email Q E, not (P = Q).\n" ++
  "% @marien partition violation by person.email\n"

def keyAccepted : IO Unit := do
  let st ← saveTo (← emailOrg) [] "org" dupEmail
  let v ← verdictOf st "org" "violation"
  check (v.partition == some (.key "Person" "email")) s!"{repr v.partition}"

-- @tg: verifies:: [[openspec:partitioning#Key partitions#Unjoined atom rejects the key partition]] {level: unit}
def unjoinedRejected : IO Unit := do
  let src := dupEmail.replace "not (P = Q)." "not (P = Q), dept D."
  let e ← saveErr (← emailOrg) [] "org" src
  check (contains e "dept at org:2:0 is not joined to person.email") e

-- @tg: verifies:: [[openspec:partitioning#Dynamic entry points stay whole#Partition on a dynamic entry point is rejected]] {level: unit}
def dynamicNotPartitioned : IO Unit := do
  let e ← saveErr (← org) [] "org" (dynamicSrc ++ "% @marien partition vio by person radius 1\n")
  check (contains e "cannot partition vio" && contains e "=> check P") e

/-! ### Narrowed scope -/

def colleagueSrc : String :=
  "pred colleague o:person, o:person.\ncolleague A B :- reports_to A _ M, reports_to B _ M.\n"

-- @tg: verifies:: [[openspec:rule-execution#Narrowed scope for monotone entry points#Monotone entry point accepts a scope]] {level: unit, confidence: partial, note: "the bind check; the integration test checks the narrowed column"}
def monotoneScope : IO Unit := do
  let sc ← org
  let st ← saveTo sc [] "org" colleagueSrc
  let _ ← ok (prepareRun {} sc st "org" "colleague" [] 1000000 (narrowed := true)) "prepareRun with a scope"

-- @tg: verifies:: [[openspec:rule-execution#Narrowed scope for monotone entry points#Non-monotone entry point refuses a scope]] {level: unit}
def nonMonotoneScope : IO Unit := do
  let sc ← org
  let st ← saveTo sc [] "org" noManager
  match prepareValidate {} sc st "org" 1000000 .info (narrowed := true) with
  | .ok _ => fail "a scope on a non-monotone entry point must fail"
  | .error e => check (contains e "not at org:2:0 reaches reports_to") e

/-! ### Recheck -/

/-- After a schema change the verdicts are computed again: a variable predicate now also covers
the new property. -/
def recheckVerdicts : IO Unit := do
  let sc ← org
  let src := "pred check i:(person -> string -> prop), o:person.\ncheck R P :- R P _.\n"
  let st ← saveTo sc [] "org" src
  let st := st.map fun m => { m with schemaHash := Schema.reachedHash (Derived.ofStored m).reached sc }
  let changed ← emailOrg
  let (_, d, _, _) ← ok (compiledFor {} changed st "org") "compiledFor"
  let some v := d.verdict? "check" | fail "verdict"
  check (v.reached.contains "person.email") s!"{repr v}"
  -- elpi_recheck stores the new verdicts too
  let r := recheckOne changed st ((st.find? (·.name == "org")).get!)
  check (contains r.derived "person.email") r.derived

/-! ### Batches and buckets -/

def plannerShapes : IO Unit := do
  check (Partition.batchSizes 10000 50000 == [10000, 10000, 10000, 10000, 10000]) "five batches"
  check (Partition.batchSizes 7 20 == [7, 7, 6]) s!"{Partition.batchSizes 7 20}"
  check (Partition.batchSizes 0 2 == [1, 1]) "batch size 0 is 1"
  let b := Partition.bucketsOf 4 [some "a@x", none, some "a@x"]
  check (b[1]! == none && b[0]! == b[2]!) s!"{b}"

def all : List (String × IO Unit) :=
  [("reachability through accumulate", throughAccumulate), ("variable predicates", variablePredicates),
   ("unreached tables excluded", unreachedExcluded), ("negation over database facts", negationOverDb),
   ("negation over local facts", negationOverLocal), ("cut like negation", cutLikeNegation),
   ("hypothetical clause is dynamic", hypotheticalDynamic), ("dynamic cannot be cleared", cannotClearDynamic),
   ("outgoing edge accepted", outgoingAccepted), ("unanchored atom rejected", unanchoredRejected),
   ("radius enforced", radiusEnforced), ("subject is the anchor", subjectIsAnchor),
   ("key partition accepted", keyAccepted), ("unjoined atom rejected", unjoinedRejected),
   ("dynamic not partitioned", dynamicNotPartitioned), ("monotone scope", monotoneScope),
   ("non-monotone scope", nonMonotoneScope), ("recheck recomputes verdicts", recheckVerdicts),
   ("batches and buckets", plannerShapes)]

end M3
