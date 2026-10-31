import Lean.Data.Json

/-!
# Schema model

The graph schema as a pure Lean value: node tables with their primary key and properties, rel
tables with their FROM/TO pairs and properties, each property with its LadybugDB type. The shim's
catalog reader serializes LadybugDB's catalog to JSON and `Schema.ofJson` builds the model, so
the offline tool of M5 can build the same model from a file.

Catalog JSON:

```json
{"nodes": [{"name": "Person", "key": "id",
            "properties": [{"name": "id", "type": "INT64"}, {"name": "tags", "type": {"list": "STRING"}}]}],
 "rels":  [{"name": "Knows", "pairs": [["Person", "Person"]],
            "properties": [{"name": "since", "type": "INT64"}]}]}
```

A type is a type name (`"INT64"`), `{"list": T}`, `{"struct": [[field, T], ...]}` or
`{"other": "MAP(STRING, INT64)"}` for a type Marien does not map.

Tables whose names start with `_elpi_` are Marien's own storage. `Schema.visible` removes them,
and the canonical form and hash are computed over what remains; `canonical_perm` proves that the
order in which the catalog lists tables and properties does not matter.
-/

-- @lat: [[components#Schema model]]

namespace Marien

open Lean (Json)

/-- A LadybugDB property type. Integer and floating types keep their LadybugDB name, so the
canonical form tells `INT32` from `INT64`. -/
inductive LType where
  /-- `INT8` … `INT128`, `UINT8` … `UINT128` and `SERIAL`. -/
  | int (name : String)
  /-- `FLOAT` or `DOUBLE`. -/
  | float (name : String)
  | string
  | bool
  | date
  | timestamp
  | list (elem : LType)
  | struct (fields : List (String × LType))
  /-- A type Marien does not map, as LadybugDB prints it. -/
  | other (text : String)
  deriving Repr, Inhabited, BEq

namespace LType

def intNames : List String :=
  ["INT8", "INT16", "INT32", "INT64", "INT128", "UINT8", "UINT16", "UINT32", "UINT64", "UINT128",
   "SERIAL"]

/-- The type of a LadybugDB type name. -/
def ofName (n : String) : LType :=
  if intNames.contains n then .int n
  else match n with
    | "FLOAT" | "DOUBLE" => .float n
    | "STRING" => .string
    | "BOOL" | "BOOLEAN" => .bool
    | "DATE" => .date
    | "TIMESTAMP" => .timestamp
    | _ => .other n

/-- The type as LadybugDB prints it. -/
partial def render : LType → String
  | .int n | .float n => n
  | .string => "STRING"
  | .bool => "BOOL"
  | .date => "DATE"
  | .timestamp => "TIMESTAMP"
  | .list e => e.render ++ "[]"
  | .struct fs => "STRUCT(" ++ ", ".intercalate (fs.map fun (n, t) => n ++ " " ++ t.render) ++ ")"
  | .other t => t

/-- An unambiguous rendering for the canonical form: names are quoted. -/
partial def canonical : LType → String
  | .list e => "list(" ++ e.canonical ++ ")"
  | .struct fs => "struct(" ++ ",".intercalate (fs.map fun (n, t) => n.quote ++ ":" ++ t.canonical) ++ ")"
  | .other t => "other(" ++ t.quote ++ ")"
  | t => t.render

partial def ofJson? : Json → Except String LType
  | .str n => .ok (ofName n)
  | j => do
    if let .ok e := j.getObjVal? "list" then return .list (← ofJson? e)
    if let .ok (.arr fs) := j.getObjVal? "struct" then
      let fields ← fs.toList.mapM fun f => match f with
        | .arr #[.str n, t] => do return (n, ← ofJson? t)
        | _ => throw s!"struct field must be [name, type], got {f.compress}"
      return .struct fields
    if let .ok (.str t) := j.getObjVal? "other" then return .other t
    throw s!"unknown property type {j.compress}"

end LType

structure Property where
  name : String
  ty : LType
  deriving Repr, Inhabited, BEq

structure NodeTable where
  name : String
  /-- The primary key property. -/
  key : Property
  /-- The other properties, in catalog order. -/
  props : List Property
  deriving Repr, Inhabited, BEq

structure RelTable where
  name : String
  /-- FROM/TO node table pairs. -/
  pairs : List (String × String)
  props : List Property
  deriving Repr, Inhabited, BEq

structure Schema where
  nodes : List NodeTable := []
  rels : List RelTable := []
  deriving Repr, Inhabited, BEq

/-- Tables of Marien's own storage. -/
def isSystem (name : String) : Bool := name.startsWith "_elpi_"

namespace Schema

/-! ### Catalog JSON -/

private def propOfJson (j : Json) : Except String Property := do
  let name ← j.getObjValAs? String "name"
  let ty ← LType.ofJson? (← j.getObjVal? "type")
  return { name, ty }

private def nodeOfJson (j : Json) : Except String NodeTable := do
  let name ← j.getObjValAs? String "name"
  let key ← j.getObjValAs? String "key"
  let props ← (← j.getObjValAs? (Array Json) "properties").toList.mapM propOfJson
  let some k := props.find? (·.name == key)
    | throw s!"node table {name}: primary key {key} is not among its properties"
  return { name, key := k, props := props.filter (·.name != key) }

private def relOfJson (j : Json) : Except String RelTable := do
  let name ← j.getObjValAs? String "name"
  let pairs ← (← j.getObjValAs? (Array Json) "pairs").toList.mapM fun p => match p with
    | .arr #[.str a, .str b] => pure (a, b)
    | _ => throw s!"rel table {name}: a pair must be [from, to], got {p.compress}"
  let props ← (← j.getObjValAs? (Array Json) "properties").toList.mapM propOfJson
  return { name, pairs, props }

/-- The schema described by the catalog reader's JSON. -/
def ofJson (j : Json) : Except String Schema := do
  let nodes ← (← j.getObjValAs? (Array Json) "nodes").toList.mapM nodeOfJson
  let rels ← (← j.getObjValAs? (Array Json) "rels").toList.mapM relOfJson
  return { nodes, rels }

def parse (text : String) : Except String Schema := do
  ofJson (← Json.parse text)

/-! ### System tables -/

/-- A rel table without its system endpoints, if any pair is left. -/
def visibleRel (r : RelTable) : Option RelTable :=
  if isSystem r.name then none
  else match r.pairs.filter (fun (a, b) => !isSystem a && !isSystem b) with
    | [] => none
    | ps => some { r with pairs := ps }

/-- The schema rules may see: every `_elpi_*` table, and every pair touching one, removed. -/
def visible (s : Schema) : Schema :=
  { nodes := s.nodes.filter (!isSystem ·.name), rels := s.rels.filterMap visibleRel }

theorem visible_nodes {s : Schema} {n : NodeTable} (h : n ∈ s.visible.nodes) : isSystem n.name = false := by
  simp [visible] at h
  exact h.2

theorem visible_rels {s : Schema} {r : RelTable} (h : r ∈ s.visible.rels) :
    isSystem r.name = false ∧ ∀ p ∈ r.pairs, isSystem p.1 = false ∧ isSystem p.2 = false := by
  simp only [visible, List.mem_filterMap] at h
  obtain ⟨r₀, _, hr⟩ := h
  unfold visibleRel at hr
  split at hr
  · contradiction
  · rename_i hs
    generalize hf : r₀.pairs.filter (fun (a, b) => !isSystem a && !isSystem b) = ps at hr
    cases ps with
    | nil => contradiction
    | cons q qs =>
      cases hr
      refine ⟨by simpa using hs, fun p hp => ?_⟩
      have : p ∈ r₀.pairs.filter (fun (a, b) => !isSystem a && !isSystem b) := by rw [hf]; exact hp
      simp [List.mem_filter] at this
      exact this.2

/-! ### Canonical form and hash -/

/-- Strings in order. -/
def sortStrings (l : List String) : List String := l.mergeSort (fun a b => decide (a ≤ b))

/-- Sorting gives the same list for any two permutations. -/
theorem sortStrings_perm {l₁ l₂ : List String} (h : l₁.Perm l₂) : sortStrings l₁ = sortStrings l₂ := by
  have trans : ∀ a b c : String, decide (a ≤ b) = true → decide (b ≤ c) = true → decide (a ≤ c) = true := by
    simp only [decide_eq_true_eq]; exact fun _ _ _ => String.le_trans
  have total : ∀ a b : String, (decide (a ≤ b) || decide (b ≤ a)) = true := by
    intro a b; simpa using String.le_total a b
  apply List.Perm.eq_of_pairwise (le := fun a b => decide (a ≤ b) = true)
  · intro a b _ _ hab hba
    simp only [decide_eq_true_eq] at hab hba
    exact String.le_antisymm hab hba
  · exact List.pairwise_mergeSort trans total _
  · exact List.pairwise_mergeSort trans total _
  · exact (List.mergeSort_perm _ _).trans (h.trans (List.mergeSort_perm _ _).symm)

def renderProp (p : Property) : String := p.name.quote ++ ":" ++ p.ty.canonical

def renderNode (n : NodeTable) : String :=
  "node " ++ n.name.quote ++ " key " ++ renderProp n.key ++ " props " ++
    ",".intercalate (sortStrings (n.props.map renderProp))

def renderRel (r : RelTable) : String :=
  "rel " ++ r.name.quote ++ " pairs " ++
    ",".intercalate (sortStrings (r.pairs.map fun (a, b) => a.quote ++ ">" ++ b.quote)) ++
    " props " ++ ",".intercalate (sortStrings (r.props.map renderProp))

/-- The canonical form: one line per visible table, tables, properties and pairs sorted. -/
def canonical (s : Schema) : List String :=
  sortStrings (s.visible.nodes.map renderNode ++ s.visible.rels.map renderRel)

/-- Listing the same tables in another order gives the same canonical form. Properties and
pairs are sorted inside `renderNode` and `renderRel` by the same `sortStrings_perm`. -/
-- @tg: verifies:: [[openspec:schema-encoding#Canonical schema hash#Order does not matter]] {level: unit}
theorem canonical_perm {s t : Schema} (hn : s.nodes.Perm t.nodes) (hr : s.rels.Perm t.rels) :
    canonical s = canonical t := by
  unfold canonical visible
  apply sortStrings_perm
  exact List.Perm.append ((hn.filter _).map _) ((hr.filterMap _).map _)

/-- 64-bit FNV-1a over the UTF-8 bytes: stable across Lean versions, unlike `hash`, because the
hash is stored in `_elpi_module.schema_hash`. -/
def fnv1a64 (s : String) : UInt64 :=
  s.toUTF8.foldl (init := 0xcbf29ce484222325) fun h b => (h ^^^ b.toUInt64) * 0x100000001b3

def hex16 (x : UInt64) : String :=
  let digits := (Nat.toDigits 16 x.toNat)
  String.ofList (List.replicate (16 - digits.length) '0' ++ digits)

/-- The schema hash: FNV-1a of the canonical form. -/
-- @tg: implements:: [[openspec:schema-encoding#Canonical schema hash]]
def hash (s : Schema) : String := hex16 (fnv1a64 ("\n".intercalate s.canonical))

end Schema

end Marien
