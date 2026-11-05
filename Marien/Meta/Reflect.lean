import Marien.Encoding.Signature

/-!
# Schema reflection

The deep description of the schema that stage 1 meta-rules read: tables, columns, types and
annotations as plain data, so that one meta-rule can range over every table. The shallow
signature cannot do this, because a predicate value of type `person -> reports_to_e -> person ->
prop` and one of type `part -> part_of_e -> part -> prop` cannot share a clause type (clause type
variables are rigid); the description carries names instead, and `schema.ident` gives the
shallow predicate a meta-rule should write into its clause text.

```
schema.node "Person".                    schema.key "Person" "id".
schema.prop "Person" "name" ty_string.   schema.rel "ReportsTo" "Person" "Person".
schema.annot "ReportsTo" "acyclic" "true".
schema.ident "ReportsTo" "reports_to".   schema.prop_ident "Person" "name" "person.name".
```

`ofSchema` reads the visible schema only, so no fact names an `_elpi_*` table
(`ofSchema_no_system`), and sorts its lines, so the order of the catalog does not matter
(`ofSchema_perm`).
-/

-- @lat: [[components#Schema reflector]]

namespace Marien.Meta.Reflect

open Marien.Encoding

/-- The closed kind of property types, and the description's predicates. -/
def prelude : String := "\n".intercalate [
  "kind schema.ty type.", "kind schema.field type.",
  "type ty_int schema.ty.", "type ty_float schema.ty.", "type ty_string schema.ty.",
  "type ty_bool schema.ty.", "type ty_date schema.ty.", "type ty_timestamp schema.ty.",
  "type ty_list schema.ty -> schema.ty.", "type ty_field string -> schema.ty -> schema.field.",
  "type ty_struct list schema.field -> schema.ty.", "type ty_other string -> schema.ty.",
  "pred schema.node o:string.", "pred schema.key o:string, o:string.",
  "pred schema.rel o:string, o:string, o:string.", "pred schema.prop o:string, o:string, o:schema.ty.",
  "pred schema.annot o:string, o:string, o:string.", "pred schema.ident o:string, o:string.",
  "pred schema.prop_ident o:string, o:string, o:string."] ++ "\n"

/-- An ELPI string literal. -/
def str (s : String) : String :=
  "\"" ++ String.join (s.toList.map fun c => match c with
    | '"' => "\\\"" | '\\' => "\\\\" | '\n' => "\\n" | '\t' => "\\t" | c => c.toString) ++ "\""

/-- The `schema.ty` term of a property type. -/
partial def tyTerm : LType → String
  | .int _ => "ty_int"
  | .float _ => "ty_float"
  | .string => "ty_string"
  | .bool => "ty_bool"
  | .date => "ty_date"
  | .timestamp => "ty_timestamp"
  | .list e => s!"(ty_list {tyTerm e})"
  | .struct fs => s!"(ty_struct [{", ".intercalate (fs.map fun (n, t) => s!"ty_field {str n} {tyTerm t}")}])"
  | .other t => s!"(ty_other {str t})"

/-- One fact of the description. -/
inductive Fact where
  | node (table : String)
  | key (table column : String)
  | prop (table column : String) (ty : LType)
  | rel (name src dst : String)
  | annot (table key value : String)
  | ident (table ident : String)
  | propIdent (table column ident : String)
  deriving Repr, Inhabited

/-- The tables a fact names. -/
def Fact.tables : Fact → List String
  | .node t | .key t _ | .prop t _ _ | .annot t _ _ | .ident t _ | .propIdent t _ _ => [t]
  | .rel r a b => [r, a, b]

def Fact.render : Fact → String
  | .node t => s!"schema.node {str t}."
  | .key t c => s!"schema.key {str t} {str c}."
  | .prop t c ty => s!"schema.prop {str t} {str c} {tyTerm ty}."
  | .rel r a b => s!"schema.rel {str r} {str a} {str b}."
  | .annot t k v => s!"schema.annot {str t} {str k} {str v}."
  | .ident t i => s!"schema.ident {str t} {str i}."
  | .propIdent t c i => s!"schema.prop_ident {str t} {str c} {str i}."

/-- The facts of a property; its shallow predicate only when `encoded` says the signature has it. -/
def propFacts (encoded : String → Bool) (t : String) (p : Property) : List Fact :=
  let i := (Origin.prop t p.name).ident
  .prop t p.name p.ty :: if encoded i then [.propIdent t p.name i] else []

def nodeFacts (encoded : String → Bool) (n : NodeTable) : List Fact :=
  let i := (Origin.node n.name).ident
  [.node n.name, .key n.name n.key.name] ++ propFacts encoded n.name n.key ++
    n.props.flatMap (propFacts encoded n.name) ++ (if encoded i then [.ident n.name i] else [])

def relFacts (encoded : String → Bool) (r : RelTable) : List Fact :=
  let i := (Origin.rel r.name).ident
  r.pairs.map (fun (a, b) => .rel r.name a b) ++ r.props.flatMap (propFacts encoded r.name) ++
    (if encoded i then [.ident r.name i] else [])

/-- The facts of the visible schema, in catalog order: `Schema.visible` drops every `_elpi_*`
table, pair and annotation first. -/
-- @tg: implements:: [[openspec:schema-reflection#System tables are not reflected]]
def facts (s : Schema) (encoded : String → Bool) : List Fact :=
  let v := s.visible
  v.nodes.flatMap (nodeFacts encoded) ++ v.rels.flatMap (relFacts encoded) ++
    v.annots.map fun a => .annot a.table a.key a.value

/-- The reflected description: one line per fact, sorted. `encoded` tells which generated
identifiers the shallow signature declares. -/
-- @tg: implements:: [[openspec:schema-reflection#Reflected schema description]]
def ofSchema (s : Schema) (encoded : String → Bool) : List String :=
  Schema.sortStrings ((facts s encoded).map Fact.render)

/-- The description as a program unit for stage 1: the prelude, then the facts. -/
def text (s : Schema) (encoded : String → Bool) : String :=
  prelude ++ "\n".intercalate (ofSchema s encoded) ++ "\n"

/-! ### Properties -/

theorem propFacts_tables (encoded : String → Bool) (t : String) (p : Property) :
    ∀ f ∈ propFacts encoded t p, f.tables = [t] := by
  intro f hf
  simp only [propFacts] at hf
  rcases List.mem_cons.mp hf with rfl | hf
  · rfl
  · split at hf
    · simp at hf; subst hf; rfl
    · simp at hf

theorem nodeFacts_tables (encoded : String → Bool) (n : NodeTable) :
    ∀ f ∈ nodeFacts encoded n, f.tables = [n.name] := by
  intro f hf
  simp only [nodeFacts, List.mem_append, List.mem_cons, List.mem_flatMap] at hf
  rcases hf with ((((rfl | rfl | h) | h) | ⟨p, _, h⟩) | h)
  · rfl
  · rfl
  · simp at h
  · exact propFacts_tables encoded _ _ f h
  · exact propFacts_tables encoded _ _ f h
  · split at h
    · simp at h; subst h; rfl
    · simp at h

theorem relFacts_tables (encoded : String → Bool) (r : RelTable) :
    ∀ f ∈ relFacts encoded r, ∀ t ∈ f.tables, t = r.name ∨ ∃ p ∈ r.pairs, t = p.1 ∨ t = p.2 := by
  intro f hf t ht
  simp only [relFacts, List.mem_append, List.mem_flatMap] at hf
  rcases hf with ((h | ⟨p, _, h⟩) | h)
  · obtain ⟨q, hq, rfl⟩ := List.mem_map.mp h
    simp only [Fact.tables, List.mem_cons, List.not_mem_nil, or_false] at ht
    rcases ht with rfl | rfl | rfl
    · exact .inl rfl
    · exact .inr ⟨q, hq, .inl rfl⟩
    · exact .inr ⟨q, hq, .inr rfl⟩
  · rw [propFacts_tables encoded _ _ f h] at ht
    exact .inl (List.mem_singleton.mp ht)
  · split at h
    · simp at h; subst h; simp [Fact.tables] at ht; exact .inl ht
    · simp at h

/-- No fact of the description names a system table: `facts` reads only the visible schema. -/
theorem facts_no_system (s : Schema) (encoded : String → Bool) :
    ∀ f ∈ facts s encoded, ∀ t ∈ f.tables, isSystem t = false := by
  intro f hf t ht
  simp only [facts, List.mem_append, List.mem_flatMap, List.mem_map] at hf
  rcases hf with ((⟨n, hn, h⟩ | ⟨r, hr, h⟩) | ⟨a, ha, rfl⟩)
  · rw [nodeFacts_tables encoded n f h] at ht
    rw [List.mem_singleton.mp ht]
    exact Schema.visible_nodes hn
  · have ⟨hname, hpairs⟩ := Schema.visible_rels hr
    rcases relFacts_tables encoded r f h t ht with rfl | ⟨p, hp, rfl | rfl⟩
    · exact hname
    · exact (hpairs p hp).1
    · exact (hpairs p hp).2
  · simp only [Fact.tables, List.mem_singleton] at ht
    subst ht
    exact Schema.visible_annots ha

/-- Every line of the description renders a fact that names no `_elpi_*` table. -/
-- @tg: verifies:: [[openspec:schema-reflection#System tables are not reflected#Module storage stays invisible]] {level: unit}
theorem ofSchema_no_system (s : Schema) (encoded : String → Bool) :
    ∀ line ∈ ofSchema s encoded, ∃ f ∈ facts s encoded, f.render = line ∧ ∀ t ∈ f.tables, isSystem t = false := by
  intro line hl
  have hm : line ∈ (facts s encoded).map Fact.render := (List.mergeSort_perm _ _).mem_iff.mp hl
  obtain ⟨f, hf, rfl⟩ := List.mem_map.mp hm
  exact ⟨f, hf, rfl, facts_no_system s encoded f hf⟩

/-- Listing the tables and annotations in another order gives the same description. -/
-- @tg: verifies:: [[openspec:rule-generation#Generated code depends only on schema and source#Catalog order does not matter]] {level: unit, confidence: partial, note: "the description stage 1 reads"}
theorem ofSchema_perm {s t : Schema} (encoded : String → Bool) (hn : s.nodes.Perm t.nodes)
    (hr : s.rels.Perm t.rels) (ha : s.annots.Perm t.annots) : ofSchema s encoded = ofSchema t encoded := by
  unfold ofSchema facts Schema.visible
  apply Schema.sortStrings_perm
  apply List.Perm.map
  exact List.Perm.append (List.Perm.append ((hn.filter _).flatMap_right _) ((hr.filterMap _).flatMap_right _))
    ((ha.filter _).map _)

end Marien.Meta.Reflect
