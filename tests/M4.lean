import M3

/-!
# M4 unit tests

Schema reflection, stage 1 meta-rules and the checks generated code goes through, dynamic entry
points, and the `graph.std` combinators: their answers on small relations, how the analysis
treats them, and the library's locality claims. Annotations written through LadybugDB, stored
generated text and partitioned runs over real graphs are integration tests in
`tests/integration/`.
-/

open Marien Marien.Encoding Marien.Store Marien.Exec Marien.Analysis Marien.Meta
open M1 (check fail ok contains)

namespace M4

/-! ### A schema with several relations -/

def nodeJson (name : String) (props : List (String × String)) : String :=
  "{\"name\": \"" ++ name ++ "\", \"key\": \"" ++ (props.headD ("id", "")).1 ++ "\", \"properties\": [" ++
    ", ".intercalate (props.map fun (n, t) => "{\"name\": \"" ++ n ++ "\", \"type\": \"" ++ t ++ "\"}") ++ "]}"

def relJson (name : String) (pairs : List (String × String)) : String :=
  "{\"name\": \"" ++ name ++ "\", \"pairs\": [" ++
    ", ".intercalate (pairs.map fun (a, b) => "[\"" ++ a ++ "\", \"" ++ b ++ "\"]") ++ "], \"properties\": []}"

/-- People, parts, cars and companies, five rel tables (`Owns` with two pairs) and Marien's
own tables; `annots` are rows of `_elpi_annotation`, `reverse` lists everything backwards. -/
def graphJson (annots : List (String × String × String) := []) (reverse := false) : String :=
  let rev {α} (l : List α) : List α := if reverse then l.reverse else l
  let nodes := rev [nodeJson "Person" [("id", "INT64"), ("name", "STRING")], nodeJson "Part" [("id", "INT64")],
    nodeJson "Car" [("id", "INT64")], nodeJson "Company" [("id", "INT64")],
    nodeJson "_elpi_module" [("name", "STRING")], nodeJson "_elpi_annotation" [("id", "STRING"), ("table_name", "STRING")]]
  let rels := rev [relJson "ReportsTo" [("Person", "Person")], relJson "PartOf" [("Part", "Part")],
    relJson "Knows" [("Person", "Person")], relJson "HasManager" [("Person", "Person")],
    relJson "Owns" [("Person", "Car"), ("Company", "Car")], relJson "_elpi_accumulates" [("_elpi_module", "_elpi_module")]]
  let anns := rev (annots.map fun (t, k, v) => "{\"table\": \"" ++ t ++ "\", \"key\": \"" ++ k ++ "\", \"value\": \"" ++ v ++ "\"}")
  "{\"nodes\": [" ++ ", ".intercalate nodes ++ "], \"rels\": [" ++ ", ".intercalate rels ++
    "], \"annotations\": [" ++ ", ".intercalate anns ++ "]}"

def schemaOf (annots : List (String × String × String) := []) (reverse := false) : IO Schema :=
  ok (Schema.parse (graphJson annots reverse)) "schema"

def acyclicAnn : List (String × String × String) := [("ReportsTo", "acyclic", "true"), ("PartOf", "acyclic", "true")]

/-- Save, keeping what the shim would read back: derived metadata, hash and generated text. -/
def saveTo (sc : Schema) (st : List Stored) (name src : String) : IO (List Stored) := do
  let c ← ok (Store.check sc st name src) s!"save {name}"
  let version := ((st.find? (·.name == name)).map (·.version)).getD 0 + 1
  return { name, version, source := src, derived := c.derived.toJson.compress, schemaHash := c.schemaHash
           generated := c.generated } :: st.filter (·.name != name)

def saveErr (sc : Schema) (st : List Stored) (name src : String) : IO String :=
  match Store.check sc st name src with
  | .ok _ => fail s!"saving {name} must fail"
  | .error e => pure e

def generatedOf (st : List Stored) (name : String) : IO String := do
  let some m := st.find? (·.name == name) | fail s!"no module {name}"
  return m.generated

def verdictOf (st : List Stored) (name pred : String) : IO EntryVerdict := do
  let some m := st.find? (·.name == name) | fail s!"no module {name}"
  let some v := (Derived.ofStored m).verdict? pred | fail s!"{name} has no verdict for {pred}"
  return v

