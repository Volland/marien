import M1
import Marien.Offline.Codegen
import Marien.Statement

/-!
# M5 unit tests: offline codegen

The schema dump, the Lean module `marien-codegen` emits for it, and the check that the ELPI
declarations `deriving Elpi` produces equal the runtime signature. Modules are elaborated in
process, in a fresh environment built from `import Elpi` (the test driver sets the search path).
Dumps written by a real LadybugDB are integration tests (`tests/integration/`, and
`tests/offline/run.sh` runs the tool on them).
-/

open Marien Marien.Encoding Marien.Offline
open M1 (check fail ok contains)

namespace M5

/-- A dump of the schema `s`. -/
def dumpOf (s : Schema) : String := Dump.ofSchema s

def prop (n : String) (t : LType) : Property := { name := n, ty := t }

/-- Node, rel, multi-pair rel and STRUCT columns, a STRUCT key, nested lists and a self rel. -/
def rich : Schema :=
  { nodes := [
      { name := "Person", key := prop "id" (.int "INT64"),
        props := [prop "name" .string, prop "tags" (.list .string), prop "born" .date,
                  prop "addr" (.struct [("city", .string), ("geo", .struct [("lat", .float "DOUBLE"), ("lon", .float "DOUBLE")])]),
                  prop "m" (.other "MAP(STRING, INT64)")] },
      { name := "Org", key := prop "code" .string, props := [prop "active" .bool, prop "scores" (.list (.list (.int "INT32")))] },
      { name := "Pt", key := prop "k" (.struct [("x", .int "INT64"), ("y", .int "INT64")]), props := [] },
      { name := "_elpi_module", key := prop "name" .string, props := [] }],
    rels := [
      { name := "ReportsTo", pairs := [("Person", "Person")], props := [prop "since" .timestamp] },
      { name := "Owns", pairs := [("Person", "Org"), ("Org", "Org"), ("Person", "Pt")],
        props := [prop "share" (.float "FLOAT"), prop "meta" (.struct [("k", .string)])] }],
    annots := [{ table := "ReportsTo", key := "acyclic", value := "true" }] }

def runOk (s : Schema) (what : String) : IO Output := do
  match ← Offline.run {} (dumpOf s) with
  | .ok o => pure o
  | .error e => fail s!"{what}: {e}"

/-! ### Schema dump -/

def dumpRoundTrip : IO Unit := do
  let d := dumpOf rich
  let s ← ok (Dump.parse d) "dump parses"
  check (dumpOf s == d) s!"the parsed dump dumps to the same text:\n{d}\n{dumpOf s}"
  check (!contains d "_elpi") s!"no system tables: {d}"
  check (Schema.hash s == Schema.hash rich) "the dump keeps the schema hash"
  check (contains d "\"struct\":[[\"city\",\"STRING\"],[\"geo\"") s!"STRUCT fields keep their order: {d}"

def dumpPermuted : IO Unit := do
  let r := { rich with nodes := rich.nodes.reverse, rels := rich.rels.reverse }
  check (dumpOf r == dumpOf rich) "tables in another order give the same dump"
  let p := { rich with nodes := rich.nodes.map fun n => { n with props := n.props.reverse } }
  check (dumpOf p == dumpOf rich) "properties in another order give the same dump"

def dumpFormat : IO Unit := do
  match Dump.parse "{\"nodes\": [], \"rels\": []}" with
  | .ok _ => fail "a catalog without the format tag is not a dump"
  | .error e => check (contains e "format") e

/-! ### Lean inductives -/

