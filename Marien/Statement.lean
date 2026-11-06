import Marien.Store.Literal

/-!
# Custom statements

The statement syntax over the `CALL` functions:

```
CREATE [OR REPLACE] RULES <name> AS $$<source>$$      -- elpi_save(name, source)
DROP RULES <name>                                       -- elpi_drop(name)
CHECK RULES                                             -- elpi_recheck()
VALIDATE [<name>, …] [MIN SEVERITY <severity>]          -- elpi_validate(…)
ANNOTATE <table> SET <key> = '<value>'                  -- elpi_annotate(table, key, value)
```

A statement has no logic of its own: `parse` reads it and `desugar` maps it to exactly one `CALL`
form (`desugar_total`), whose arguments the shim passes as literal values, so the statement and
its `CALL` form share binding, plan, rows and errors. `CREATE` and `CREATE OR REPLACE` both save a
new version, as `elpi_save` does. `VALIDATE … MIN SEVERITY` needs module names: `elpi_validate` has
no form for every module at a severity, so the statement refuses it rather than invent one.

The source between dollar delimiters is taken byte for byte (`source_roundtrip`): no escape is
read, so quotes, backslashes and lone `$` survive. A source containing `$$` uses a tagged
delimiter `$tag$…$tag$`. Names are identifiers or single-quoted Cypher strings; values are
single-quoted Cypher strings, read with the same unescaping as LadybugDB (`Store.Literal.lexBody`).

LadybugDB 0.22.1 routes no new syntax to extensions (only `CREATE USER` and `CREATE ROLE` reach
extension parsers), so the shim registers the statement parser for when the grammar does, and
`CALL elpi_statement('<statement>')` runs a statement through its `CALL` form today.
-/

