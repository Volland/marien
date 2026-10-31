/-!
# Cypher string literals

Module sources travel inside the Cypher statement that `rewriteFunc` returns, as single-quoted
string literals. This file models how LadybugDB lexes such a literal (`StringLiteral` in its
`Cypher.g4`, unescaped by `Transformer::transformStringLiteral`) and proves the escaping
function against the model:

* `unescape_escape`: reading the escaped text back gives the source, byte for byte;
* `escape_no_delim`: the escaped text contains no bare `'`, so the literal ends exactly at the
  quote Marien puts after it and nothing in a source can start another clause;
* `literal_extent`: both at once, for a literal followed by any further text.

The model reads code points; Lean strings are valid UTF-8, which is what LadybugDB's lexer
requires. Escaping only touches `\` and `'`; the lexer accepts every other character raw,
including newlines and tabs. The integration tests check the model against the real lexer.
-/

-- @lat: [[components#Module store]]

namespace Marien.Store.Literal

/-- The character an escape sequence `\c` stands for, if `c` is one LadybugDB accepts and
decodes (`\x` is not decoded and `\u` needs hex digits; Marien never emits either). -/
def unescapeChar : Char → Option Char
  | '\\' => some '\\'
  | '\'' => some '\''
  | '"' => some '"'
  | 'b' | 'B' => some '\x08'
  | 'f' | 'F' => some '\x0c'
  | 'n' | 'N' => some '\n'
  | 'r' | 'R' => some '\r'
  | 't' | 'T' => some '\t'
  | _ => none

/-- Lex the body of a single-quoted literal, after its opening quote: the characters it stands
for and the text after its closing quote, or `none` when the text ends first or has a bad
escape. -/
def lexBody : List Char → Option (List Char × List Char)
  | [] => none
  | '\'' :: rest => some ([], rest)
  | '\\' :: c :: rest => do
    let u ← unescapeChar c
    let (cs, r) ← lexBody rest
    return (u :: cs, r)
  | '\\' :: [] => none
  | c :: rest => do
    let (cs, r) ← lexBody rest
    return (c :: cs, r)

/-- Whether a text, placed after an opening quote, contains a quote that would end the literal. -/
def hasBareDelimiter (l : List Char) : Bool := (lexBody l).isSome

def escapeChar : Char → List Char
  | '\\' => ['\\', '\\']
  | '\'' => ['\\', '\'']
  | c => [c]

def escapeList (l : List Char) : List Char := l.flatMap escapeChar

/-- The body of a single-quoted Cypher literal standing for `s`. -/
-- @tg: implements:: [[openspec:rule-storage#Source is stored byte for byte]]
def escape (s : String) : String := String.ofList (escapeList s.toList)

/-- `s` as a single-quoted Cypher literal. -/
def quote (s : String) : String := "'" ++ escape s ++ "'"

/-- What a literal body stands for, if it is exactly one literal body. -/
def unescape (body : String) : Option String :=
  match lexBody (body.toList ++ ['\'']) with
  | some (cs, []) => some (String.ofList cs)
  | _ => none

theorem lexBody_escapeList (cs rest : List Char) :
    lexBody (escapeList cs ++ '\'' :: rest) = some (cs, rest) := by
  induction cs with
  | nil => simp [escapeList, lexBody]
  | cons c cs ih =>
    simp only [escapeList, List.flatMap_cons, List.append_assoc] at ih ⊢
    by_cases h1 : c = '\\'
    · subst h1; simp [escapeChar, lexBody, unescapeChar, ih]
    · by_cases h2 : c = '\''
      · subst h2; simp [escapeChar, lexBody, unescapeChar, ih]
      · have : escapeChar c = [c] := by
          unfold escapeChar; split <;> simp_all
        rw [this]
        simp only [List.singleton_append]
        rw [lexBody.eq_5 c _ h2 (fun _ _ h _ => h1 h) (fun h _ => h1 h)]
        simp [ih]

theorem lexBody_escapeList_none (cs : List Char) : lexBody (escapeList cs) = none := by
  induction cs with
  | nil => simp [escapeList, lexBody]
  | cons c cs ih =>
    simp only [escapeList, List.flatMap_cons] at ih ⊢
    by_cases h1 : c = '\\'
    · subst h1; simp [escapeChar, lexBody, unescapeChar, ih]
    · by_cases h2 : c = '\''
      · subst h2; simp [escapeChar, lexBody, unescapeChar, ih]
      · have : escapeChar c = [c] := by
          unfold escapeChar; split <;> simp_all
        rw [this]
        simp only [List.singleton_append]
        rw [lexBody.eq_5 c _ h2 (fun _ _ h _ => h1 h) (fun h _ => h1 h)]
        simp [ih]

/-- The escaped literal followed by any text lexes as exactly `s`, ending at Marien's quote. -/
theorem literal_extent (s : String) (rest : List Char) :
    lexBody ((escape s).toList ++ '\'' :: rest) = some (s.toList, rest) := by
  simp [escape, lexBody_escapeList]

/-- Unescaping the escaped text gives back the source. -/
-- @tg: verifies:: [[openspec:rule-storage#Source is stored byte for byte#Hostile characters survive]] {level: unit}
theorem unescape_escape (s : String) : unescape (escape s) = some s := by
  simp [unescape, literal_extent]

/-- The escaped text has no quote that would end the literal early. -/
-- @tg: verifies:: [[openspec:rule-storage#Source is stored byte for byte#Source cannot escape its literal]] {level: unit}
theorem escape_no_delim (s : String) : hasBareDelimiter (escape s).toList = false := by
  simp [hasBareDelimiter, escape, lexBody_escapeList_none]

end Marien.Store.Literal
