import Marien.Schema

/-!
# Schema dump

The canonical JSON document of a schema: what `CALL elpi_signature(format := 'json')` returns and
what `lake exe marien-codegen` reads. It is the catalog JSON that `Schema.ofJson` parses, so the
offline tool builds the same `Schema` value the extension builds from the live catalog:

```json
{"annotations":[{"key":"acyclic","table":"ReportsTo","value":"true"}],
 "format":"marien.schema/1",
 "nodes":[{"key":"id","name":"Person","properties":[{"name":"id","type":"INT64"},{"name":"name","type":"STRING"}]}],
 "rels":[{"name":"ReportsTo","pairs":[["Person","Person"]],"properties":[{"name":"since","type":"INT64"}]}]}
```

(one line in the dump). Only the visible schema is dumped: `_elpi_*` tables, pairs and
annotations are left out. Object keys are sorted; tables, properties, pairs and annotations are
sorted by their rendering, so the document depends on the schema and not on the order in which the
catalog lists it (`canonical_perm`). STRUCT fields keep their order, which is part of the type.
-/

namespace Marien.Dump

open Lean (Json)

/-- The format tag of the document. -/
def formatTag : String := "marien.schema/1"

private def q (s : String) : String := (Json.str s).compress

/-- A type as `LType.ofJson?` reads it. -/
partial def typeJson : LType → String
  | .int n | .float n => q n
  | .string => q "STRING"
  | .bool => q "BOOL"
  | .date => q "DATE"
  | .timestamp => q "TIMESTAMP"
  | .list e => "{\"list\":" ++ typeJson e ++ "}"
  | .struct fs => "{\"struct\":[" ++ ",".intercalate (fs.map fun (n, t) => "[" ++ q n ++ "," ++ typeJson t ++ "]") ++ "]}"
  | .other t => "{\"other\":" ++ q t ++ "}"

def propJson (p : Property) : String := "{\"name\":" ++ q p.name ++ ",\"type\":" ++ typeJson p.ty ++ "}"

def array (elems : List String) : String := "[" ++ ",".intercalate (Schema.sortStrings elems) ++ "]"

def nodeJson (n : NodeTable) : String :=
  "{\"key\":" ++ q n.key.name ++ ",\"name\":" ++ q n.name ++ ",\"properties\":" ++
    array ((n.key :: n.props).map propJson) ++ "}"

def relJson (r : RelTable) : String :=
  "{\"name\":" ++ q r.name ++ ",\"pairs\":" ++ array (r.pairs.map fun (a, b) => "[" ++ q a ++ "," ++ q b ++ "]") ++
    ",\"properties\":" ++ array (r.props.map propJson) ++ "}"

def annotJson (a : Annot) : String :=
  "{\"key\":" ++ q a.key ++ ",\"table\":" ++ q a.table ++ ",\"value\":" ++ q a.value ++ "}"

/-- The canonical dump of the visible schema. -/
-- @tg: implements:: [[openspec:offline-codegen#Schema dump]]
def ofSchema (s : Schema) : String :=
  let v := s.visible
  "{\"annotations\":" ++ array (v.annots.map annotJson) ++ ",\"format\":" ++ q formatTag ++
    ",\"nodes\":" ++ array (v.nodes.map nodeJson) ++ ",\"rels\":" ++ array (v.rels.map relJson) ++ "}"

/-- Listing the same tables and annotations in another order gives the same document. Properties
and pairs inside a table are sorted by the same `sortStrings`. -/
-- @tg: verifies:: [[openspec:offline-codegen#Schema dump#Dump is canonical]] {level: unit}
theorem canonical_perm {s t : Schema} (hn : s.nodes.Perm t.nodes) (hr : s.rels.Perm t.rels)
    (ha : s.annots.Perm t.annots) : ofSchema s = ofSchema t := by
  unfold ofSchema array Schema.visible
  simp only
  rw [Schema.sortStrings_perm ((ha.filter _).map annotJson),
    Schema.sortStrings_perm ((hn.filter _).map nodeJson),
    Schema.sortStrings_perm ((hr.filterMap _).map relJson)]

/-- The schema a dump describes. -/
def parse (text : String) : Except String Schema := do
  let j ← Json.parse text
  match j.getObjValAs? String "format" with
  | .ok f => if f != formatTag then throw s!"unknown schema dump format {f}; expected {formatTag}"
  | .error _ => throw s!"not a schema dump: no \"format\" key (expected {formatTag})"
  Schema.ofJson j

end Marien.Dump
