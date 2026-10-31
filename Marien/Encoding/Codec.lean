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

end Codec

end Marien.Encoding
