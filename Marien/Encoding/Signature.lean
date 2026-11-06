import Marien.Schema

/-!
# Signature generator

The predicate-per-property encoding of a schema as an ELPI signature. For a node table `Person`
with key `id INT64` and property `name STRING`:

```
kind person type.
pred person o:person.
type person int -> person.
pred person.name o:person, o:string.
```

`person` is both the constructor (`person 7` is the node with key 7) and the predicate listing
every node; LeanElpi resolves the overloading by type. A `pred` declaration after a `type` of the
same name would replace the constant instead, so the predicate is always declared first.

A rel table `Knows(FROM Person TO Person, since INT64)` becomes an edge kind over the edge's
internal id, the rel predicate and one predicate per property:

```
kind knows type.
pred knows o:person, o:knows, o:person.
type knows int -> knows.
pred knows.since o:knows, o:int.
```

With several FROM/TO pairs the endpoints are union kinds `r.src` and `r.dst`, with one
constructor per node table (`type owns.src.person person -> owns.src.`). Edge ids are internal
ids, stable only within one transaction.

A rel table with one FROM/TO pair over one node table also gets its structural predicates,
computed from the graph when a rule reaches them:

```
pred in_cycle.reports_to o:person.
pred component.reports_to o:person, o:int.
```

Names are lower snake case (`ReportsTo` ↦ `reports_to`). Generation fails when two catalog
names map to one identifier, or an identifier is a keyword or library name, so the naming is
injective whenever generation succeeds (`assignNames_injective`). `_elpi_*` tables never reach
the signature (`signature_excludes_system`).

Every signature starts with the validation protocol's kinds, and every table gets a constructor
of the `subject` union, named `subj_<table>`:

```
kind severity type.
type error, warning, info severity.
kind subject type.
type subj_person person -> subject.
```

`Signature.ofSchema` is the single encoding function, shared with the offline codegen of M5.
-/