-- @lat: [[components#Statement extension]]

namespace Marien.Statement

inductive Statement where
  | createRules (name source : String) (orReplace : Bool)
  | dropRules (name : String)
  | checkRules
  | validate (modules : List String) (minSeverity : Option String)
  | annotate (table key value : String)
  deriving Repr, Inhabited, BEq, DecidableEq

/-- A literal argument of a `CALL` form. -/
inductive Arg where
  | str (s : String)
  | strs (xs : List String)
  deriving Repr, Inhabited, BEq, DecidableEq

/-- A `CALL` form: the function, its literal arguments, and whether it returns rows (a table
function, called as `CALL f(…) RETURN *`) or is a standalone write function. -/
structure Call where
  fn : String
  args : List Arg
  rows : Bool
  deriving Repr, Inhabited, BEq, DecidableEq

/-! ### Desugaring -/

/-- The `CALL` form of a statement. -/
-- @tg: implements:: [[openspec:custom-statements#Statements equal their CALL forms]]
def desugar : Statement → Call
  | .createRules n src _ => ⟨"elpi_save", [.str n, .str src], false⟩
  | .dropRules n => ⟨"elpi_drop", [.str n], false⟩
  | .checkRules => ⟨"elpi_recheck", [], false⟩
  | .validate [] _ => ⟨"elpi_validate", [], true⟩
  | .validate ms none => ⟨"elpi_validate", [.strs ms], true⟩
  | .validate ms (some s) => ⟨"elpi_validate", [.strs ms, .str s], true⟩
  | .annotate t k v => ⟨"elpi_annotate", [.str t, .str k, .str v], false⟩

/-- The five functions statements desugar to. -/
def callFunctions : List String := ["elpi_save", "elpi_drop", "elpi_recheck", "elpi_validate", "elpi_annotate"]

/-- Every statement maps to exactly one `CALL` form, of one of the five functions; the save's
source and the annotation's value are passed as they were read. -/
-- @tg: verifies:: [[openspec:custom-statements#Statements equal their CALL forms]] {level: unit}
theorem desugar_total (s : Statement) :
    (∀ c₁ c₂, desugar s = c₁ → desugar s = c₂ → c₁ = c₂) ∧ (desugar s).fn ∈ callFunctions := by
  refine ⟨fun _ _ h₁ h₂ => h₁ ▸ h₂, ?_⟩
  cases s with
  | validate ms sev => cases ms <;> cases sev <;> simp [desugar, callFunctions]
  | _ => simp [desugar, callFunctions]

theorem desugar_save (n src : String) (r : Bool) :
    desugar (.createRules n src r) = ⟨"elpi_save", [.str n, .str src], false⟩ := rfl

/-- The `CALL` form as Cypher text, every string an escaped literal (`Store.Literal.quote`, proved to
read back byte for byte). -/
def Call.cypher (c : Call) : String :=
  let arg : Arg → String
    | .str s => Store.Literal.quote s
    | .strs xs => "[" ++ ", ".intercalate (xs.map Store.Literal.quote) ++ "]"
  s!"CALL {c.fn}({", ".intercalate (c.args.map arg)})" ++ (if c.rows then " RETURN *" else "")

/-! ### The dollar-quote lexer -/

def isTagChar (c : Char) : Bool := c.isAlphanum || c == '_'

/-- The characters up to the first occurrence of the delimiter `d`, and the rest after it. -/
def scanTo (d : List Char) (acc : List Char) : List Char → Option (List Char × List Char)
  | [] => none
  | c :: cs =>
    if d.isPrefixOf (c :: cs) then some (acc.reverse, (c :: cs).drop d.length)
    else scanTo d (c :: acc) cs

/-- A dollar-quoted string `$tag$…$tag$` at the head of `cs`: its body and the text after it. -/
-- @tg: implements:: [[openspec:custom-statements#Statement source is not re-escaped]]
def dollarQuoted : List Char → Option (List Char × List Char)
  | '$' :: cs =>
    match cs.dropWhile isTagChar with
    | '$' :: body => scanTo ('$' :: cs.takeWhile isTagChar ++ ['$']) [] body
    | _ => none
  | _ => none

/-- The delimiter of a tag. -/
def delim (tag : List Char) : List Char := '$' :: tag ++ ['$']

theorem scanTo_body (d rest : List Char) (hd : d ≠ []) :
    ∀ (body acc : List Char), (∀ k < body.length, d.isPrefixOf ((body ++ d ++ rest).drop k) = false) →
      scanTo d acc (body ++ d ++ rest) = some (acc.reverse ++ body, rest)
  | [], acc, _ => by
    cases d with
    | nil => exact absurd rfl hd
    | cons x xs =>
      have hp : (x :: xs).isPrefixOf (x :: (xs ++ rest)) = true := by
        rw [← List.cons_append]; exact List.isPrefixOf_iff_prefix.mpr (List.prefix_append _ _)
      simp only [List.nil_append, List.cons_append, scanTo, hp, ite_true, List.append_nil]
      rw [← List.cons_append, List.drop_left]
  | b :: bs, acc, h => by
    have h0 : d.isPrefixOf (b :: (bs ++ d ++ rest)) = false := by simpa using h 0 (by simp)
    simp only [List.cons_append, scanTo, h0, Bool.false_eq_true, ite_false]
    rw [scanTo_body d rest hd bs (b :: acc) (fun k hk => by
      have := h (k + 1) (by simp; omega)
      simpa using this)]
    simp

theorem takeWhile_tag (tag rest : List Char) (ht : ∀ c ∈ tag, isTagChar c = true) :
    (tag ++ '$' :: rest).takeWhile isTagChar = tag ∧ (tag ++ '$' :: rest).dropWhile isTagChar = '$' :: rest := by
  induction tag with
  | nil => simp [isTagChar]
  | cons c cs ih =>
    have hc := ht c (by simp)
    have ih' := ih (fun x hx => ht x (by simp [hx]))
    simp [hc, ih'.1, ih'.2]

/-- The body between two delimiters comes back unchanged, whatever bytes it holds, as long as
no delimiter starts inside it. -/
-- @tg: verifies:: [[openspec:custom-statements#Statement source is not re-escaped#Quotes and backslashes survive]] {level: unit}
theorem source_roundtrip (tag body rest : List Char) (ht : ∀ c ∈ tag, isTagChar c = true)
    (hb : ∀ k < body.length, (delim tag).isPrefixOf ((body ++ delim tag ++ rest).drop k) = false) :
    dollarQuoted (delim tag ++ body ++ delim tag ++ rest) = some (body, rest) := by
  have hsplit : delim tag ++ body ++ delim tag ++ rest = '$' :: (tag ++ '$' :: (body ++ delim tag ++ rest)) := by
    simp [delim, List.append_assoc]
  rw [hsplit]
  obtain ⟨h1, h2⟩ := takeWhile_tag tag (body ++ delim tag ++ rest) ht
  simp only [dollarQuoted, h1, h2]
  have := scanTo_body (delim tag) rest (by simp [delim]) body [] hb
  simpa [delim] using this

/-! ### The parser -/

/-- Characters, and the keyword-insensitive reading of the statement grammar. -/
abbrev P := StateT (List Char) (Except String)

def skipWs : P Unit := modify (·.dropWhile Char.isWhitespace)

def isIdentStart (c : Char) : Bool := c.isAlpha || c == '_'
def isIdentChar (c : Char) : Bool := c.isAlphanum || c == '_'

/-- The next word, without consuming it. -/
def peekWord : P String := do
  let cs := (← get).dropWhile Char.isWhitespace
  return String.ofList (cs.takeWhile isIdentChar)

/-- Consume the keyword `kw` (any case), or fail with `what`. -/
def keyword (kw : String) (what : String := s!"expected {kw}") : P Unit := do
  skipWs
  let cs ← get
  let w := cs.takeWhile isIdentChar
  if (String.ofList w).toUpper == kw then set (cs.drop w.length) else throw what

def tryKeyword (kw : String) : P Bool := do
  if (← peekWord).toUpper == kw then keyword kw; return true
  return false

/-- A single-quoted Cypher string, unescaped as LadybugDB does. -/
def quoted (what : String) : P String := do
  skipWs
  match ← get with
  | '\'' :: cs =>
    match Store.Literal.lexBody cs with
    | some (body, rest) => set rest; return String.ofList body
    | none => throw s!"unterminated or badly escaped string literal in {what}"
  | _ => throw s!"expected a quoted string for {what}"

/-- A name: an identifier, a backquoted name or a single-quoted string. -/
def name (what : String) : P String := do
  skipWs
  match ← get with
  | '\'' :: _ => quoted what
  | '`' :: cs =>
    let n := cs.takeWhile (· != '`')
    if (cs.drop n.length).head? != some '`' then throw s!"unterminated `name` for {what}"
    set (cs.drop (n.length + 1))
    if n.isEmpty then throw s!"missing {what}"
    return String.ofList n
  | c :: cs =>
    if !isIdentStart c then throw s!"missing {what}"
    let n := c :: cs.takeWhile isIdentChar
    -- a keyword where the name belongs means the name is missing
    if ["AS", "SET", "MIN"].contains (String.ofList n).toUpper then throw s!"missing {what}"
    set (cs.drop (n.length - 1))
    return String.ofList n
  | [] => throw s!"missing {what}"

def source : P String := do
  skipWs
  match dollarQuoted (← get) with
  | some (body, rest) => set rest; return String.ofList body
  | none =>
    match ← get with
    | '$' :: _ => throw "unterminated rule source: no closing delimiter (a source containing $$ needs $tag$…$tag$)"
    | _ => throw "expected the rule source between $$ delimiters"

def endOfStatement : P Unit := do
  skipWs
  match ← get with
  | [] => pure ()
  | [';'] => set ([] : List Char)
  | cs => throw s!"unexpected text after the statement: {String.ofList (cs.take 20)}"

def statementP : P Statement := do
  let w := (← peekWord).toUpper
  match w with
  | "CREATE" =>
    keyword "CREATE"
    let orReplace ← tryKeyword "OR"
    if orReplace then keyword "REPLACE" "expected REPLACE after CREATE OR"
    keyword "RULES"
    let n ← name "module name"
    keyword "AS" s!"expected AS after the module name {n}"
    let src ← source
    endOfStatement
    return .createRules n src orReplace
  | "DROP" =>
    keyword "DROP"; keyword "RULES"
    let n ← name "module name"
    endOfStatement
    return .dropRules n
  | "CHECK" =>
    keyword "CHECK"; keyword "RULES"
    endOfStatement
    return .checkRules
  | "VALIDATE" =>
    keyword "VALIDATE"
    let mut ms : List String := []
    if (← peekWord).toUpper != "MIN" then
      skipWs
      let cs : List Char ← get
      if !cs.isEmpty && cs != [';'] then
        ms := [← name "module name"]
        repeat
          skipWs
          let cs : List Char ← get
          match cs with
          | ',' :: rest =>
            set rest
            let n ← name "module name"
            ms := ms ++ [n]
          | _ => break
    let sev ← if ← tryKeyword "MIN" then do
        keyword "SEVERITY" "expected SEVERITY after MIN"
        if ms.isEmpty then
          throw "VALIDATE … MIN SEVERITY needs module names: elpi_validate has no form for every module at a severity"
        pure (some (← name "severity"))
      else pure none
    endOfStatement
    return .validate ms sev
  | "ANNOTATE" =>
    keyword "ANNOTATE"
    let t ← name "table name"
    keyword "SET" "expected SET after the table name"
    let k ← name "annotation key"
    skipWs
    match ← get with
    | '=' :: rest => set rest
    | _ => throw "expected = after the annotation key"
    let v ← quoted "annotation value"
    endOfStatement
    return .annotate t k v
  | _ => throw "not a Marien statement"

/-- Whether a statement text starts like one of Marien's statements; any other text belongs to
LadybugDB or to another extension. -/
def isMarien (text : String) : Bool :=
  let ws := ((text.splitToList fun c => c.isWhitespace || c == ';').filter (· ≠ "")).map String.toUpper
  match ws with
  | "CREATE" :: "RULES" :: _ | "CREATE" :: "OR" :: "REPLACE" :: "RULES" :: _ | "DROP" :: "RULES" :: _
  | "CHECK" :: "RULES" :: _ | "VALIDATE" :: _ | "ANNOTATE" :: _ => true
  | _ => false

/-- Parse one statement. -/
-- @tg: implements:: [[openspec:custom-statements#Rule statements]]
def parse (text : String) : Except String Statement :=
  (statementP.run text.toList).map (·.1)

end Marien.Statement