-- @tg: verifies:: [[openspec:offline-codegen#Lean inductives from the schema#Generated module builds]] {level: unit}
def generatedBuilds : IO Unit := do
  let o ← runOk rich "rich schema"
  for k in ["inductive «person» where", "| «person» : Int → «person»", "inductive «owns.src» where",
            "| «owns.dst.pt» : «pt» → «owns.dst»", "| «pt» : «pt.k.rec» → «pt»",
            "| «person.addr.rec» : String → «person.addr.geo.rec» → «person.addr.rec»",
            "inductive «subject» where", "| «error» : «severity»"] do
    check (contains o.module k) s!"module declares {k}:\n{o.module}"
  check (!contains o.module "_elpi") "no system tables"
  check (contains o.derived "kind owns.dst type.") s!"derived: {o.derived}"

/-- A stored validation module, unedited, against the emitted program. -/
-- @tg: verifies:: [[openspec:offline-codegen#Lean inductives from the schema#Derived ELPI types match the runtime kinds]] {level: unit}
def ruleTypechecks : IO Unit := do
  let o ← runOk rich "rich schema"
  let rule := "pred violation o:severity, o:string, o:subject.
violation error \"no-manager\" (subj_person P) :- person P, not (reports_to P _ _).
violation warning \"far\" (subj_person P) :- person.addr P (person.addr.rec _ (person.addr.geo.rec La _)), La > 80.0.
violation info \"owns\" (subj_owns E) :- owns (owns.src.person _) E (owns.dst.pt (pt (pt.k.rec 0 0))).
violation error \"tags\" (subj_org O) :- org.scores O [[1]], org.active O tt."
  let text := o.module ++ s!"\nelpi_accumulate Schema.signature lp%\{\n{rule}\n}%\n"
  match ← elaborate text with
  | .ok _ => pure ()
  | .error e => fail s!"the stored rule does not typecheck against the module: {e}"
  -- and an ill-typed one is rejected, so the check is not vacuous
  let bad := o.module ++ "\nelpi_accumulate Schema.signature lp%{\npred bad o:person.\nbad (person \"x\").\n}%\n"
  match ← elaborate bad with
  | .ok _ => fail "an ill-typed rule typechecks"
  | .error e => check (contains e "string") e

/-! ### Agreement -/

/-- A small deterministic generator (64-bit LCG). -/
structure Rng where
  s : UInt64

def Rng.next (r : Rng) (n : Nat) : Nat × Rng :=
  let s := r.s * 6364136223846793005 + 1442695040888963407
  ((s >>> 33).toNat % n, ⟨s⟩)

/-- Every supported property type, nested lists and STRUCTs to depth 2, and an unsupported one. -/
partial def genType (depth : Nat) (r : Rng) : LType × Rng :=
  let (k, r) := r.next (if depth == 0 then 12 else 14)
  match k with
  | 0 => (.int "INT64", r) | 1 => (.int "INT32", r) | 2 => (.int "UINT64", r) | 3 => (.int "INT128", r)
  | 4 => (.float "DOUBLE", r) | 5 => (.float "FLOAT", r) | 6 => (.string, r) | 7 => (.bool, r)
  | 8 => (.date, r) | 9 => (.timestamp, r) | 10 => (.other "MAP(STRING, INT64)", r) | 11 => (.int "SERIAL", r)
  | 12 => let (t, r) := genType (depth - 1) r; (.list t, r)
  | _ =>
    let (n, r) := r.next 3
    let (fs, r) := (List.range (n + 1)).foldl (fun (acc, r) i =>
      let (t, r) := genType (depth - 1) r
      (acc ++ [(s!"f{i}", t)], r)) ([], r)
    (.struct fs, r)

def genSchema (seed : Nat) : Schema := Id.run do
  let mut r : Rng := ⟨seed.toUInt64 * 2654435761 + 1⟩
  let (nn, r1) := r.next 3; r := r1
  let mut nodes : List NodeTable := []
  for i in [0:nn + 1] do
    let (kt, r1) := genType 1 r; r := r1
    let (np, r1) := r.next 4; r := r1
    let mut props : List Property := []
    for j in [0:np] do
      let (t, r1) := genType 2 r; r := r1
      props := props ++ [prop s!"p{j}" t]
    nodes := nodes ++ [{ name := s!"N{i}", key := prop "id" kt, props }]
  let names := nodes.map (·.name)
  let (nr, r1) := r.next 4; r := r1
  let mut rels : List RelTable := []
  for i in [0:nr] do
    let (npairs, r1) := r.next 3; r := r1
    let mut pairs : List (String × String) := []
    for _ in [0:npairs + 1] do
      let (a, r1) := r.next names.length; r := r1
      let (b, r1) := r.next names.length; r := r1
      pairs := (pairs ++ [(names[a]!, names[b]!)]).eraseDups
    let (np, r1) := r.next 3; r := r1
    let mut props : List Property := []
    for j in [0:np] do
      let (t, r1) := genType 2 r; r := r1
      props := props ++ [prop s!"q{j}" t]
    rels := rels ++ [{ name := s!"R{i}", pairs, props }]
  return { nodes, rels }

-- @tg: verifies:: [[openspec:offline-codegen#Offline and runtime signatures agree#Agreement on random schemas]] {level: unit}
def randomAgreement : IO Unit := do
  let mut tried := 0
  for seed in [0:24] do
    let s := genSchema seed
    -- a key whose type Marien does not map leaves its table out; the schema may still encode
    if (Signature.ofSchema (Engine.reservedNames.contains ·) s).toOption.map (·.plan.nodes.isEmpty) != some false then
      continue
    tried := tried + 1
    let _ ← runOk s s!"seed {seed}"
  check (tried ≥ 16) s!"only {tried} of 24 random schemas encode a table"

/-- A printer that swaps the arguments of the first constructor with two of different types. -/
def swappedPrinter (o : Options) (sig : Signature) (hash : String) : Except String String :=
  let swapped := Id.run do
    let mut done := false
    let mut out : List (String × List Decl) := []
    for (t, ds) in sig.decls do
      let mut ds' : List Decl := []
      for d in ds do
        match d with
        | .ctor cs [a, b] k =>
          if !done && !(a == b) then
            done := true
            ds' := ds' ++ [.ctor cs [b, a] k]
          else ds' := ds' ++ [d]
        | _ => ds' := ds' ++ [d]
      out := out ++ [(t, ds')]
    return { sig with decls := out }
  LeanPrinter.module o swapped hash

-- @tg: verifies:: [[openspec:offline-codegen#Offline and runtime signatures agree#Disagreement fails the tool]] {level: unit}
def disagreementFails : IO Unit := do
  match ← Offline.run {} (dumpOf rich) swappedPrinter with
  | .ok _ => fail "a printer with swapped constructor arguments passes the check"
  | .error e =>
    check (contains e "disagree" && contains e "kind person.addr.rec" && contains e "constructor person.addr.rec") e

def unprintable : IO Unit := do
  let s : Schema := { nodes := [{ name := "Rec", key := prop "id" (.int "INT64"), props := [] }] }
  match ← Offline.run {} (dumpOf s) with
  | .ok _ => fail "a constructor named rec is accepted"
  | .error e => check (contains e "rec" && contains e "rename") e
  match ← Offline.run {} (dumpOf {}) with
  | .ok _ => fail "an empty schema is accepted"
  | .error e => check (contains e "no tables") e

/-! ### Statements -/

open Marien.Statement in
def parsesTo (text : String) (want : Statement) : IO Unit :=
  match parse text with
  | .ok got => check (got == want) s!"{text}: parsed as {repr got}"
  | .error e => fail s!"{text}: {e}"

open Marien.Statement in
def statementsParse : IO Unit := do
  parsesTo "CREATE RULES org_rules AS $$pred n o:int. n 1.$$" (.createRules "org_rules" "pred n o:int. n 1." false)
  parsesTo "create or replace rules `org` as $$x.$$;" (.createRules "org" "x." true)
  parsesTo "DROP RULES org_rules" (.dropRules "org_rules")
  parsesTo "  CHECK RULES ;" .checkRules
  parsesTo "VALIDATE" (.validate [] none)
  parsesTo "VALIDATE org_rules, 'hr' MIN SEVERITY warning" (.validate ["org_rules", "hr"] (some "warning"))
  parsesTo "ANNOTATE ReportsTo SET acyclic = 'tr\\'ue'" (.annotate "ReportsTo" "acyclic" "tr'ue")
  check (desugar (.validate ["a"] (some "warning"))).rows "VALIDATE returns rows"
  check ((desugar (.createRules "q" "s 'x'." false)).cypher == "CALL elpi_save('q', 's \\'x\\'.')")
    (desugar (.createRules "q" "s 'x'." false)).cypher
  check ((desugar (.validate ["a", "b"] (some "info"))).cypher == "CALL elpi_validate(['a', 'b'], 'info') RETURN *")
    (desugar (.validate ["a", "b"] (some "info"))).cypher

-- @tg: verifies:: [[openspec:custom-statements#Statement source is not re-escaped#Tagged delimiter]] {level: unit}
open Marien.Statement in
def statementSource : IO Unit := do
  parsesTo "CREATE RULES q AS $r$m \"$$\".$r$" (.createRules "q" "m \"$$\"." false)
  -- quotes, backslashes and a lone $ are taken as written
  parsesTo "CREATE RULES q AS $$s \"a\\\"b\" 'c' $x.$$" (.createRules "q" "s \"a\\\"b\" 'c' $x." false)
  match parse "CREATE RULES q AS $$m \"$$\".$$" with
  | .ok s => fail s!"a $$ inside a $$ source ends it: {repr s}"
  | .error e => check (contains e "unexpected text") e

-- @tg: verifies:: [[openspec:custom-statements#Rule statements#Malformed statement]] {level: unit}
open Marien.Statement in
def statementsMalformed : IO Unit := do
  let bad (text reason : String) : IO Unit :=
    match parse text with
    | .ok s => fail s!"{text} parsed as {repr s}"
    | .error e => check (contains e reason) s!"{text}: {e}"
  bad "CREATE RULES AS $$x$$" "missing module name"
  bad "CREATE RULES q $$x$$" "expected AS"
  bad "CREATE RULES q AS $$x" "unterminated rule source"
  bad "VALIDATE MIN SEVERITY error" "needs module names"
  bad "ANNOTATE T SET k = v" "quoted string"
  bad "DROP RULES q extra" "unexpected text"
  check (!isMarien "CREATE USER alice" && !isMarien "MATCH (n) RETURN n" && !isMarien "CREATE NODE TABLE T(id INT64 PRIMARY KEY)")
    "other statements are left to LadybugDB"
  check (isMarien "create rules q as $$x$$" && isMarien "VALIDATE") "Marien statements are recognized"

def all : List (String × IO Unit) :=
  [("dump round trip", dumpRoundTrip), ("dump is canonical", dumpPermuted), ("dump format tag", dumpFormat),
   ("generated module builds", generatedBuilds), ("stored rule typechecks", ruleTypechecks),
   ("agreement on random schemas", randomAgreement), ("disagreement fails", disagreementFails),
   ("unprintable schemas", unprintable), ("statements parse", statementsParse),
   ("statement source byte for byte", statementSource), ("malformed statements", statementsMalformed)]

end M5
