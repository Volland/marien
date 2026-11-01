import Marien.Engine
import Marien.Encoding.Signature

/-!
# Value codec

Database values as ELPI terms and back, for each property type of the signature. Integers of
every width map to `int`, which LeanElpi represents as an unbounded `Int`, so no integer is ever
out of range. DATE and TIMESTAMP arrive from the scanner as days and microseconds since
1970-01-01 UTC. A float keeps its IEEE-754 bits. A STRUCT is its record constructor applied to
its fields in order. Node references are the table's constructor applied to the primary key,
edges the rel table's constructor applied to the internal id.

`decode_encode` proves that decoding the encoding gives back the value, for every type.
-/

-- @lat: [[components#Value codec]]

namespace Marien.Encoding

open Marien.Engine (ResultTerm)

/-- A database value, as the scanner hands it over. `null` stands for SQL NULL. -/
inductive Value where
  | int (i : Int)
  | float (bits : UInt64)
  | str (s : String)
  | bool (b : Bool)
  | list (xs : List Value)
  | struct (fields : List Value)
  | null
  deriving Repr, Inhabited, BEq

namespace Codec

mutual
/-- Whether a value has a type; a null nowhere inside. -/
def HasType : Value → ETy → Bool
  | .int _, .int | .float _, .float | .str _, .string | .bool _, .bool => true
  | .list xs, .list t => allHave xs t
  | .struct vs, .record _ ts => fieldsHave vs ts
  | _, _ => false
def allHave : List Value → ETy → Bool
  | [], _ => true
  | x :: xs, t => HasType x t && allHave xs t
def fieldsHave : List Value → List ETy → Bool
  | [], [] => true
  | v :: vs, t :: ts => HasType v t && fieldsHave vs ts
  | _, _ => false
end

mutual
/-- The term of a value of type `ty`. -/
def encode : ETy → Value → ResultTerm
  | .int, .int i => .int i
  | .float, .float b => .float b
  | .string, .str s => .str s
  | .bool, .bool b => .const (if b then "tt" else "ff")
  | .list t, .list xs => .list ⟨encodeList t xs⟩
  | .record c ts, .struct vs => match vs with
    | [] => .const c
    | _ => .app c ⟨encodeFields ts vs⟩
  | _, _ => .unbound
def encodeList (t : ETy) : List Value → List ResultTerm
  | [] => []
  | x :: xs => encode t x :: encodeList t xs
def encodeFields : List ETy → List Value → List ResultTerm
  | t :: ts, v :: vs => encode t v :: encodeFields ts vs
  | _, _ => []
end

mutual
/-- The value of a term of type `ty`. -/
def decode : ETy → ResultTerm → Option Value
  | .int, .int i => some (.int i)
  | .float, .float b => some (.float b)
  | .string, .str s => some (.str s)
  | .bool, .const "tt" => some (.bool true)
  | .bool, .const "ff" => some (.bool false)
  | .list t, .list ⟨xs⟩ => (decodeList t xs).map .list
  | .record c [], .const h => if h == c then some (.struct []) else none
  | .record c ts, .app h ⟨args⟩ => if h == c then (decodeFields ts args).map .struct else none
  | _, _ => none
def decodeList (t : ETy) : List ResultTerm → Option (List Value)
  | [] => some []
  | x :: xs => do return (← decode t x) :: (← decodeList t xs)
def decodeFields : List ETy → List ResultTerm → Option (List Value)
  | [], [] => some []
  | t :: ts, a :: as => do return (← decode t a) :: (← decodeFields ts as)
  | _, _ => none
end

mutual
/-- Decoding the encoding of a well-typed value gives the value back. -/
-- @tg: verifies:: [[openspec:schema-encoding#Value codec round-trip#Every supported type round-trips]] {level: unit}
theorem decode_encode : (v : Value) → (ty : ETy) → HasType v ty = true → decode ty (encode ty v) = some v
  | .int _, .int, _ | .float _, .float, _ | .str _, .string, _ => by simp [encode, decode]
  | .bool b, .bool, _ => by cases b <;> simp [encode, decode]
  | .list xs, .list t, h => by
    simp only [HasType] at h
    simp [encode, decode, decodeList_encodeList xs t h]
  | .struct vs, .record c ts, h => by
    simp only [HasType] at h
    match vs, ts, h with
    | [], [], _ => simp [encode, decode]
    | v :: vs, t :: ts, h =>
      have := decodeFields_encodeFields (v :: vs) (t :: ts) h
      simp only [encode, decode, encodeFields] at this ⊢
      simp [this]
  | .int _, .float, h | .int _, .string, h | .int _, .bool, h | .int _, .list _, h | .int _, .record .., h
  | .float _, .int, h | .float _, .string, h | .float _, .bool, h | .float _, .list _, h | .float _, .record .., h
  | .str _, .int, h | .str _, .float, h | .str _, .bool, h | .str _, .list _, h | .str _, .record .., h
  | .bool _, .int, h | .bool _, .float, h | .bool _, .string, h | .bool _, .list _, h | .bool _, .record .., h
  | .list _, .int, h | .list _, .float, h | .list _, .string, h | .list _, .bool, h | .list _, .record .., h
  | .struct _, .int, h | .struct _, .float, h | .struct _, .string, h | .struct _, .bool, h | .struct _, .list _, h
  | .null, _, h => by simp [HasType] at h
theorem decodeList_encodeList : (xs : List Value) → (t : ETy) → allHave xs t = true →
    decodeList t (encodeList t xs) = some xs
  | [], _, _ => by simp [encodeList, decodeList]
  | x :: xs, t, h => by
    simp only [allHave, Bool.and_eq_true] at h
    simp [encodeList, decodeList, decode_encode x t h.1, decodeList_encodeList xs t h.2]
theorem decodeFields_encodeFields : (vs : List Value) → (ts : List ETy) → fieldsHave vs ts = true →
    decodeFields ts (encodeFields ts vs) = some vs
  | [], [], _ => by simp [encodeFields, decodeFields]
  | v :: vs, t :: ts, h => by
    simp only [fieldsHave, Bool.and_eq_true] at h
    simp [encodeFields, decodeFields, decode_encode v t h.1, decodeFields_encodeFields vs ts h.2]
  | [], _ :: _, h | _ :: _, [], h => by simp [fieldsHave] at h
end

/-- The term of a value, or why it has none. A null inside a LIST or STRUCT has no term. -/
-- @tg: implements:: [[openspec:schema-encoding#Value codec round-trip]]
def encodeChecked (ty : ETy) (v : Value) : Except String ResultTerm :=
  if HasType v ty then .ok (encode ty v)
  else .error s!"value {repr v} is not a {ty.render} (a NULL inside a LIST or STRUCT is not supported)"

/-- The node with primary key `key`: the table's constructor applied to it. -/
def node (ctor : String) (keyTy : ETy) (key : Value) : Except String ResultTerm := do
  return .app ctor #[← encodeChecked keyTy key]

/-- The edge with internal id `id`. -/
def edge (ctor : String) (id : Int) : ResultTerm := .app ctor #[.int id]

/-! ### Columns of typed entry points

An argument of a predicate called by `elpi_run` maps to a column: `int` to INT64, `float` to
DOUBLE, `string` to STRING, `bool` to BOOL, `list T` to a LIST, a generated record kind to a
STRUCT, a node kind to its table's primary key and an edge kind to the edge's internal id. -/

/-- A scalar column: its terms are literals (or `tt`/`ff`); `lty` is its LadybugDB type. -/
inductive Base where
  | int (lty : LType)
  | float (lty : LType)
  | string
  | bool
  deriving Repr, Inhabited, BEq

/-- The terms of an argument and the column they become. -/
inductive Col where
  | base (b : Base)
  | list (elem : Col)
  /-- A generated record kind: constructor, STRUCT field names and field columns. -/
  | record (ctor : String) (names : List String) (fields : List Col)
  /-- A node kind: the table's constructor applied to the primary key. -/
  | node (ctor : String) (key : Base)
  /-- An edge kind: the rel table's constructor applied to the internal id. -/
  | edge (ctor : String)
  deriving Repr, Inhabited, BEq

def Base.lty : Base → LType
  | .int l | .float l => l
  | .string => .string
  | .bool => .bool

def Base.render : Base → String
  | .int _ => "int"
  | .float _ => "float"
  | .string => "string"
  | .bool => "bool"

namespace Col

/-- The column's LadybugDB type. -/
partial def lty : Col → LType
  | .base b => b.lty
  | .list e => .list e.lty
  | .record _ ns fs => .struct (ns.zip (fs.map lty))
  | .node _ k => k.lty
  | .edge _ => .int "INT64"

/-- The ELPI type the column stands for, for messages. -/
partial def render : Col → String
  | .base b => b.render
  | .list e => "(list " ++ e.render ++ ")"
  | .record c _ _ | .node c _ | .edge c => c

/-- The column type for the shim, in prefix form: a scalar type name, `LIST` and the element,
or `STRUCT`, the field count, then each field's name and type. -/
partial def ltyTokens : LType → List String
  | .list e => "LIST" :: ltyTokens e
  | .struct fs => "STRUCT" :: toString fs.length :: fs.flatMap fun (n, t) => n :: ltyTokens t
  | t => [t.render]

end Col

def baseOfLType : LType → Option Base
  | .int n => some (.int (.int n))
  | .date => some (.int .date)
  | .timestamp => some (.int .timestamp)
  | .float n => some (.float (.float n))
  | .string => some .string
  | .bool => some .bool
  | _ => none

/-- The column of a property type at `path` of `table`; record constructors are named as the
signature names them (`mapType`). -/
partial def colOfLType (table : String) (path : List String) : LType → Option Col
  | .list e => (colOfLType table path e).map .list
  | .struct fs => do
    let cols ← fs.mapM fun (f, t) => colOfLType table (path ++ [f]) t
    some (.record (Origin.record table path).ident (fs.map (·.1)) cols)
  | t => (baseOfLType t).map .base

/-- The column of a predicate argument type, or `none` when it has no column mapping (a type
variable, a function type, a union endpoint kind, `severity`, `subject`, …). -/
partial def colOfTy (sig : Signature) : Elpi.Host.TyTerm → Option Col
  | .const "int" => some (.base (.int (.int "INT64")))
  | .const "float" => some (.base (.float (.float "DOUBLE")))
  | .const "string" => some (.base .string)
  | .const "bool" => some (.base .bool)
  | .app "list" [e] => (colOfTy sig e).map .list
  | .const k =>
    match sig.plan.nodes.find? (·.id == k) with
    | some n => (baseOfLType n.keyLty).map (.node k)
    | none =>
      if sig.plan.rels.any (·.id == k) then some (.edge k)
      else
        let recs := sig.plan.nodes.flatMap (·.records) ++ sig.plan.rels.flatMap (·.records)
        match recs.find? (·.ctor == k) with
        | some { origin := .record t path, lty, .. } => colOfLType t path lty
        | _ => none
  | _ => none

/-! ### Typed codec -/

def hasBase : Value → Base → Bool
  | .int _, .int _ | .float _, .float _ | .str _, .string | .bool _, .bool => true
  | _, _ => false

def encodeBase : Base → Value → ResultTerm
  | .int _, .int i => .int i
  | .float _, .float b => .float b
  | .string, .str s => .str s
  | .bool, .bool b => .const (if b then "tt" else "ff")
  | _, _ => .unbound

def decodeBase : Base → ResultTerm → Option Value
  | .int _, .int i => some (.int i)
  | .float _, .float b => some (.float b)
  | .string, .str s => some (.str s)
  | .bool, .const "tt" => some (.bool true)
  | .bool, .const "ff" => some (.bool false)
  | _, _ => none

mutual
/-- Whether a value fits a column; a null nowhere inside. -/
def HasTypeC : Value → Col → Bool
  | .list xs, .list c => allHaveC xs c
  | .struct vs, .record _ _ cs => fieldsHaveC vs cs
  | v, .base b => hasBase v b
  | v, .node _ k => hasBase v k
  | .int _, .edge _ => true
  | _, _ => false
def allHaveC : List Value → Col → Bool
  | [], _ => true
  | x :: xs, c => HasTypeC x c && allHaveC xs c
def fieldsHaveC : List Value → List Col → Bool
  | [], [] => true
  | v :: vs, c :: cs => HasTypeC v c && fieldsHaveC vs cs
  | _, _ => false
end

mutual
/-- The term of a value in a column. -/
def encodeC : Col → Value → ResultTerm
  | .list c, .list xs => .list ⟨encodeListC c xs⟩
  | .record c _ [], _ => .const c
  | .record c _ cs, .struct vs => .app c ⟨encodeFieldsC cs vs⟩
  | .base b, v => encodeBase b v
  | .node c k, v => .app c #[encodeBase k v]
  | .edge c, .int i => .app c #[.int i]
  | _, _ => .unbound
def encodeListC (c : Col) : List Value → List ResultTerm
  | [] => []
  | x :: xs => encodeC c x :: encodeListC c xs
def encodeFieldsC : List Col → List Value → List ResultTerm
  | c :: cs, v :: vs => encodeC c v :: encodeFieldsC cs vs
  | _, _ => []
end

mutual
/-- The value of a term in a column. -/
def decodeC : Col → ResultTerm → Option Value
  | .list c, .list ⟨xs⟩ => (decodeListC c xs).map .list
  | .record c _ [], .const h => if h == c then some (.struct []) else none
  | .record c _ (f :: fs), .app h ⟨args⟩ => if h == c then (decodeFieldsC (f :: fs) args).map .struct else none
  | .base b, t => decodeBase b t
  | .node c k, .app h ⟨[a]⟩ => if h == c then decodeBase k a else none
  | .edge c, .app h ⟨[.int i]⟩ => if h == c then some (.int i) else none
  | _, _ => none
def decodeListC (c : Col) : List ResultTerm → Option (List Value)
  | [] => some []
  | x :: xs => do return (← decodeC c x) :: (← decodeListC c xs)
def decodeFieldsC : List Col → List ResultTerm → Option (List Value)
  | [], [] => some []
  | c :: cs, a :: as => do return (← decodeC c a) :: (← decodeFieldsC cs as)
  | _, _ => none
end

theorem decodeBase_encodeBase (v : Value) (b : Base) (h : hasBase v b = true) :
    decodeBase b (encodeBase b v) = some v := by
  cases v <;> cases b <;> simp_all [hasBase, encodeBase, decodeBase]
  rename_i x; cases x <;> rfl

mutual
/-- Decoding the encoding of a value that fits a column gives the value back, for every column
type with a mapping. -/
-- @tg: verifies:: [[openspec:rule-execution#Typed entry points#Strings round-trip without printing]] {level: unit}
theorem value_roundtrip : (v : Value) → (c : Col) → HasTypeC v c = true →
    decodeC c (encodeC c v) = some v
  | v, .base b, h => by
    have hb : hasBase v b = true := by cases v <;> simpa [HasTypeC] using h
    simpa [encodeC, decodeC] using decodeBase_encodeBase v b hb
  | v, .node c k, h => by
    have hb : hasBase v k = true := by cases v <;> simpa [HasTypeC] using h
    simp [encodeC, decodeC, decodeBase_encodeBase v k hb]
  | .int i, .edge c, _ => by simp [encodeC, decodeC]
  | .list xs, .list c, h => by
    simp only [HasTypeC] at h
    simp [encodeC, decodeC, decodeListC_encodeListC xs c h]
  | .struct vs, .record c ns cs, h => by
    simp only [HasTypeC] at h
    match vs, cs, h with
    | [], [], _ => simp [encodeC, decodeC]
    | v :: vs, f :: fs, h =>
      have := decodeFieldsC_encodeFieldsC (v :: vs) (f :: fs) h
      simp only [encodeC, decodeC] at this ⊢
      simp [this]
  | .float _, .edge _, h | .str _, .edge _, h | .bool _, .edge _, h | .list _, .edge _, h
  | .struct _, .edge _, h | .null, .edge _, h
  | .int _, .list _, h | .float _, .list _, h | .str _, .list _, h | .bool _, .list _, h
  | .struct _, .list _, h | .null, .list _, h
  | .int _, .record .., h | .float _, .record .., h | .str _, .record .., h | .bool _, .record .., h
  | .list _, .record .., h | .null, .record .., h => by simp [HasTypeC] at h
theorem decodeListC_encodeListC : (xs : List Value) → (c : Col) → allHaveC xs c = true →
    decodeListC c (encodeListC c xs) = some xs
  | [], _, _ => by simp [encodeListC, decodeListC]
  | x :: xs, c, h => by
    simp only [allHaveC, Bool.and_eq_true] at h
    simp [encodeListC, decodeListC, value_roundtrip x c h.1, decodeListC_encodeListC xs c h.2]
theorem decodeFieldsC_encodeFieldsC : (vs : List Value) → (cs : List Col) → fieldsHaveC vs cs = true →
    decodeFieldsC cs (encodeFieldsC cs vs) = some vs
  | [], [], _ => by simp [encodeFieldsC, decodeFieldsC]
  | v :: vs, c :: cs, h => by
    simp only [fieldsHaveC, Bool.and_eq_true] at h
    simp [encodeFieldsC, decodeFieldsC, value_roundtrip v c h.1, decodeFieldsC_encodeFieldsC vs cs h.2]
  | [], _ :: _, h | _ :: _, [], h => by simp [fieldsHaveC] at h
end

/-- A parameter value as the term of an input argument, or why it does not fit. -/
def encodeParam (c : Col) (v : Value) : Except String ResultTerm :=
  if HasTypeC v c then .ok (encodeC c v) else .error s!"expected a value of type {c.render}"

/-! ### Subjects -/

/-- One constructor of the `subject` union: the table, `subj_<table>`, and the column of the
node or edge it wraps. -/
structure SubjectCase where
  label : String
  ctor : String
  col : Col
  deriving Repr, Inhabited

/-- The subject cases of a signature: every encoded node table with a scalar key, every rel
table. -/
def subjectCases (sig : Signature) : List SubjectCase :=
  sig.plan.nodes.filterMap (fun n => (baseOfLType n.keyLty).map fun k =>
    { label := n.name, ctor := (Origin.subject n.name).ident, col := .node n.id k }) ++
  sig.plan.rels.map fun r => { label := r.name, ctor := (Origin.subject r.name).ident, col := .edge r.id }

/-- The `subject` term of a table label and a key (an internal id for an edge). -/
def encodeSubject (cases : List SubjectCase) (label : String) (key : Value) : Option ResultTerm := do
  let c ← cases.find? (·.label == label)
  if HasTypeC key c.col then some (.app c.ctor #[encodeC c.col key]) else none

/-- The table label and key of a `subject` term. -/
-- @tg: implements:: [[openspec:validation#Subject union kind]]
def decodeSubject (cases : List SubjectCase) : ResultTerm → Option (String × Value)
  | .app h ⟨[a]⟩ => do
    let c ← cases.find? (·.ctor == h)
    return (c.label, ← decodeC c.col a)
  | _ => none

private theorem find_unique {cases : List SubjectCase} {f : SubjectCase → String} {c : SubjectCase}
    (hc : c ∈ cases) (huniq : ∀ a ∈ cases, ∀ b ∈ cases, f a = f b → a = b) :
    cases.find? (f · == f c) = some c := by
  cases h : cases.find? (f · == f c) with
  | none => simp [List.find?_eq_none] at h; exact absurd rfl (h c hc)
  | some d =>
    have hd := List.find?_some h
    have hm := List.mem_of_find?_eq_some h
    simp at hd
    rw [huniq d hm c hc hd]

/-- Encoding a (label, key) pair of an existing table and decoding it gives the pair back,
when constructors and labels are unique (the signature's names are injective). -/
-- @tg: verifies:: [[openspec:validation#Subject union kind#Subject codec round-trips]] {level: unit}
theorem subject_decode_encode {cases : List SubjectCase} {label : String} {key : Value}
    {t : ResultTerm}
    (hctor : ∀ a ∈ cases, ∀ b ∈ cases, a.ctor = b.ctor → a = b)
    (h : encodeSubject cases label key = some t) : decodeSubject cases t = some (label, key) := by
  simp only [encodeSubject, Option.bind_eq_bind] at h
  cases hf : cases.find? (·.label == label) with
  | none => simp [hf] at h
  | some c =>
    simp only [hf, Option.bind_some] at h
    split at h
    · rename_i hty
      cases h
      have hl : c.label = label := by simpa using List.find?_some hf
      have hc := List.mem_of_find?_eq_some hf
      simp [decodeSubject, find_unique (f := SubjectCase.ctor) hc hctor, value_roundtrip key c.col hty, hl]
    · contradiction

theorem decodeBase_sound {b : Base} {t : ResultTerm} {v : Value} (h : decodeBase b t = some v) :
    hasBase v b = true ∧ encodeBase b v = t := by
  unfold decodeBase at h
  split at h <;> (cases h <;> simp [hasBase, encodeBase])

mutual
/-- A term that decodes is the encoding of its value, which fits the column. -/
theorem decodeC_sound : (c : Col) → (t : ResultTerm) → (v : Value) → decodeC c t = some v →
    HasTypeC v c = true ∧ encodeC c v = t
  | .base b, t, v, h => by
    have hb : decodeBase b t = some v := by simpa [decodeC] using h
    have := decodeBase_sound hb
    constructor
    · cases v <;> simpa [HasTypeC] using this.1
    · simpa [encodeC] using this.2
  | .node c k, t, v, h => by
    unfold decodeC at h
    split at h
    all_goals first
      | contradiction
      | (rename_i hcol
         cases hcol
         split at h
         · rename_i heq
           have := decodeBase_sound h
           simp at heq
           subst heq
           exact ⟨by cases v <;> simpa [HasTypeC] using this.1, by simp [encodeC, this.2]⟩
         · contradiction)
  | .edge c, t, v, h => by
    unfold decodeC at h
    split at h
    all_goals first
      | contradiction
      | (rename_i hcol
         cases hcol
         split at h
         · rename_i heq; simp at heq; subst heq; cases h; simp [HasTypeC, encodeC]
         · contradiction)
  | .list c, t, v, h => by
    match t with
    | .list ⟨xs⟩ =>
      simp only [decodeC, Option.map_eq_some_iff] at h
      obtain ⟨vs, hvs, rfl⟩ := h
      have := decodeListC_sound c xs vs hvs
      exact ⟨by simpa [HasTypeC] using this.1, by simp [encodeC, this.2]⟩
    | .app .. | .const _ | .int _ | .float _ | .str _ | .unbound | .lam | .opaque .. =>
      simp [decodeC] at h
  | .record c ns [], t, v, h => by
    match t with
    | .const hd =>
      simp only [decodeC] at h
      split at h
      · rename_i heq; simp at heq; subst heq; cases h; simp [HasTypeC, fieldsHaveC, encodeC]
      · contradiction
    | .app .. | .list _ | .int _ | .float _ | .str _ | .unbound | .lam | .opaque .. =>
      simp [decodeC] at h
  | .record c ns (f :: fs), t, v, h => by
    match t with
    | .app hd ⟨args⟩ =>
      simp only [decodeC] at h
      split at h
      · rename_i heq
        simp at heq; subst heq
        simp only [Option.map_eq_some_iff] at h
        obtain ⟨vs, hvs, rfl⟩ := h
        have := decodeFieldsC_sound (f :: fs) args vs hvs
        refine ⟨by simpa [HasTypeC] using this.1, ?_⟩
        match vs, this with
        | [], ⟨hf, _⟩ => simp [fieldsHaveC] at hf
        | _ :: _, ⟨_, he⟩ => simp [encodeC, he]
      · contradiction
    | .const _ | .list _ | .int _ | .float _ | .str _ | .unbound | .lam | .opaque .. =>
      simp [decodeC] at h
theorem decodeListC_sound : (c : Col) → (xs : List ResultTerm) → (vs : List Value) →
    decodeListC c xs = some vs → allHaveC vs c = true ∧ encodeListC c vs = xs
  | _, [], vs, h => by simp [decodeListC] at h; subst h; simp [allHaveC, encodeListC]
  | c, x :: xs, vs, h => by
    simp only [decodeListC, Option.bind_eq_bind, Option.bind_eq_some_iff, Option.pure_def,
      Option.some.injEq] at h
    obtain ⟨v, hv, ws, hws, rfl⟩ := h
    have h1 := decodeC_sound c x v hv
    have h2 := decodeListC_sound c xs ws hws
    simp [allHaveC, encodeListC, h1.1, h1.2, h2.1, h2.2]
theorem decodeFieldsC_sound : (cs : List Col) → (as : List ResultTerm) → (vs : List Value) →
    decodeFieldsC cs as = some vs → fieldsHaveC vs cs = true ∧ encodeFieldsC cs vs = as
  | [], [], vs, h => by simp [decodeFieldsC] at h; subst h; simp [fieldsHaveC, encodeFieldsC]
  | c :: cs, a :: as, vs, h => by
    simp only [decodeFieldsC, Option.bind_eq_bind, Option.bind_eq_some_iff, Option.pure_def,
      Option.some.injEq] at h
    obtain ⟨v, hv, ws, hws, rfl⟩ := h
    have h1 := decodeC_sound c a v hv
    have h2 := decodeFieldsC_sound cs as ws hws
    simp [fieldsHaveC, encodeFieldsC, h1.1, h1.2, h2.1, h2.2]
  | [], _ :: _, _, h | _ :: _, [], _, h => by simp [decodeFieldsC] at h
end

/-- A `subject` term that decodes is the encoding of its (label, key) pair, when labels and
constructors are unique. -/
-- @tg: verifies:: [[openspec:validation#Subject union kind#Subject decodes to label and key]] {level: unit}
theorem subject_encode_decode {cases : List SubjectCase} {t : ResultTerm} {label : String}
    {key : Value}
    (hlabel : ∀ a ∈ cases, ∀ b ∈ cases, a.label = b.label → a = b)
    (h : decodeSubject cases t = some (label, key)) : encodeSubject cases label key = some t := by
  match t with
  | .app hd ⟨[a]⟩ =>
    simp only [decodeSubject, Option.bind_eq_bind, Option.bind_eq_some_iff] at h
    obtain ⟨c, hc, h⟩ := h
    simp only [Option.bind_eq_bind, Option.bind_eq_some_iff, Option.pure_def, Option.some.injEq,
      Prod.mk.injEq] at h
    obtain ⟨v, hv, rfl, rfl⟩ := h
    have hd : c.ctor = hd := by simpa using List.find?_some hc
    have hm := List.mem_of_find?_eq_some hc
    have := decodeC_sound c.col a v hv
    simp [encodeSubject, find_unique (f := SubjectCase.label) hm hlabel, this.1, this.2, hd]
  | .app _ ⟨[]⟩ | .app _ ⟨_ :: _ :: _⟩ | .const _ | .int _ | .float _ | .str _ | .list _
  | .unbound | .lam | .opaque .. => simp [decodeSubject] at h

end Codec

end Marien.Encoding