-- @lat: [[components#Signature generator]]

namespace Marien.Encoding

/-! ### ELPI types of properties -/

/-- The ELPI type of a property value. DATE and TIMESTAMP are `int` (days and microseconds since
1970-01-01 UTC); a STRUCT is a generated record kind with one constructor. -/
inductive ETy where
  | int
  | float
  | string
  | bool
  | list (elem : ETy)
  | record (ctor : String) (fields : List ETy)
  deriving Repr, Inhabited, BEq

partial def ETy.render : ETy → String
  | .int => "int"
  | .float => "float"
  | .string => "string"
  | .bool => "bool"
  | .list e => "(list " ++ e.render ++ ")"
  | .record c _ => c

/-! ### Naming -/

/-- Lower snake case: a `_` before an upper-case letter that follows a lower-case letter or a
digit, or that starts a word after an acronym (`HTTPServer` ↦ `http_server`); any character
other than an ASCII letter, digit or `_` becomes `_`. -/
def snake (s : String) : String := Id.run do
  let cs := s.toList.toArray
  let mut out : Array Char := #[]
  for h : i in [0:cs.size] do
    let c := cs[i]
    if c.isUpper then
      let prev := if i > 0 then cs[i - 1]? else none
      let nextLower := (cs[i + 1]?.map Char.isLower).getD false
      let boundary := match prev with
        | some p => p.isLower || p.isDigit || (p.isUpper && nextLower)
        | none => false
      if boundary then out := out.push '_'
      out := out.push c.toLower
    else if c.isAlphanum || c == '_' then out := out.push c
    else out := out.push '_'
  return String.ofList out.toList

/-- What a generated identifier stands for. -/
inductive Origin where
  /-- Kind, constructor and predicate of a node table. -/
  | node (table : String)
  /-- Edge kind, edge constructor and predicate of a rel table. -/
  | rel (table : String)
  /-- The predicate of a property. -/
  | prop (table prop : String)
  /-- The record kind and constructor of a STRUCT value at `path` (property, then fields). -/
  | record (table : String) (path : List String)
  /-- The union endpoint kind `r.src` (`src = true`) or `r.dst` of a multi-pair rel table. -/
  | endpoint (rel : String) (src : Bool)
  /-- The constructor of a union endpoint kind for one node table. -/
  | endpointCtor (rel : String) (src : Bool) (node : String)
  /-- The `subject` constructor of a node or rel table. -/
  | subject (table : String)
  /-- A kind or constant of the validation protocol (`severity`, `error`, `subject`, …). -/
  | protocol (name : String)
  /-- The structural predicate `in_cycle.<rel>` (`cycle = true`) or `component.<rel>` of a rel
  table whose endpoints are one node table. -/
  | structural (rel : String) (cycle : Bool)
  deriving DecidableEq, Repr, Inhabited

namespace Origin

private def side (src : Bool) : String := if src then "src" else "dst"

/-- The generated identifier. -/
def ident : Origin → String
  | .node t | .rel t => snake t
  | .prop t p => snake t ++ "." ++ snake p
  | .record t path => snake t ++ "." ++ ".".intercalate (path.map snake) ++ ".rec"
  | .endpoint r s => snake r ++ "." ++ side s
  | .endpointCtor r s t => snake r ++ "." ++ side s ++ "." ++ snake t
  | .subject t => "subj_" ++ snake t
  | .protocol n => n
  | .structural r c => (if c then "in_cycle." else "component.") ++ snake r

/-- The catalog names the identifier is made of. -/
def parts : Origin → List String
  | .node t | .rel t => [t]
  | .prop t p => [t, p]
  | .record t path => t :: path
  | .endpoint r _ => [r]
  | .endpointCtor r _ t => [r, t]
  | .subject t => [t]
  | .protocol _ => []
  | .structural r _ => [r]

/-- The table an identifier belongs to; `none` for the protocol's own names. -/
def table? : Origin → Option String
  | .node t | .rel t | .prop t _ | .record t _ | .endpoint t _ | .endpointCtor t _ _ | .subject t
  | .structural t _ => some t
  | .protocol _ => none

def describe : Origin → String
  | .node t => s!"node table {t}"
  | .rel t => s!"rel table {t}"
  | .prop t p => s!"property {t}.{p}"
  | .record t path => s!"struct {t}.{".".intercalate path}"
  | .endpoint r s => s!"{side s} endpoints of {r}"
  | .endpointCtor r s t => s!"{side s} endpoint {t} of {r}"
  | .subject t => s!"the subject constructor of {t}"
  | .protocol n => s!"the validation protocol's {n}"
  | .structural r c => s!"the {if c then "cycle" else "component"} predicate of {r}"

/-- Every part becomes a word that starts with an ASCII lower-case letter, as ELPI constants
must (a leading `_` or upper-case letter would make a variable). -/
def valid (o : Origin) : Bool :=
  o.parts.all fun p => match (snake p).toList with
    | c :: _ => 'a' ≤ c && c ≤ 'z'
    | [] => false

end Origin

/-! ### The encodable schema -/

structure RecordDecl where
  origin : Origin
  ctor : String
  fields : List ETy
  /-- The STRUCT type it encodes, with its field names. -/
  lty : LType
  deriving Repr, Inhabited

structure PropPlan where
  name : String
  pred : String
  ty : ETy
  deriving Repr, Inhabited

structure NodePlan where
  name : String
  id : String
  keyName : String
  keyTy : ETy
  /-- The primary key's LadybugDB type. -/
  keyLty : LType
  props : List PropPlan
  /-- Records used by the key and the properties, inner ones first. -/
  records : List RecordDecl
  deriving Repr, Inhabited

structure RelPlan where
  name : String
  id : String
  /-- FROM/TO pairs whose endpoints are encoded node tables. -/
  pairs : List (String × String)
  props : List PropPlan
  records : List RecordDecl
  deriving Repr, Inhabited

namespace RelPlan

/-- Endpoints are union kinds when there are several pairs. -/
def multi (r : RelPlan) : Bool := r.pairs.length > 1

def srcTables (r : RelPlan) : List String := (r.pairs.map (·.1)).eraseDups
def dstTables (r : RelPlan) : List String := (r.pairs.map (·.2)).eraseDups

/-- The node table of both endpoints, when the rel table has one FROM/TO pair over one table;
such a table gets the structural predicates `in_cycle.<rel>` and `component.<rel>`. -/
def selfKind? (r : RelPlan) : Option String :=
  match r.pairs with
  | [(a, b)] => if a == b then some a else none
  | _ => none

end RelPlan

/-- The part of a schema the signature encodes. -/
structure Plan where
  nodes : List NodePlan
  rels : List RelPlan
  deriving Repr, Inhabited

/-- The ELPI type of a LadybugDB type at `path` of `table`, with the records it needs (inner
ones first); `none` for a type Marien does not map. -/
partial def mapType (table : String) (path : List String) : LType → Option (ETy × List RecordDecl)
  | .int _ | .date | .timestamp => some (.int, [])
  | .float _ => some (.float, [])
  | .string => some (.string, [])
  | .bool => some (.bool, [])
  | .list e => (mapType table path e).map fun (t, rs) => (.list t, rs)
  | .struct fs => do
    let mut tys : List ETy := []
    let mut rs : List RecordDecl := []
    for (f, ft) in fs do
      let (t, r) ← mapType table (path ++ [f]) ft
      tys := tys ++ [t]
      rs := rs ++ r
    let o := Origin.record table path
    some (.record o.ident tys, rs ++ [{ origin := o, ctor := o.ident, fields := tys, lty := .struct fs }])
  | .other _ => none

def planProp (table : String) (p : Property) : Option (PropPlan × List RecordDecl) :=
  (mapType table [p.name] p.ty).map fun (ty, rs) =>
    ({ name := p.name, pred := (Origin.prop table p.name).ident, ty }, rs)

def planNode (n : NodeTable) : Option NodePlan := do
  let (keyTy, keyRecs) ← mapType n.name [n.key.name] n.key.ty
  let props := n.props.filterMap (planProp n.name)
  some { name := n.name, id := (Origin.node n.name).ident, keyName := n.key.name, keyTy,
         keyLty := n.key.ty,
         props := props.map (·.1), records := keyRecs ++ props.flatMap (·.2) }

def planRel (encoded : List String) (r : RelTable) : Option RelPlan :=
  match r.pairs.filter (fun (a, b) => encoded.contains a && encoded.contains b) with
  | [] => none
  | pairs =>
    let props := r.props.filterMap (planProp r.name)
    some { name := r.name, id := (Origin.rel r.name).ident, pairs, props := props.map (·.1),
           records := props.flatMap (·.2) }

/-- The encodable part of the visible schema. -/
def plan (s : Schema) : Plan :=
  let v := s.visible
  let nodes := v.nodes.filterMap planNode
  { nodes, rels := v.rels.filterMap (planRel (nodes.map (·.name))) }

/-- What `plan` leaves out, and why. -/
def warnings (s : Schema) : List String := Id.run do
  let v := s.visible
  let mut out : List String := []
  let unsupported (t : String) (p : Property) : Option String :=
    match mapType t [p.name] p.ty with
    | some _ => none
    | none => some s!"table {t}, property {p.name}: type {p.ty.render} is not supported; the property is left out"
  for n in v.nodes do
    match mapType n.name [n.key.name] n.key.ty with
    | none => out := out ++ [s!"node table {n.name}: primary key {n.key.name} has unsupported type {n.key.ty.render}; the table is left out"]
    | some _ => out := out ++ n.props.filterMap (unsupported n.name)
  let encoded := (plan s).nodes.map (·.name)
  for r in v.rels do
    for (a, b) in r.pairs do
      unless encoded.contains a && encoded.contains b do
        out := out ++ [s!"rel table {r.name}: pair ({a}, {b}) has an endpoint that is left out"]
    out := out ++ r.props.filterMap (unsupported r.name)
  return out

theorem planNode_name {n : NodeTable} {p : NodePlan} (h : planNode n = some p) : p.name = n.name := by
  unfold planNode at h
  cases hm : mapType n.name [n.key.name] n.key.ty with
  | none => simp [hm] at h
  | some r => simp [hm] at h; rw [← h]

theorem planRel_name {enc : List String} {r : RelTable} {p : RelPlan} (h : planRel enc r = some p) :
    p.name = r.name := by
  unfold planRel at h
  split at h
  · contradiction
  · cases h; rfl

/-- `_elpi_*` tables never reach the signature: every encoded node and rel table is visible. -/
-- @tg: verifies:: [[openspec:schema-encoding#System tables are invisible to rules#Module cannot read its own storage]] {level: unit}
theorem signature_excludes_system (s : Schema) :
    (∀ n ∈ (plan s).nodes, ¬ n.name.startsWith "_elpi_") ∧
    (∀ r ∈ (plan s).rels, ¬ r.name.startsWith "_elpi_") := by
  constructor
  · intro n hn
    simp only [plan, List.mem_filterMap] at hn
    obtain ⟨n₀, h₀, hp⟩ := hn
    have := Schema.visible_nodes h₀
    rw [planNode_name hp]
    simpa [isSystem] using this
  · intro r hr
    simp only [plan, List.mem_filterMap] at hr
    obtain ⟨r₀, h₀, hp⟩ := hr
    have := (Schema.visible_rels h₀).1
    rw [planRel_name hp]
    simpa [isSystem] using this

/-! ### Names -/

/-- The kinds and constants of the validation protocol. -/
def protocolNames : List String := ["severity", "error", "warning", "info", "subject"]

/-- Every identifier the signature declares, by what it stands for. -/
def origins (p : Plan) : List Origin :=
  protocolNames.map .protocol ++
  p.nodes.flatMap (fun n =>
    .node n.name :: .subject n.name :: n.props.map (fun pr => .prop n.name pr.name) ++
      n.records.map (·.origin)) ++
  p.rels.flatMap fun r =>
    .rel r.name :: .subject r.name :: r.props.map (fun pr => .prop r.name pr.name) ++
      r.records.map (·.origin) ++
    (if r.selfKind?.isSome then [.structural r.name true, .structural r.name false] else []) ++
    (if r.multi then
      [.endpoint r.name true, .endpoint r.name false] ++
      r.srcTables.map (.endpointCtor r.name true) ++ r.dstTables.map (.endpointCtor r.name false)
    else [])

inductive NameError where
  /-- Several catalog names map to one identifier. -/
  | clash (ident : String) (origins : List Origin)
  | reserved (ident : String) (origin : Origin)
  | invalid (ident : String) (origin : Origin)
  deriving Repr, Inhabited

def NameError.toString : NameError → String
  | .clash i os => s!"{" and ".intercalate (os.map Origin.describe)} all map to the identifier {i}; rename one of them"
  | .reserved i o => s!"{o.describe} maps to {i}, which is an ELPI keyword or library name; rename it"
  | .invalid i o => s!"{o.describe} maps to {i}, which is not an ELPI constant (each part must start with a letter)"

instance : ToString NameError := ⟨NameError.toString⟩

/-- No two different origins share an identifier. -/
def injCheck (os : List Origin) : Bool :=
  os.all fun a => os.all fun b => a.ident != b.ident || a == b

/-- The first clash, for the error message. -/
def firstClash (os : List Origin) : Option NameError :=
  os.findSome? fun a =>
    match (os.filter (·.ident == a.ident)).eraseDups with
    | xs@(_ :: _ :: _) => some (.clash a.ident xs)
    | _ => none

/-- The identifier of each origin, if they are valid, unreserved and pairwise distinct. -/
-- @tg: implements:: [[openspec:schema-encoding#Injective naming]]
def assignNames (reserved : String → Bool) (p : Plan) : Except NameError (Origin → String) :=
  let os := origins p
  match os.find? (!·.valid) with
  | some o => .error (.invalid o.ident o)
  | none =>
    match os.find? (reserved ·.ident) with
    | some o => .error (.reserved o.ident o)
    | none =>
      if injCheck os then .ok Origin.ident
      else .error ((firstClash os).getD (.clash "" os))

/-- Whenever generation succeeds, no identifier stands for two catalog names. -/
-- @tg: verifies:: [[openspec:schema-encoding#Injective naming#Collision is an error]] {level: unit}
theorem assignNames_injective {reserved : String → Bool} {p : Plan} {m : Origin → String}
    (h : assignNames reserved p = .ok m) :
    ∀ a ∈ origins p, ∀ b ∈ origins p, m a = m b → a = b := by
  unfold assignNames at h
  dsimp only at h
  split at h
  · contradiction
  · split at h
    · contradiction
    · split at h
      · rename_i hc
        cases h
        intro a ha b hb hab
        have := (List.all_eq_true.mp hc) a ha
        have := (List.all_eq_true.mp this) b hb
        simp only [Bool.or_eq_true, bne_iff_ne, ne_eq, beq_iff_eq] at this
        exact this.resolve_left (fun h' => h' hab)
      · contradiction

/-! ### Declarations

The generator produces structured declarations; a `SignaturePrinter` renders them. The
`ElpiPrinter` here writes the ELPI text the database loads; the `LeanPrinter` of the offline
codegen (`Marien/Offline/Codegen.lean`) writes Lean inductives with `deriving Elpi` from the same
declarations, so the encoding has one definition and two printers. -/

/-- The type of a constructor or predicate argument: a property value type, or a generated kind
(node, edge, union endpoint, `subject`, `severity`). -/
inductive ATy where
  | val (t : ETy)
  | kind (name : String)
  deriving Repr, Inhabited, BEq

/-- One declaration of the generated signature. -/
inductive Decl where
  /-- `kind k type.` -/
  | kind (name : String)
  /-- `type c₁, …, cₙ a₁ -> … -> k.`: constructors of the kind `result`. -/
  | ctor (names : List String) (args : List ATy) (result : String)
  /-- `pred p o:a₁, ….`, indexed to `index` when it is not empty (`_`: not indexed). -/
  | pred (name : String) (args : List ATy) (index : List String)
  deriving Repr, Inhabited, BEq

private def recordDecls (rs : List RecordDecl) : List Decl :=
  rs.flatMap fun r => [.kind r.ctor, .ctor [r.ctor] (r.fields.map .val) r.ctor]

def nodeDecls (n : NodePlan) : List Decl :=
  [.kind n.id] ++ recordDecls n.records ++
    [.pred n.id [.kind n.id] ["2"], .ctor [n.id] [.val n.keyTy] n.id] ++
    n.props.map (fun p => .pred p.pred [.kind n.id, .val p.ty] ["2"]) ++
    [.ctor [(Origin.subject n.name).ident] [.kind n.id] "subject"]

def relDecls (nodeId : String → String) (r : RelPlan) : List Decl :=
  let ends : List Decl × String × String :=
    if r.multi then
      let s := (Origin.endpoint r.name true).ident
      let d := (Origin.endpoint r.name false).ident
      let ctors (src : Bool) (ts : List String) (k : String) : List Decl :=
        ts.map fun t => .ctor [(Origin.endpointCtor r.name src t).ident] [.kind (nodeId t)] k
      ([.kind s] ++ ctors true r.srcTables s ++ [.kind d] ++ ctors false r.dstTables d, s, d)
    else match r.pairs with
      | (a, b) :: _ => ([], nodeId a, nodeId b)
      | [] => ([], "", "")
  let (endDecls, src, dst) := ends
  -- a union endpoint wraps the node once more (`owns.src.person (person 7)`)
  let endDepth := if r.multi then "3" else "2"
  [.kind r.id] ++ endDecls ++ recordDecls r.records ++
    [.pred r.id [.kind src, .kind r.id, .kind dst] [endDepth, "2", endDepth],
     .ctor [r.id] [.val .int] r.id] ++
    r.props.map (fun p => .pred p.pred [.kind r.id, .val p.ty] ["2"]) ++
    [.ctor [(Origin.subject r.name).ident] [.kind r.id] "subject"] ++
    (match r.selfKind? with
     | some k =>
       [.pred (Origin.structural r.name true).ident [.kind (nodeId k)] ["2"],
        .pred (Origin.structural r.name false).ident [.kind (nodeId k), .val .int] ["2"]]
     | none => [])

/-- The validation protocol's declarations, at the head of every signature. -/
-- @tg: implements:: [[openspec:validation#Violation protocol]] {confidence: partial, note: "the prepended severity and subject kinds"}
def protocolItems : List Decl :=
  [.kind "severity", .ctor ["error", "warning", "info"] [] "severity", .kind "subject"]

/-- A generated signature: structured declarations per table, in catalog order, and warnings. -/
structure Signature where
  plan : Plan
  /-- Catalog name and declarations of each encoded table, node tables first. -/
  decls : List (String × List Decl)
  warnings : List String
  deriving Inhabited

/-- A rendering of a generated signature. -/
structure SignaturePrinter where
  /-- What it renders to, for messages (`elpi`, `lean`). -/
  name : String
  print : Signature → String

namespace ElpiPrinter

def aty : ATy → String
  | .val t => t.render
  | .kind k => k

/-- A generated predicate indexed by its node and edge arguments to `depths` (`_`: not
indexed). A node is `person 7`, so the default first-argument index, which looks only at the
constructor, would put every fact of a table in one bucket; depth 2 hashes the key too. -/
def decl : Decl → String
  | .kind k => s!"kind {k} type."
  | .ctor cs args k => s!"type {", ".intercalate cs} {String.join (args.map (aty · ++ " -> "))}{k}."
  | .pred p args index =>
    let d := s!"pred {p} {", ".intercalate (args.map ("o:" ++ aty ·))}."
    if index.isEmpty then d else s!":index ({" ".intercalate index})\n{d}"

def decls (ds : List Decl) : String := "\n".intercalate (ds.map decl)

end ElpiPrinter

/-- The validation protocol's declarations as ELPI text. -/
def protocolDecls : String := ElpiPrinter.decls protocolItems

namespace Signature

/-- The ELPI declarations of each encoded table, by catalog name. -/
def tables (s : Signature) : List (String × String) := s.decls.map fun (n, ds) => (n, ElpiPrinter.decls ds)

/-- Every declaration, the protocol's first. -/
def allDecls (s : Signature) : List Decl := protocolItems ++ s.decls.flatMap (·.2)

def text (s : Signature) : String := "\n".intercalate (protocolDecls :: s.tables.map (·.2)) ++ "\n"

end Signature

/-- The printer of the in-database signature, which LeanElpi loads and typechecks rules against. -/
def ElpiPrinter : SignaturePrinter := ⟨"elpi", Signature.text⟩

namespace Signature

/-- The table a generated identifier belongs to (kind, constructor, predicate, record or
subject constructor); `none` for any other name. -/
def tableOf? (s : Signature) (ident : String) : Option String :=
  ((origins s.plan).find? (·.ident == ident)).bind Origin.table?

/-- The declarations of one table, by catalog name. -/
def table? (s : Signature) (name : String) : Option String := (s.tables.find? (·.1 == name)).map (·.2)

/-- Generated predicates and the table each belongs to. -/
def preds (s : Signature) : List (String × String) :=
  s.plan.nodes.flatMap (fun n => (n.id, n.name) :: n.props.map (·.pred, n.name)) ++
  s.plan.rels.flatMap fun r => (r.id, r.name) :: r.props.map (·.pred, r.name) ++
    (if r.selfKind?.isSome then
      [((Origin.structural r.name true).ident, r.name), ((Origin.structural r.name false).ident, r.name)]
    else [])

/-- The signature of a schema; `reserved` names the identifiers it must not produce. -/
-- @tg: implements:: [[openspec:schema-encoding#Node table encoding]]
-- @tg: implements:: [[openspec:schema-encoding#Rel table encoding]]
-- @tg: implements:: [[openspec:schema-encoding#Property type mapping]]
-- @tg: implements:: [[openspec:schema-encoding#System tables are invisible to rules]]
-- @tg: implements:: [[openspec:validation#Subject union kind]]
def ofSchema (reserved : String → Bool) (s : Schema) : Except NameError Signature := do
  let p := Encoding.plan s
  let _ ← assignNames reserved p
  let nodeId (t : String) : String := (Origin.node t).ident
  return { plan := p
           decls := p.nodes.map (fun n => (n.name, nodeDecls n)) ++
             p.rels.map (fun r => (r.name, relDecls nodeId r))
           warnings := Encoding.warnings s }

end Signature

end Marien.Encoding
