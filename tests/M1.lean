import Marien.Exec.Run

/-!
# M1 unit tests

The Lean layers of the tracer bullet without a database: schema model, signature, codec, module
store, handle cache and executor. Column batches stand in for the shim's table scanner. Scenarios
that need LadybugDB itself (transactions, interrupts, the real lexer, memory) are integration
tests in `tests/integration/`.
-/

open Marien Marien.Encoding Marien.Store Marien.Exec
open Marien.Engine (ResultTerm)

namespace M1

def check (b : Bool) (msg : String) : IO Unit := unless b do throw (IO.userError msg)

def fail {α : Type} (msg : String) : IO α := throw (IO.userError msg)

def ok {α ε : Type} [ToString ε] (r : Except ε α) (what : String) : IO α :=
  match r with
  | .ok a => pure a
  | .error e => fail s!"{what}: {e}"

def contains (s part : String) : Bool := (s.splitOn part).length > 1

/-- People, companies, cars, events; `Knows` has one pair, `Owns` two. -/
def orgJson : String := "{\"nodes\": [
  {\"name\": \"Person\", \"key\": \"id\", \"properties\": [
    {\"name\": \"id\", \"type\": \"INT64\"}, {\"name\": \"name\", \"type\": \"STRING\"},
    {\"name\": \"age\", \"type\": \"INT64\"}, {\"name\": \"born\", \"type\": \"DATE\"},
    {\"name\": \"balance\", \"type\": \"UINT64\"},
    {\"name\": \"tags\", \"type\": {\"other\": \"MAP(STRING, INT64)\"}}]},
  {\"name\": \"Company\", \"key\": \"code\", \"properties\": [{\"name\": \"code\", \"type\": \"STRING\"}]},
  {\"name\": \"Car\", \"key\": \"vin\", \"properties\": [{\"name\": \"vin\", \"type\": \"INT64\"}]},
  {\"name\": \"Event\", \"key\": \"id\", \"properties\": [
    {\"name\": \"id\", \"type\": \"INT64\"}, {\"name\": \"title\", \"type\": \"STRING\"}]},
  {\"name\": \"_elpi_module\", \"key\": \"name\", \"properties\": [
    {\"name\": \"name\", \"type\": \"STRING\"}, {\"name\": \"source\", \"type\": \"STRING\"}]}],
 \"rels\": [
  {\"name\": \"Knows\", \"pairs\": [[\"Person\", \"Person\"]], \"properties\": [{\"name\": \"since\", \"type\": \"INT64\"}]},
  {\"name\": \"Owns\", \"pairs\": [[\"Person\", \"Car\"], [\"Company\", \"Car\"]], \"properties\": []},
  {\"name\": \"_elpi_accumulates\", \"pairs\": [[\"_elpi_module\", \"_elpi_module\"]], \"properties\": []}]}"

def org : IO Schema := ok (Schema.parse orgJson) "schema"

def reserved (n : String) : Bool := Engine.reservedNames.contains n

def sigOf (s : Schema) : IO Signature := ok (Signature.ofSchema reserved s) "signature"

def lines (text : String) : List String := text.splitOn "\n"

/-- Save a module through the checks and return it as the shim would read it back. -/
def saveTo (schema : Schema) (stored : List Stored) (name src : String) : IO (List Stored) := do
  let c ← ok (Store.check schema stored name src) s!"save {name}"
  let version := ((stored.find? (·.name == name)).map (·.version)).getD 0 + 1
  return { name, version, source := src, derived := c.derived.toJson.compress } ::
    stored.filter (·.name != name)

def sessionOf (schema : Schema) (stored : List Stored) (name : String) (maxFacts := 1000000) :
    IO Session := do
  let (s, _) ← ok (prepare {} schema stored name maxFacts) "prepare"
  return s

/-- Run to the end: the solutions and whether the search was exhausted. -/
partial def runAll (r : Run) : IO (Array (Array (String × String)) × Bool) :=
  go r #[]
where
  go (r : Run) (acc : Array (Array (String × String))) : IO (Array (Array (String × String)) × Bool) :=
    match step r with
    | .solution bs r' => go r' (acc.push bs)
    | .paused r' => go r' acc
    | .done ex => pure (acc, ex)
    | .error e => throw (IO.userError e)

def query (s : Session) (goal : String) (fuel := 1000000) (slice := 1000) (maxSol := 1000000) :
    IO (Array (Array (String × String)) × Bool) := do
  runAll (← ok (start s goal fuel slice maxSol) "goal")

def int (i : Int) : Value := .int i
def str (s : String) : Value := .str s

/-- Persons 1 and 2 (2 has no name), 7 knows 2 twice. -/
def loadPeople (s : Session) : IO Session := do
  let idx := s.scans.toList.findIdx? fun sc => sc.table == "Person"
  let some i := idx | return s
  let .node ns := s.scans[i]! | fail "Person is a node table"
  let cols := ns.props.map fun p => match p.name with
    | "name" => #[str "ann", .null]
    | "age" => #[int 30, int 40]
    | "born" => #[int 10, int 20]
    | "balance" => #[int 18446744073709551615, int 0]
    | _ => #[.null, .null]
  ok (addBatch s i (#[#[int 1, int 2]] ++ cols.toArray)) "person batch"

/-! ### Schema model -/

-- @tg: verifies:: [[openspec:schema-encoding#Schema model from the catalog#Node and rel tables are read]] {level: unit}
def tablesAreRead : IO Unit := do
  let s ← org
  let some p := s.nodes.find? (·.name == "Person") | fail "Person"
  check (p.key == { name := "id", ty := .int "INT64" }) "key id: INT64"
  check (p.props.take 2 == [{ name := "name", ty := .string }, { name := "age", ty := .int "INT64" }]) "name, age"
  let some k := s.rels.find? (·.name == "Knows") | fail "Knows"
  check (k.pairs == [("Person", "Person")] && k.props == [{ name := "since", ty := .int "INT64" }]) "Knows"

/-! ### Naming -/

-- @tg: verifies:: [[openspec:schema-encoding#Injective naming#Snake-case mapping]] {level: unit}
def snakeCase : IO Unit := do
  check (snake "ReportsTo" == "reports_to") (snake "ReportsTo")
  check (snake "firstName" == "first_name") (snake "firstName")
  check (snake "HTTPServer" == "http_server") (snake "HTTPServer")
  check ((Origin.prop "Person" "firstName").ident == "person.first_name") "property identifier"

-- @tg: verifies:: [[openspec:schema-encoding#Injective naming#Collision is an error]] {level: unit}
def collision : IO Unit := do
  let s : Schema := { nodes := [
    { name := "ReportsTo", key := { name := "id", ty := .int "INT64" }, props := [] },
    { name := "Reports_To", key := { name := "id", ty := .int "INT64" }, props := [] }] }
  match Signature.ofSchema reserved s with
  | .ok _ => fail "the clash must fail"
  | .error e =>
    let m := toString e
    check (contains m "ReportsTo" && contains m "Reports_To" && contains m "reports_to") m
  -- a keyword is refused too
  let k : Schema := { nodes := [{ name := "Pred", key := { name := "id", ty := .int "INT64" }, props := [] }] }
  check (Signature.ofSchema reserved k |>.toOption |>.isNone) "pred is a keyword"

/-! ### Node and rel tables -/

-- @tg: verifies:: [[openspec:schema-encoding#Node table encoding#Generated node declarations]] {level: unit}
def nodeDeclarations : IO Unit := do
  let sig ← sigOf (← org)
  let some t := sig.table? "Person" | fail "Person declarations"
  for l in ["kind person type.", "type person int -> person.", "pred person o:person.",
            "pred person.name o:person, o:string.", "pred person.age o:person, o:int."] do
    check ((lines t).contains l) s!"missing: {l}"
  -- the predicate comes before the constructor, so LeanElpi overloads instead of replacing
  check ((lines t).idxOf "pred person o:person." < (lines t).idxOf "type person int -> person.") "pred first"

-- @tg: verifies:: [[openspec:schema-encoding#Node table encoding#Null is an absent fact]] {level: unit}
def nullIsAbsent : IO Unit := do
  let schema ← org
  let stored ← saveTo schema [] "people" "pred named o:person.\nnamed P :- person.name P _.\n"
  let s ← loadPeople (← sessionOf schema stored "people")
  let (sols, _) ← query s "person.name P N"
  check (sols.size == 1) s!"one name fact, got {sols.size}"
  check (sols[0]! == #[("P", "[\"app\",\"person\",[[\"int\",1]]]"), ("N", "[\"str\",\"ann\"]")]) s!"{sols[0]!}"

-- @tg: verifies:: [[openspec:schema-encoding#Rel table encoding#Single-pair rel]] {level: unit}
def singlePairRel : IO Unit := do
  let sig ← sigOf (← org)
  let some t := sig.table? "Knows" | fail "Knows declarations"
  for l in ["kind knows type.", "pred knows o:person, o:knows, o:person.", "pred knows.since o:knows, o:int."] do
    check ((lines t).contains l) s!"missing: {l}"

-- @tg: verifies:: [[openspec:schema-encoding#Rel table encoding#Multi-pair rel]] {level: unit}
def multiPairRel : IO Unit := do
  let sig ← sigOf (← org)
  let some t := sig.table? "Owns" | fail "Owns declarations"
  for l in ["kind owns.src type.", "type owns.src.person person -> owns.src.",
            "type owns.src.company company -> owns.src.", "pred owns o:owns.src, o:owns, o:owns.dst."] do
    check ((lines t).contains l) s!"missing: {l}"
  -- the whole signature compiles
  discard <| ok (Engine.compile [(signatureUnit, sig.text)]) "signature compiles"

-- @tg: verifies:: [[openspec:schema-encoding#Rel table encoding#Parallel edges stay distinct]] {level: unit}
def parallelEdges : IO Unit := do
  let schema ← org
  let stored ← saveTo schema [] "k" "pred kn o:person, o:person.\nkn A B :- knows A _ B.\n"
  let s ← sessionOf schema stored "k"
  let some i := s.scans.toList.findIdx? (·.table == "Knows") | fail "Knows is scanned"
  let p := #[str "Person", str "Person"]
  let s ← ok (addBatch s i #[p, #[int 7, int 7], #[int 100, int 101], p, #[int 2, int 2]]) "knows batch"
  let (sols, _) ← query s "knows A E B"
  check (sols.size == 2) s!"two facts, got {sols.size}"
  check ((sols.map (·[1]!.2)).toList.eraseDups.length == 2) "different edge terms"

/-! ### Property types -/

-- @tg: verifies:: [[openspec:schema-encoding#Property type mapping#Temporal values as epoch integers]] {level: unit}
def temporal : IO Unit := do
  let schema ← org
  let stored ← saveTo schema [] "b" "pred b o:person, o:int.\nb P D :- person.born P D.\n"
  let s ← loadPeople (← sessionOf schema stored "b")
  let (sols, _) ← query s "person.born (person 1) D"
  check (sols == #[#[("D", "[\"int\",10]")]]) s!"{sols}"

-- @tg: verifies:: [[openspec:schema-encoding#Property type mapping#Unsupported type is skipped with a warning]] {level: unit}
def unsupportedType : IO Unit := do
  let sig ← sigOf (← org)
  check (!contains sig.text "person.tags") "no predicate for tags"
  check (sig.warnings.any fun w => contains w "Person" && contains w "tags" && contains w "MAP(STRING, INT64)")
    s!"warning: {sig.warnings}"
  let c ← ok (Store.check (← org) [] "m" "pred x o:int.\nx 1.\n") "save"
  check (c.warnings.any (contains · "tags")) "elpi_save reports the warning"

-- @tg: verifies:: [[openspec:schema-encoding#Property type mapping#Large integers keep their value]] {level: unit}
def largeIntegers : IO Unit := do
  let schema ← org
  let stored ← saveTo schema [] "m" "pred bal o:person, o:int.\nbal P B :- person.balance P B.\n"
  let s ← loadPeople (← sessionOf schema stored "m")
  let (sols, _) ← query s "person.balance (person 1) B"
  check (sols == #[#[("B", "[\"int\",18446744073709551615]")]]) s!"{sols}"

-- @tg: verifies:: [[openspec:schema-encoding#System tables are invisible to rules#Module cannot read its own storage]] {level: unit}
def systemInvisible : IO Unit := do
  let schema ← org
  check (!contains (← sigOf schema).text "_elpi") "no system identifier in the signature"
  -- `_elpi_module.source` is a variable in ELPI, never a generated constant
  let st ← saveTo schema [] "spy" "pred s o:string.\ns X :- _elpi_module.source _ X.\n"
  let s ← sessionOf schema st "spy"
  check (s.scans.all fun sc => !isSystem sc.table) "no system table is scanned"

/-! ### Schema hash -/

-- @tg: verifies:: [[openspec:schema-encoding#Canonical schema hash#Order does not matter]] {level: unit}
def orderDoesNotMatter : IO Unit := do
  let s ← org
  let t : Schema := { nodes := s.nodes.reverse.map fun n => { n with props := n.props.reverse },
                      rels := s.rels.reverse }
  check (Schema.hash s == Schema.hash t) "same hash in another order"

-- @tg: verifies:: [[openspec:schema-encoding#Canonical schema hash#Type change changes the hash]] {level: unit}
def typeChangeChangesHash : IO Unit := do
  let s ← org
  let t : Schema := { s with nodes := s.nodes.map fun n =>
    { n with props := n.props.map fun p => if p.name == "age" then { p with ty := .float "DOUBLE" } else p } }
  check (Schema.hash s != Schema.hash t) "the hash differs"

/-! ### Codec -/

-- @tg: verifies:: [[openspec:schema-encoding#Value codec round-trip#Every supported type round-trips]] {level: unit}
def codecRoundTrip : IO Unit := do
  let rec_ := ETy.record "t.p.rec" [.int, .list .string, .record "t.p.q.rec" [.bool, .float]]
  let cases : List (ETy × Value) :=
    [(.int, int (-5)), (.int, int 18446744073709551615), (.float, .float (2.5 : Float).toBits),
     (.string, str "λ \"q\""), (.bool, .bool true), (.bool, .bool false),
     (.list (.list .int), .list [.list [int 1], .list []]),
     (rec_, .struct [int 1, .list [str "a"], .struct [.bool false, .float (0.1 : Float).toBits]]),
     (.record "e.rec" [], .struct [])]
  for (ty, v) in cases do
    check (Codec.decode ty (Codec.encode ty v) == some v) s!"{repr v} round-trips"
  check (Codec.encodeChecked (.list .int) (.list [.null]) |>.toOption |>.isNone) "a NULL inside a list is refused"

/-! ### Signature inspection -/

-- @tg: verifies:: [[openspec:schema-encoding#Signature inspection#Show one table]] {level: unit}
def showOneTable : IO Unit := do
  let sig ← sigOf (← org)
  let some t := sig.table? "Person" | fail "Person"
  check (contains t "person.name" && !contains t "knows" && !contains t "event") t

/-! ### Rule storage -/

-- @tg: verifies:: [[openspec:rule-storage#Save checks before storing#Ill-typed module is rejected]] {level: unit}
def illTyped : IO Unit := do
  match Store.check (← org) [] "org-rules" "pred v o:person.\nv P :- person.nme P N.\n" with
  | .ok _ => fail "the module must be rejected"
  | .error e => check (contains e "org-rules:2:") s!"located in the module: {e}"

-- @tg: verifies:: [[openspec:rule-storage#Source is stored byte for byte#Hostile characters survive]] {level: unit}
def hostileCharacters : IO Unit := do
  let src := "% \"q\" 'a' \\ \\n $$ \t λ\npred x o:int.\nx 1.\n"
  check (Literal.unescape (Literal.escape src) == some src) "round trip"
  let c ← ok (Store.check (← org) [] "h" src) "save"
  check (contains c.statement (Literal.quote src)) "the statement embeds the escaped source"

-- @tg: verifies:: [[openspec:rule-storage#Source is stored byte for byte#Source cannot escape its literal]] {level: unit}
def cannotEscape : IO Unit := do
  let src := "% '}) DETACH DELETE (n) //\npred x o:int.\nx 1.\n"
  check (!Literal.hasBareDelimiter (Literal.escape src).toList) "no bare quote"
  let c ← ok (Store.check (← org) [] "e" src) "save"
  check (contains c.statement "\\'}) DETACH") "the quote is escaped"
  check (!contains (c.statement.replace "\\'" "") "'}) DETACH") "no bare quote before the payload"

-- @tg: verifies:: [[openspec:rule-storage#Derived module metadata#Called generated predicates are listed]] {level: unit}
def derivedMetadata : IO Unit := do
  let schema : Schema ← ok (Schema.parse "{\"nodes\": [{\"name\": \"Person\", \"key\": \"id\", \"properties\": [
      {\"name\": \"id\", \"type\": \"INT64\"}, {\"name\": \"name\", \"type\": \"STRING\"}]}],
    \"rels\": [{\"name\": \"ReportsTo\", \"pairs\": [[\"Person\", \"Person\"]], \"properties\": []}]}") "schema"
  let c ← ok (Store.check schema [] "org" "pred violation o:person.\nviolation P :- person.name P _, not (reports_to P _ _).\n") "save"
  check (c.derived.callsGenerated == ["person.name", "reports_to"]) s!"{c.derived.callsGenerated}"
  check (c.derived.defines == ["violation"] && c.derived.entries == ["violation"]) s!"{repr c.derived}"

-- @tg: verifies:: [[openspec:rule-storage#Accumulate dependencies#Missing dependency]] {level: unit}
def missingDependency : IO Unit := do
  match Store.check (← org) [] "org-rules" "accumulate graph-base.\npred x o:int.\n" with
  | .ok _ => fail "must fail"
  | .error e => check (contains e "graph-base") e

-- @tg: verifies:: [[openspec:rule-storage#Accumulate dependencies#Cycle is rejected]] {level: unit}
def cycleRejected : IO Unit := do
  let schema ← org
  let st ← saveTo schema [] "b" "pred pb o:int.\npb 1.\n"
  let st ← saveTo schema st "a" "accumulate b.\npred pa o:int.\npa 1.\n"
  match Store.check schema st "b" "accumulate a.\npred pb o:int.\npb 1.\n" with
  | .ok _ => fail "the cycle must fail"
  | .error e => check (contains e "b → a → b") e

-- @tg: verifies:: [[openspec:rule-storage#Drop protects dependents#Dependent blocks drop]] {level: unit}
def dropProtects : IO Unit := do
  let schema ← org
  let st ← saveTo schema [] "graph-base" "pred e o:int.\ne 1.\n"
  let st ← saveTo schema st "org-rules" "accumulate graph-base.\npred x o:int.\nx N :- e N.\n"
  match Store.drop st "graph-base" with
  | .ok _ => fail "drop must fail"
  | .error e => check (contains e "org-rules") e
  discard <| ok (Store.drop st "org-rules") "a module nothing accumulates can be dropped"

-- @tg: verifies:: [[openspec:rule-storage#Export and import#Round trip through a bundle]] {level: unit}
def bundleRoundTrip : IO Unit := do
  let schema ← org
  let st ← saveTo schema [] "graph-base" "pred e o:int.\ne 1.\n"
  let st ← saveTo schema st "org-rules" "accumulate graph-base.\npred x o:int.\nx N :- e N.\n"
  let rows ← ok (Store.exportOrder st) "export"
  check (rows.map (·.name) == ["graph-base", "org-rules"]) "dependencies first"
  let bundle := Lean.Json.arr (rows.reverse.map fun r =>
    Lean.Json.mkObj [("name", .str r.name), ("source", .str r.source)]).toArray
  let (stmts, _) ← ok (Store.importBundle schema [] bundle.compress) "import"
  check (stmts.length == 3) "two saves and a summary"
  check (contains stmts[0]! (Literal.quote "pred e o:int.\ne 1.\n")) "graph-base is saved first, byte for byte"

-- @tg: verifies:: [[openspec:rule-storage#Export and import#One bad module aborts the import]] {level: unit}
def badImport : IO Unit := do
  let bundle := "[{\"name\": \"a\", \"source\": \"pred a o:int.\\na 1.\\n\"},
                  {\"name\": \"b\", \"source\": \"pred b o:int.\\nb \\\"x\\\".\\n\"},
                  {\"name\": \"c\", \"source\": \"pred c o:int.\\nc 1.\\n\"}]"
  match Store.importBundle (← org) [] bundle with
  | .ok _ => fail "the import must fail"
  | .error e => check (contains e "module b") e

-- @tg: verifies:: [[openspec:rule-storage#Compiled handle cache#Second run reuses the program]] {level: unit}
def cacheReuse : IO Unit := do
  let schema ← org
  let st ← saveTo schema [] "m" "pred x o:int.\nx 1.\n"
  let (_, c1) ← ok (prepare {} schema st "m" 100) "first run"
  let (_, c2) ← ok (prepare c1 schema st "m" 100) "second run"
  check (c1.misses == 1 && c2.misses == 1) s!"one compile: {c2.misses}"

-- @tg: verifies:: [[openspec:rule-storage#Compiled handle cache#New version is a new entry]] {level: unit}
def cacheNewVersion : IO Unit := do
  let schema ← org
  let st ← saveTo schema [] "m" "pred x o:int.\nx 1.\n"
  let (_, c1) ← ok (prepare {} schema st "m" 100) "first run"
  let st ← saveTo schema st "m" "pred x o:int.\nx 2.\n"
  let (s, c2) ← ok (prepare c1 schema st "m" 100) "after the save"
  check (c2.misses == 2) "the new version compiles"
  let (sols, _) ← query s "x N"
  check (sols == #[#[("N", "[\"int\",2]")]]) s!"uses the new version: {sols}"
  -- another database (or a drop and a new save) may have a module of the same name and version
  let other : List Stored := [{ name := "m", version := 1, source := "pred x o:int.\nx 9.\n",
                                derived := (st.find? (·.name == "m")).get!.derived }]
  let (s, c3) ← ok (prepare c2 schema other "m" 100) "same version, other source"
  check (c3.misses == 3) "a different source is a different entry"
  let (sols, _) ← query s "x N"
  check (sols == #[#[("N", "[\"int\",9]")]]) s!"uses its own source: {sols}"

/-! ### Rule execution -/

-- @tg: verifies:: [[openspec:rule-execution#Full-scope materialization#Unused tables are not loaded]] {level: unit}
def unusedTables : IO Unit := do
  let schema ← org
  let st ← saveTo schema [] "m" "pred n o:string.\nn N :- person.name _ N.\n"
  let s ← sessionOf schema st "m"
  check (s.scans.map Scan.describe == #[#["node", "Person", "name"]]) s!"{s.scans.map Scan.describe}"

-- @tg: verifies:: [[openspec:rule-execution#Untyped debug query#Bindings as rows]] {level: unit}
def bindingsAsRows : IO Unit := do
  let schema ← org
  let st ← saveTo schema [] "people" "pred named o:person.\nnamed P :- person.name P _.\n"
  let s ← sessionOf schema st "people"
  let s ← ok (addBatch s 0 #[#[int 1, int 2], #[str "ann", str "bob"]]) "batch"
  let (sols, ex) ← query s "person.name P N"
  check (sols.size == 2 && sols.all (·.map (·.1) == #["P", "N"]) && ex) s!"{sols} {ex}"

-- @tg: verifies:: [[openspec:rule-execution#Untyped debug query#Goal with a syntax error]] {level: unit}
def goalSyntaxError : IO Unit := do
  let schema ← org
  let st ← saveTo schema [] "m" "pred x o:int.\nx 1.\n"
  let s ← sessionOf schema st "m"
  match start s "x N,, x M" 1000 100 10 with
  | .ok _ => fail "must fail"
  | .error e => check (contains e "column 4") e

-- @tg: verifies:: [[openspec:rule-execution#Fuel-sliced execution#Slicing does not change answers]] {level: unit}
def slicingSameAnswers : IO Unit := do
  let schema ← org
  let st ← saveTo schema [] "m" "pred n o:int.\nn X :- std.iota 300 L, std.mem L X, 0 is X mod 7.\n"
  let s ← sessionOf schema st "m"
  let a ← query s "n X" (slice := 100)
  let b ← query s "n X" (slice := 1000000)
  check (a == b && a.1.size == 43) s!"{a.1.size} vs {b.1.size}"

-- @tg: verifies:: [[openspec:rule-execution#Execution limits are errors#Fuel exhaustion is an error]] {level: unit}
def fuelExhaustion : IO Unit := do
  let schema ← org
  let st ← saveTo schema [] "m" "pred loop.\nloop :- loop.\n"
  let s ← sessionOf schema st "m"
  try
    discard <| query s "loop" (fuel := 5000) (slice := 100)
    fail "must fail"
  catch e => check (contains (toString e) "elpi_fuel") (toString e)

-- @tg: verifies:: [[openspec:rule-execution#Execution limits are errors#Fact budget is checked before solving]] {level: unit}
def factBudget : IO Unit := do
  let schema ← org
  let st ← saveTo schema [] "m" "pred n o:string.\nn N :- person.name _ N.\n"
  let s ← sessionOf schema st "m" (maxFacts := 1)
  match addBatch s 0 #[#[int 1, int 2], #[str "a", str "b"]] with
  | .ok _ => fail "must fail"
  | .error e => check (contains e "elpi_max_facts" && contains e "Person") e

-- @tg: verifies:: [[openspec:rule-execution#Execution limits are errors#Solution limit is reported]] {level: unit}
def solutionLimit : IO Unit := do
  let schema ← org
  let st ← saveTo schema [] "m" "pred x o:int.\nx 1.\nx 2.\nx 3.\n"
  let s ← sessionOf schema st "m"
  let (sols, ex) ← query s "x N" (maxSol := 1)
  check (sols.size == 1 && !ex) s!"{sols.size} {ex}"

def all : List (String × IO Unit) :=
  [("tables are read", tablesAreRead), ("snake case", snakeCase), ("collision", collision),
   ("node declarations", nodeDeclarations), ("null is absent", nullIsAbsent),
   ("single-pair rel", singlePairRel), ("multi-pair rel", multiPairRel),
   ("parallel edges", parallelEdges), ("temporal", temporal), ("unsupported type", unsupportedType),
   ("large integers", largeIntegers), ("system tables invisible", systemInvisible),
   ("order does not matter", orderDoesNotMatter), ("type change changes hash", typeChangeChangesHash),
   ("codec round trip", codecRoundTrip), ("show one table", showOneTable),
   ("ill-typed module", illTyped), ("hostile characters", hostileCharacters),
   ("cannot escape literal", cannotEscape), ("derived metadata", derivedMetadata),
   ("missing dependency", missingDependency), ("cycle", cycleRejected), ("drop protects", dropProtects),
   ("bundle round trip", bundleRoundTrip), ("bad import", badImport), ("cache reuse", cacheReuse),
   ("cache new version", cacheNewVersion), ("unused tables", unusedTables),
   ("bindings as rows", bindingsAsRows), ("goal syntax error", goalSyntaxError),
   ("slicing same answers", slicingSameAnswers), ("fuel exhaustion", fuelExhaustion),
   ("fact budget", factBudget), ("solution limit", solutionLimit)]

end M1