def sigOf (sc : Schema) : IO Signature := ok (Signature.ofSchema (Engine.reservedNames.contains ·) sc) "signature"

def reflected (sc : Schema) : IO (List String) := do
  let sig ← sigOf sc
  return Reflect.ofSchema sc (isDbPred sig)

/-! ### Schema reflection -/

-- @tg: verifies:: [[openspec:schema-reflection#Reflected schema description#Node and rel tables are reflected]] {level: unit}
def nodeAndRel : IO Unit := do
  let r ← reflected (← schemaOf)
  for l in ["schema.node \"Person\".", "schema.rel \"ReportsTo\" \"Person\" \"Person\".",
            "schema.prop \"Person\" \"id\" ty_int.", "schema.prop \"Person\" \"name\" ty_string.",
            "schema.key \"Person\" \"id\".", "schema.ident \"ReportsTo\" \"reports_to\".",
            "schema.prop_ident \"Person\" \"name\" \"person.name\"."] do
    check (r.contains l) s!"missing {l} in {r}"

-- @tg: verifies:: [[openspec:schema-reflection#Reflected schema description#Multi-pair rel tables give one fact per pair]] {level: unit}
def multiPair : IO Unit := do
  let r ← reflected (← schemaOf)
  check (r.contains "schema.rel \"Owns\" \"Person\" \"Car\"." && r.contains "schema.rel \"Owns\" \"Company\" \"Car\".") s!"{r}"

-- @tg: verifies:: [[openspec:schema-reflection#Reflected schema description#Reflection typechecks without rigid-variable conflicts]] {level: unit}
def reflectionTypechecks : IO Unit := do
  let sc ← schemaOf acyclicAnn
  let sig ← sigOf sc
  let metaRules := "pred generate o:string.\npred tables o:list string.\n" ++
    "tables L :- std.findall (schema.rel N _ _) Gs, std.map Gs (g\\ n\\ g = schema.rel n _ _) L.\n" ++
    "generate S :- schema.rel N A B, S is N ^ \" \" ^ A ^ \" \" ^ B.\n"
  let g ← ok (Stage.generate (Reflect.text sc (isDbPred sig)) (isDbPred sig) "m" metaRules {}) "stage 1"
  check (contains g.text "PartOf Part Part" && contains g.text "ReportsTo Person Person") g.text

-- @tg: verifies:: [[openspec:schema-reflection#System tables are not reflected#Module storage stays invisible]] {level: unit}
def systemInvisible : IO Unit := do
  let r ← reflected (← schemaOf [("_elpi_module", "k", "v"), ("ReportsTo", "acyclic", "true")])
  check (!r.any (contains · "_elpi_")) s!"{r.filter (contains · "_elpi_")}"
  check (r.contains "schema.annot \"ReportsTo\" \"acyclic\" \"true\".") s!"{r}"

-- @tg: verifies:: [[openspec:schema-reflection#Schema annotations#Annotation appears in reflection]] {level: unit}
def annotationReflected : IO Unit := do
  let r ← reflected (← schemaOf [("ReportsTo", "acyclic", "true")])
  check (r.contains "schema.annot \"ReportsTo\" \"acyclic\" \"true\".") s!"{r}"
  -- and the statement elpi_annotate writes
  let stmts ← ok (Store.annotate (← schemaOf) "ReportsTo" "acyclic" "true") "annotate"
  check (stmts.any (contains · "MERGE (a:_elpi_annotation {id: 'ReportsTo/acyclic'})")) s!"{stmts}"
  let del ← ok (Store.annotate (← schemaOf) "ReportsTo" "acyclic" "") "remove"
  check (del.any (contains · "DELETE a")) s!"{del}"

-- @tg: verifies:: [[openspec:schema-reflection#Schema annotations#Annotating an unknown table fails]] {level: unit}
def annotateUnknown : IO Unit := do
  match Store.annotate (← schemaOf) "NoSuchTable" "acyclic" "true" with
  | .ok _ => fail "annotating NoSuchTable must fail"
  | .error e => check (contains e "NoSuchTable") e
  match Store.annotate (← schemaOf) "_elpi_module" "acyclic" "true" with
  | .ok _ => fail "annotating a system table must fail"
  | .error e => check (contains e "_elpi_module") e

/-! ### Stage 1 -/

/-- One `cycle` violation per table annotated `acyclic`. -/
def cyclesSrc : String :=
  "accumulate graph.std.
pred violation o:severity, o:string, o:subject.
% @marien meta
pred generate o:string.
generate S :- schema.annot T \"acyclic\" \"true\", schema.ident T R, schema.rel T K _, schema.ident K N,
  S is \"violation error \\\"cycle\\\" (subj_\" ^ N ^ \" X) :- acyclic_witness (edge_of \" ^ R ^ \") X.\".
% @marien end
"

-- @tg: verifies:: [[openspec:rule-generation#Stage one meta-rules#Per-table clauses from an annotation]] {level: unit}
def perTable : IO Unit := do
  let st ← saveTo (← schemaOf acyclicAnn) [] "cycles" cyclesSrc
  let g ← generatedOf st "cycles"
  check (contains g "edge_of reports_to" && contains g "edge_of part_of") g
  check (!contains g "knows" && !contains g "has_manager") g
  check (((g.splitOn "\n").filter (· ≠ "")).length == 2) g

-- @tg: verifies:: [[openspec:schema-reflection#Schema annotations#Annotation change triggers regeneration]] {level: unit, confidence: partial, note: "the hash changes and the lazy recheck regenerates; the integration test runs it"}
def annotationRegenerates : IO Unit := do
  let st ← saveTo (← schemaOf [("ReportsTo", "acyclic", "true")]) [] "cycles" cyclesSrc
  let m := (st.find? (·.name == "cycles")).get!
  let after ← schemaOf acyclicAnn
  check (runHash (Derived.ofStored m) after != m.schemaHash) "an annotation changes the hash"
  let r := recheckOne after st m
  check (r.oldStatus == "stale" && contains r.generated "part_of") s!"{repr r}"
  let _ ← ok (prepareValidate {} after st "cycles" 1000000 .info) "the run regenerates"

-- @tg: verifies:: [[openspec:rule-generation#Stage one meta-rules#Stage one sees no data]] {level: unit}
def noData : IO Unit := do
  let e ← saveErr (← schemaOf) [] "m" "pred violation o:severity, o:string, o:subject.
% @marien meta
pred generate o:string.
generate S :- person.name _ S.
% @marien end
"
  check (contains e "stage 1" && contains e "person.name is a database predicate") e

-- @tg: verifies:: [[openspec:rule-generation#Stage one meta-rules#Unparseable output fails the save]] {level: unit}
def unparseable : IO Unit := do
  let e ← saveErr (← schemaOf) [] "m" "pred violation o:severity, o:string, o:subject.
% @marien meta
pred generate o:string.
generate \"violation X :-\".
% @marien end
"
  check (contains e "m (generated):" && contains e "stage 1") e

def unclosedMeta : IO Unit := do
  let e ← saveErr (← schemaOf) [] "m" "% @marien meta\npred generate o:string.\n"
  check (contains e "never closed") e

/-! ### Generated code is checked like source -/

-- @tg: verifies:: [[openspec:rule-generation#Generated code is checked like source#Ill-typed generated clause is rejected]] {level: unit}
def illTyped : IO Unit := do
  let e ← saveErr (← schemaOf) [] "m" "pred violation o:severity, o:string, o:subject.
% @marien meta
pred generate o:string.
generate \"violation error \\\"c\\\" (subj_person P) :- reports_to P \\\"x\\\" Q.\".
% @marien end
"
  check (contains e "m (generated):1:") e

def undeclaredHead : IO Unit := do
  let e ← saveErr (← schemaOf) [] "m" "pred violation o:severity, o:string, o:subject.
% @marien meta
pred generate o:string.
generate \"sneaky 1.\".
% @marien end
"
  check (contains e "sneaky") e

-- @tg: verifies:: [[openspec:rule-generation#Generated code is checked like source#Generated negation affects narrowed scope]] {level: unit}
def generatedNegation : IO Unit := do
  let sc ← schemaOf
  let plain := "pred q o:person.\nq P :- person P.\n"
  let st ← saveTo sc [] "m" plain
  check (← verdictOf st "m" "q").monotone "q is monotone without generated code"
  let st ← saveTo sc [] "m" (plain ++ "% @marien meta
pred generate o:string.
generate \"q P :- person P, not (person.name P _).\".
% @marien end
")
  let v ← verdictOf st "m" "q"
  check (!v.monotone) s!"{repr v}"
  match prepareRun {} sc st "m" "q" [] 1000000 (narrowed := true) with
  | .ok _ => fail "a narrowed call of q must be refused"
  | .error e => check (contains e "not monotone") e

/-! ### Generated code depends only on schema and source -/

-- @tg: verifies:: [[openspec:rule-generation#Generated code depends only on schema and source#Regeneration is byte-identical]] {level: unit}
def byteIdentical : IO Unit := do
  let sc ← schemaOf acyclicAnn
  let st ← saveTo sc [] "cycles" cyclesSrc
  let g ← generatedOf st "cycles"
  let r := recheckOne sc st ((st.find? (·.name == "cycles")).get!)
  check (r.generated == g && r.oldStatus == "ok") s!"{repr r}"

-- @tg: verifies:: [[openspec:rule-generation#Generated code depends only on schema and source#Catalog order does not matter]] {level: unit}
def catalogOrder : IO Unit := do
  let a ← saveTo (← schemaOf acyclicAnn) [] "cycles" cyclesSrc
  let b ← saveTo (← schemaOf acyclicAnn (reverse := true)) [] "cycles" cyclesSrc
  check ((← generatedOf a "cycles") == (← generatedOf b "cycles")) "the same text in both orders"

/-! ### Dynamic entry points -/

-- @tg: verifies:: [[openspec:rule-generation#Dynamic entry points#Hypothetical database facts make an entry point dynamic]] {level: unit}
def hypotheticalDynamic : IO Unit := do
  let st ← saveTo (← schemaOf) [] "m" "pred what_if o:severity.
what_if S :- (reports_to (person 1) (reports_to 9) (person 2) => violation S _ _).
pred violation o:severity, o:string, o:subject.
violation error \"self\" (subj_person P) :- reports_to P _ P.
"
  let v ← verdictOf st "m" "what_if"
  check (v.dynamic && (v.dynamicGoal.getD "").length > 0 && contains v.whyNotMonotone "m:2:") s!"{repr v}"

-- @tg: verifies:: [[openspec:rule-generation#Dynamic entry points#Dynamic entry points are never partitioned]] {level: unit}
def dynamicNeverPartitioned : IO Unit := do
  -- generated code makes violation dynamic once Knows is annotated what_if
  let src := "pred violation o:severity, o:string, o:subject.
violation error \"self\" (subj_person P) :- person P, reports_to P _ P.
% @marien partition violation by person radius 1
% @marien meta
pred generate o:string.
generate \"violation error \\\"hyp\\\" (subj_person P) :- person P, (reports_to P (reports_to 0) P => reports_to P _ P).\" :-
  schema.annot \"Knows\" \"what_if\" \"true\".
% @marien end
"
  let st ← saveTo (← schemaOf) [] "m" src
  check (← verdictOf st "m" "violation").partition.isSome "partitioned before the annotation"
  match prepareValidate {} (← schemaOf [("Knows", "what_if", "true")]) st "m" 1000000 .info with
  | .ok _ => fail "a partitioned run of a dynamic violation must fail"
  | .error e => check (contains e "dynamic entry points run at full scope only") e

-- @tg: verifies:: [[openspec:rule-generation#Dynamic entry points#Local hypotheticals stay static]] {level: unit}
def localHypothetical : IO Unit := do
  let st ← saveTo (← schemaOf) [] "m" "pred flag o:person.
pred q o:person.
q P :- person P, (flag P => flag P).
"
  check (!(← verdictOf st "m" "q").dynamic) "a hypothetical of the module's own predicate is static"

/-! ### graph.std: answers -/

partial def render : Engine.ResultTerm → String
  | .app h as => "(" ++ " ".intercalate (h :: as.toList.map render) ++ ")"
  | .const c => c
  | .int i => toString i
  | .str s => s.quote
  | .list xs => "[" ++ ", ".intercalate (xs.toList.map render) ++ "]"
  | _ => "_"

partial def solutions (q : Engine.Query) (acc : Array String := #[]) : Except String (List String) :=
  match Engine.slice q 1000000 with
  | .solution bs _ q' => solutions q' (acc.push (" ".intercalate (bs.toList.map fun (v, t) => s!"{v}={render t}")))
  | .paused q' => solutions q' acc
  | .exhausted => .ok acc.toList
  | .error e => .error (toString e)

/-- The answers of `goal` over `facts` (clauses for generated predicates), with `graph.std`. -/
def answers (facts goal : String) (extra : String := "") : IO (List String) := do
  let sig ← sigOf (← schemaOf)
  let p ← ok (Engine.compile [(signatureUnit, sig.text), ("facts", facts), ("q", "accumulate graph.std.\n" ++ extra)]
    [(GraphStd.name, GraphStd.source)]) "compile"
  let q ← ok (Engine.parseGoal p goal 10000000) "goal"
  ok (solutions q) "solve"

def edges (rel : String) (kind : String) (es : List (Nat × Nat)) : String :=
  String.join (es.zipIdx.map fun ((a, b), i) => s!"{rel} ({kind} {a}) ({rel} {i}) ({kind} {b}).\n")

def people (ids : List Nat) : String := String.join (ids.map fun i => s!"person (person {i}).\n")

def sorted (l : List String) : List String := Schema.sortStrings l

-- @tg: verifies:: [[openspec:graph-std#Relation combinators#Closure over a relation]] {level: unit}
def closureOver : IO Unit := do
  let r ← answers (edges "reports_to" "person" [(1, 2), (2, 3)]) "closure (edge_of reports_to) (person 1) Y"
  check (sorted r == ["Y=(person 2)", "Y=(person 3)"]) s!"{r}"

-- @tg: verifies:: [[openspec:graph-std#Relation combinators#Closure terminates on cycles]] {level: unit}
def closureCycle : IO Unit := do
  let r ← answers (edges "reports_to" "person" [(1, 2), (2, 1)]) "closure (edge_of reports_to) (person 1) Y"
  check (sorted r == ["Y=(person 1)", "Y=(person 2)"]) s!"{r}"

-- @tg: verifies:: [[openspec:graph-std#Relation combinators#One combinator, two relations]] {level: unit}
def twoRelations : IO Unit := do
  let src := "accumulate graph.std.
pred up o:person, o:person.
up P M :- person P, closure (edge_of reports_to) P M.
pred within o:part, o:part.
within A B :- part A, closure (edge_of part_of) A B.
"
  let _ ← saveTo (← schemaOf) [] "m" src
  let facts := edges "reports_to" "person" [(1, 2)] ++ edges "part_of" "part" [(1, 2), (2, 3)] ++ people [1, 2] ++
    "part (part 1).\npart (part 2).\npart (part 3).\n"
  let r ← answers facts "up P M" (src.drop "accumulate graph.std.\n".length).toString
  check (r == ["P=(person 1) M=(person 2)"]) s!"{r}"
  let r ← answers facts "within (part 1) B" (src.drop "accumulate graph.std.\n".length).toString
  check (sorted r == ["B=(part 2)", "B=(part 3)"]) s!"{r}"

-- @tg: verifies:: [[openspec:graph-std#Relation combinators#Functional witness]] {level: unit}
def functional : IO Unit := do
  let r ← answers (edges "has_manager" "person" [(1, 2), (1, 3), (4, 2)]) "functional_witness (edge_of has_manager) X Y1 Y2"
  check (sorted r == ["X=(person 1) Y1=(person 2) Y2=(person 3)", "X=(person 1) Y1=(person 3) Y2=(person 2)"]) s!"{r}"

-- @tg: verifies:: [[openspec:graph-std#Cycle detection#Witnesses on a cycle]] {level: unit}
def witnesses : IO Unit := do
  let facts := edges "part_of" "part" [(1, 2), (2, 3), (3, 1), (4, 1)]
  let r ← answers facts "acyclic_witness (edge_of part_of) X"
  check (sorted r == ["X=(part 1)", "X=(part 2)", "X=(part 3)"]) s!"{r}"
  check ((← answers facts "acyclic (edge_of part_of)").isEmpty) "acyclic fails on a cycle"
  check ((← answers (edges "part_of" "part" [(1, 2), (2, 3)]) "acyclic (edge_of part_of)").length == 1) "acyclic holds"

-- @tg: verifies:: [[openspec:graph-std#Cardinality checks#Missing mandatory edge]] {level: unit}
def missingEdge : IO Unit := do
  let r ← answers (people [1, 2, 3] ++ edges "has_manager" "person" [(1, 2), (2, 3)])
    "card_witness person (edge_of has_manager) 1 1 X N"
  check (r == ["X=(person 3) N=0"]) s!"{r}"

-- @tg: verifies:: [[openspec:graph-std#Cardinality checks#Unbounded maximum]] {level: unit}
def unbounded : IO Unit := do
  let r ← answers (people [1, 2, 3, 4, 5, 6] ++ edges "knows" "person" [(1, 2), (1, 3), (1, 4), (1, 5), (1, 6)])
    "card_witness person (edge_of knows) 0 -1 X N"
  check r.isEmpty s!"{r}"
  let r ← answers (people [1, 2] ++ edges "knows" "person" [(1, 2), (1, 2)]) "card (edge_of knows) (person 1) 1 1"
  check (r.length == 1) "two edges to one target count once"

/-! ### graph.std: the analysis treats combinators by their definitions -/

def ruleSrc (body : String) (radius : Nat := 1) : String :=
  "accumulate graph.std.
pred violation o:severity, o:string, o:subject.
violation error \"x\" (subj_person X) :- " ++ body ++ s!".
% @marien partition violation by person radius {radius}
"

-- @tg: verifies:: [[openspec:graph-std#Combinators in violation rules#Cardinality rule partitions by anchor]] {level: unit, confidence: partial, note: "the save; the integration test compares partitioned and full rows"}
def cardPartitions : IO Unit := do
  let st ← saveTo (← schemaOf) [] "m" (ruleSrc "card_witness person (edge_of has_manager) 1 1 X _")
  let v ← verdictOf st "m" "violation"
  check (v.partition.isSome && !v.monotone) s!"{repr v}"

-- @tg: verifies:: [[openspec:graph-std#Combinators in violation rules#Search-based cycle rule cannot be anchor-partitioned]] {level: unit}
def cycleNotPartitioned : IO Unit := do
  let e ← saveErr (← schemaOf) [] "m" (ruleSrc "acyclic_witness (edge_of knows) X")
  check (contains e "rejected" && contains e "acyclic_witness") e

/-- The library's locality claims agree with the check, on a probe rule per combinator. -/
def localityClaims : IO Unit := do
  let probes : List (String × String) :=
    [("card_witness", "card_witness person (edge_of knows) 1 1 X _"),
     ("functional_witness", "functional_witness (edge_of knows) X _ _"),
     ("symmetric_witness", "symmetric_witness (edge_of knows) X _"),
     ("acyclic_witness_in", "acyclic_witness_in in_cycle.knows X"),
     ("closure", "person X, closure (edge_of knows) X _"),
     ("acyclic", "person X, acyclic (edge_of knows)"),
     ("acyclic_witness", "acyclic_witness (edge_of knows) X")]
  check (GraphStd.claims.length == probes.length) s!"{GraphStd.claims}"
  for (p, claim) in GraphStd.claims do
    let some (_, body) := probes.find? (·.1 == p) | fail s!"no probe for {p}"
    match claim, Store.check (← schemaOf) [] "m" (ruleSrc body (claim.getD 1)) with
    | some _, .error e => fail s!"{p} is claimed local: {e}"
    | none, .ok _ => fail s!"{p} is claimed non-local, but the check accepts it"
    | _, _ => pure ()

def all : List (String × IO Unit) :=
  [("node and rel tables reflected", nodeAndRel), ("multi-pair rel tables", multiPair),
   ("reflection typechecks", reflectionTypechecks), ("system tables invisible", systemInvisible),
   ("annotation reflected", annotationReflected), ("annotating an unknown table", annotateUnknown),
   ("per-table clauses", perTable), ("annotation regenerates", annotationRegenerates),
   ("stage one sees no data", noData), ("unparseable output", unparseable), ("unclosed meta section", unclosedMeta),
   ("ill-typed generated clause", illTyped), ("undeclared generated head", undeclaredHead),
   ("generated negation", generatedNegation), ("byte-identical regeneration", byteIdentical),
   ("catalog order", catalogOrder), ("hypothetical makes dynamic", hypotheticalDynamic),
   ("dynamic never partitioned", dynamicNeverPartitioned), ("local hypotheticals", localHypothetical),
   ("closure", closureOver), ("closure on cycles", closureCycle), ("two relations", twoRelations),
   ("functional witness", functional), ("cycle witnesses", witnesses), ("missing mandatory edge", missingEdge),
   ("unbounded maximum", unbounded), ("cardinality rule partitions", cardPartitions),
   ("cycle rule not partitioned", cycleNotPartitioned), ("locality claims", localityClaims)]

end M4
