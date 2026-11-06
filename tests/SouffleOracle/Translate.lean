import Property.Gen

/-!
# Soufflé oracle: fragment classifier and translator

An independent engine for the analyses of M3: a module whose reached clauses lie in the
first-order stratified fragment is translated, with the facts of the generated graph, into a
Soufflé Datalog program. Nothing here uses Marien's or LeanElpi's code: the module text is read
by the small parser below, and the facts come from the generator's graph, not from Marien's
materialization, so a fault in either shows up as a difference.

**Fragment.** Clauses reached from the entry point with no cut, `pi`, `=>`, lambda, list,
higher-order call, call outside the module and the schema, constant edge id or edge subject,
whose variables all get a type and are bound by a positive literal before they are used, and
whose negations are stratified. Anything else is **skipped** with its reason, never translated
approximately.

**Multiplicities.** `elpi_validate` returns one row per solution, so answers are multisets, while
Soufflé relations are sets. Each clause becomes one *proof relation* per branch of its
disjunctive normal form, over its answer columns followed by every variable of the branch, `_`
in a positive literal becoming a fresh variable: one tuple per proof. Projecting the tuples on
the answer columns and keeping duplicates gives ELPI's multiset. Non-recursive module predicates
called positively are unfolded into the branch; a recursive one is outside the fragment (the
number of its derivations is not a Datalog relation). Negation needs only existence: `not G`
becomes `!neg_k(V…)` with `neg_k(V…) :- <earlier literals>, G` over the variables bound before
it, and module predicates under negation are ordinary set relations, recursive or not.
-/

namespace Oracle

open Property

/-! ### Fragment syntax -/

inductive Tm where
  | var (n : String)
  | wild
  | const (c : String)
  | int (i : Int)
  | str (s : String)
  | float (f : String)
  | app (f : String) (args : List Tm)
  | arith (op : String) (a b : Tm)
  deriving Repr, Inhabited, BEq

inductive Goal where
  | atom (p : String) (args : List Tm)
  | conj (gs : List Goal)
  | disj (gs : List Goal)
  | neg (g : Goal)
  | cmp (op : String) (a b : Tm)
  | tru
  /-- A construct outside the fragment, and why. -/
  | outside (why : String)
  deriving Repr, Inhabited

structure Clause where
  pred : String
  args : List Tm
  body : Goal
  deriving Inhabited

/-- What a module says: its clauses, the declared argument types of its predicates, and the
first reason it is outside the fragment as a whole (`accumulate`). -/
structure Module where
  clauses : List Clause := []
  decls : List (String × List String) := []
  outside : Option String := none
  deriving Inhabited

/-! ### Lexer -/

inductive Tok where
  | id (s : String)
  | var (s : String)
  | int (i : Int)
  | float (s : String)
  | str (s : String)
  | sym (s : String)
  deriving Repr, Inhabited, BEq

def isIdChar (c : Char) : Bool := c.isAlphanum || c == '_' || c == '\''

def lex (src : String) : Except String (Array Tok) := Id.run do
  let cs := src.toList.toArray
  let mut i := 0
  let mut out : Array Tok := #[]
  let charAt (j : Nat) : Char := cs[j]?.getD ' '
  while i < cs.size do
    let c := cs[i]!
    if c == '%' then
      while i < cs.size && cs[i]! != '\n' do i := i + 1
    else if c.isWhitespace then i := i + 1
    else if c == '"' then
      let mut s := ""
      i := i + 1
      let mut closed := false
      while i < cs.size && !closed do
        let d := cs[i]!
        if d == '\\' then
          s := s.push (match charAt (i + 1) with | 'n' => '\n' | 't' => '\t' | e => e)
          i := i + 2
        else if d == '"' then closed := true; i := i + 1
        else s := s.push d; i := i + 1
      if !closed then return .error "unterminated string"
      out := out.push (.str s)
    else if c.isDigit then
      let mut s := ""
      while i < cs.size && cs[i]!.isDigit do s := s.push cs[i]!; i := i + 1
      if charAt i == '.' && (charAt (i + 1)).isDigit then
        s := s.push '.'; i := i + 1
        while i < cs.size && cs[i]!.isDigit do s := s.push cs[i]!; i := i + 1
        out := out.push (.float s)
      else out := out.push (.int s.toInt!)
    else if c.isLower then
      let mut s := ""
      -- a `.` belongs to the name when a name character follows it (`t0.p0`, `std.forall`)
      while i < cs.size && (isIdChar cs[i]! || (cs[i]! == '.' && isIdChar (charAt (i + 1)) && !(charAt (i + 1)).isWhitespace)) do
        s := s.push cs[i]!; i := i + 1
      out := out.push (.id s)
    else if c.isUpper || c == '_' then
      let mut s := ""
      while i < cs.size && isIdChar cs[i]! do s := s.push cs[i]!; i := i + 1
      out := out.push (if s == "_" then .sym "_" else .var s)
    else
      let two := String.ofList [c, charAt (i + 1)]
      if [":-", "=>", ">=", "=<", "->", "<="].contains two then
        out := out.push (.sym two); i := i + 2
      else if c == ':' && (charAt (i + 1)).isAlpha then
        -- an attribute (`:index`) or a mode separator (`o:t0`): kept as one symbol
        let mut s := ":"
        i := i + 1
        while i < cs.size && isIdChar cs[i]! do s := s.push cs[i]!; i := i + 1
        out := out.push (.sym s)
      else
        out := out.push (.sym (String.singleton c)); i := i + 1
  return .ok out

/-! ### Parser -/

abbrev P := StateT Nat (ExceptT String (ReaderM (Array Tok)))

def peek : P (Option Tok) := do return (← read)[← get]?
def advance : P Unit := modify (· + 1)
def expectSym (s : String) : P Unit := do
  match ← peek with
  | some (.sym t) => if t == s then advance else throw s!"expected {s}"
  | t => throw s!"expected {s}, got {repr t}"

def startsPrimary : Option Tok → Bool
  | some (.id s) => s != "is"
  | some (.var _) | some (.int _) | some (.float _) | some (.str _) => true
  | some (.sym "(") | some (.sym "_") | some (.sym "[") => true
  | _ => false

mutual
  /-- A term: an application, or a primary. -/
  partial def term : P Tm := do
    match ← peek with
    | some (.id f) =>
      advance
      let mut args := #[]
      while startsPrimary (← peek) do args := args.push (← primary)
      return if args.isEmpty then .const f else .app f args.toList
    | some (.var v) =>
      advance
      if startsPrimary (← peek) then throw "higher-order: a variable applied to arguments"
      return .var v
    | _ => primary

  partial def primary : P Tm := do
    match ← peek with
    | some (.id f) => advance; return .const f
    | some (.var v) => advance; return .var v
    | some (.sym "_") => advance; return .wild
    | some (.int n) => advance; return .int n
    | some (.float f) => advance; return .float f
    | some (.str s) => advance; return .str s
    | some (.sym "(") =>
      advance
      let t ← arith
      expectSym ")"
      return t
    | some (.sym "[") => throw "list"
    | t => throw s!"unexpected {repr t}"

  partial def arith : P Tm := do
    let mut t ← term
    repeat
      match ← peek with
      | some (.sym op) =>
        if ["+", "-", "*"].contains op then
          advance
          t := .arith op t (← term)
        else break
      | _ => break
    return t
end

def cmpOps : List String := ["=", ">", "<", ">=", "=<", "<="]

mutual
  partial def disj : P Goal := do
    let mut gs := #[← conj]
    while (← peek) == some (.sym ";") do advance; gs := gs.push (← conj)
    return if gs.size == 1 then gs[0]! else .disj gs.toList

  partial def conj : P Goal := do
    let mut gs := #[← lit]
    while (← peek) == some (.sym ",") do advance; gs := gs.push (← lit)
    return if gs.size == 1 then gs[0]! else .conj gs.toList

  partial def lit : P Goal := do
    let g ← match ← peek with
      | some (.sym "!") => advance; pure (.outside "cut")
      | some (.sym "\\") => throw "lambda"
      | some (.id "not") =>
        advance
        expectSym "("
        let g ← disj
        expectSym ")"
        pure (.neg g)
      | some (.id "pi") | some (.id "sigma") => throw "pi or sigma"
      | some (.sym "(") =>
        -- a parenthesized goal; the generator never compares a parenthesized term
        advance
        let g ← disj
        expectSym ")"
        pure g
      | _ => goalOfTerm
    if (← peek) == some (.sym "=>") then
      advance
      let _ ← lit
      return .outside "=>"
    return g

  partial def goalOfTerm : P Goal := do
    let a ← arith
    match ← peek with
    | some (.sym op) =>
      if cmpOps.contains op then advance; return .cmp op a (← arith)
    | some (.id "is") => advance; return .cmp "is" a (← arith)
    | _ => pure ()
    match a with
    | .app f args => return .atom f args
    | .const "true" => return .tru
    | .const c => return .atom c []
    | .var _ => return .outside "a variable called as a goal"
    | _ => return .outside "a goal that is not an atom"
end

def clauseP : P Clause := do
  match ← term with
  | .app p args =>
    if (← peek) == some (.sym ":-") then advance; return { pred := p, args, body := ← disj }
    return { pred := p, args, body := .tru }
  | .const p =>
    if (← peek) == some (.sym ":-") then advance; return { pred := p, args := [], body := ← disj }
    return { pred := p, args := [], body := .tru }
  | _ => throw "a clause head must be an atom"

/-- The argument type names of a `pred p o:t1, o:t2` or `type p t1 -> t2 -> prop` declaration. -/
def declArgs (ts : List Tok) : Option (String × List String) :=
  match ts with
  | .id "pred" :: .id p :: rest =>
    let args := (rest.filterMap fun | .sym s => if s.startsWith ":" && s.length > 1 then some (s.drop 1).toString else none | _ => none)
    some (p, args)
  | .id "type" :: .id p :: rest =>
    let parts := rest.splitOn (Tok.sym "->")
    let tys := parts.filterMap fun | [.id t] => some t | _ => none
    if tys.length == parts.length && tys.getLast? == some "prop" then some (p, tys.dropLast) else none
  | _ => none

/-- The clauses and declarations of a module's source. -/
def parseModule (src : String) : Module := Id.run do
  let toks ← match lex src with
    | .ok t => pure t
    | .error e => return { outside := some e }
  -- sentences end at a `.` symbol
  let mut sentences : List (List Tok) := []
  let mut cur : Array Tok := #[]
  for t in toks do
    if t == Tok.sym "." then sentences := sentences ++ [cur.toList]; cur := #[]
    else cur := cur.push t
  let mut m : Module := {}
  for s in sentences do
    -- attributes such as `:index (2)` before a declaration
    let s := match s with
      | .sym a :: .sym "(" :: rest => if a.startsWith ":" then (rest.dropWhile (· != Tok.sym ")")).drop 1 else s
      | _ => s
    match s with
    | .id "accumulate" :: _ => return { m with outside := some "accumulate" }
    | .id k :: _ =>
      if ["pred", "type", "kind", "mode", "typeabbrev", "macro", "namespace", "shorten", "constraint"].contains k then
        if let some d := declArgs s then m := { m with decls := m.decls ++ [d] }
        continue
      let arr := s.toArray
      match ((clauseP.run 0).run.run arr) with
      | .ok (c, pos) =>
        if pos != arr.size then return { m with outside := some s!"cannot read a clause of {c.pred}" }
        m := { m with clauses := m.clauses ++ [c] }
      | .error e =>
        -- a clause outside the fragment counts only when it is reached
        m := { m with clauses := m.clauses ++ [{ pred := k, args := [], body := .outside e }] }
    | [] => pure ()
    | _ => return { m with outside := some "a sentence that is not a clause" }
  return m

/-! ### Sorts and columns -/

/-- What an argument position holds. -/
inductive ASort where
  /-- A node of a kind, one `number` column: its key. -/
  | node (k : String)
  /-- An endpoint of a multi-pair rel table: a `symbol` tag (the node kind) and a `number` key. -/
  | endpoint
  /-- An edge: its id, a `number`. -/
  | edge
  /-- A value: `number`, `symbol` or `float`. -/
  | val (ty : String)
  deriving Repr, Inhabited, BEq

/-- A database predicate: its Soufflé relation and argument sorts. -/
structure DbPred where
  rel : String
  sorts : List ASort
  deriving Inhabited

def kindOf (table : String) : String := table.toLower

def ptypeSort : PType → Option ASort
  | .int | .date => some (.val "number")
  | .str | .bool => some (.val "symbol")
  | .dbl => some (.val "float")
  | .ints => none

/-- The database predicates of a generated schema, by ELPI name. -/
def dbPreds (s : GSchema) : List (String × Option DbPred) :=
  s.nodes.flatMap (fun t =>
    let k := kindOf t.name
    (k, some { rel := s!"n_{k}", sorts := [.node k] }) ::
      t.props.map fun (p, ty) => (s!"{k}.{p}", (ptypeSort ty).map fun so => { rel := s!"p_{k}_{p}", sorts := [.node k, so] })) ++
  s.rels.flatMap fun r =>
    let k := kindOf r.name
    let ends : List ASort := match r.pairs with
      | [(a, b)] => [.node (kindOf a), .edge, .node (kindOf b)]
      | _ => [.endpoint, .edge, .endpoint]
    (k, some { rel := s!"e_{k}", sorts := ends }) ::
      r.props.map fun (p, ty) => (s!"{k}.{p}", (ptypeSort ty).map fun so => { rel := s!"q_{k}_{p}", sorts := [.edge, so] })

def ASort.types : ASort → List String
  | .node _ | .edge => ["number"]
  | .endpoint => ["symbol", "number"]
  | .val t => [t]

/-- The sort of an ELPI type name in a module declaration. -/
def sortOfDecl (s : GSchema) (t : String) : Option ASort :=
  if s.nodes.any (kindOf ·.name == t) then some (.node t)
  else if s.rels.any fun r => kindOf r.name == t && r.pairs.length == 1 then some .edge
  else match t with
    | "int" => some (.val "number")
    | "string" | "bool" => some (.val "symbol")
    | "float" => some (.val "float")
    | _ => none

/-! ### Translation -/

structure Lit where
  text : String
  /-- Variables it binds (positive literals and equations). -/
  binds : List String
  /-- Variables it needs bound. -/
  needs : List String
  deriving Inhabited

/-- Translation state: fresh names, variable types, generated rules and declarations. -/
structure St where
  fresh : Nat := 0
  types : List (String × String) := []
  rules : Array String := #[]
  decls : Array String := #[]
  inputs : List String := []
  derived : List String := []
  deriving Inhabited

abbrev T := StateT St (Except String)

def freshVar (p : String := "w") : T String := do
  let s ← get
  set { s with fresh := s.fresh + 1 }
  return s!"{p}{s.fresh}"

def setType (v ty : String) : T Unit := do
  let s ← get
  match s.types.lookup v with
  | some t => if t != ty then throw s!"variable {v} is used as {t} and as {ty}"
  | none => set { s with types := (v, ty) :: s.types }

def quote (s : String) : String :=
  "\"" ++ String.join (s.toList.map fun c => if c == '"' then "\\\"" else if c == '\\' then "\\\\" else String.singleton c) ++ "\""

/-- The columns of a term at a sort; `_` becomes a fresh variable when `positive`. -/
partial def cols (s : GSchema) (positive : Bool) (rn : String → String) : Tm → ASort → T (List String)
  | .wild, so =>
    if positive then so.types.mapM fun ty => do let v ← freshVar; setType v ty; return v
    else return so.types.map fun _ => "_"
  | .var x, .endpoint => throw s!"endpoint variable {x}"
  | .var x, so => do
    let ty := so.types.head!
    setType (rn x) ty
    return [rn x]
  | .app k [t], .node k' => if k == k' then cols s positive rn t (.val "number") else throw s!"{k} term at a {k'} position"
  | .app c [t], .endpoint =>
    match (c.splitOn ".").getLast? with
    | some k => do return (quote k) :: (← cols s positive rn t (.node k))
    | none => throw s!"endpoint {c}"
  | .app _ _, .edge => throw "an edge id constant"
  | .int n, .val "number" => return [toString n]
  | .str x, .val "symbol" => return [quote x]
  | .const c, .val "symbol" => return [quote c]
  | .float f, .val "float" => return [f]
  | t, so => throw s!"term {repr t} at sort {repr so}"

/-- A column that is a variable (not a number, a float or a quoted symbol). -/
def isVarCol (c : String) : Bool := match c.toList with
  | x :: _ => x.isAlpha
  | [] => false

/-- An arithmetic or comparison operand: a variable, a number or a symbol. -/
partial def operand (rn : String → String) : Tm → T String
  | .var x => return rn x
  | .int n => return toString n
  | .float f => return f
  | .str x => return quote x
  | .const c => return quote c
  | .arith op a b => do return s!"({← operand rn a} {op} {← operand rn b})"
  | .app _ [t] => operand rn t -- a node term compares as its key
  | t => throw s!"operand {repr t}"

partial def tmVars : Tm → List String
  | .var x => [x]
  | .app _ args => args.flatMap tmVars
  | .arith _ a b => tmVars a ++ tmVars b
  | _ => []

/-- A goal in disjunctive normal form: a list of branches, each a list of literals. -/
partial def dnf : Goal → List (List Goal)
  | .conj gs => gs.foldl (fun acc g => acc.flatMap fun b => (dnf g).map (b ++ ·)) [[]]
  | .disj gs => gs.flatMap dnf
  | .tru => [[]]
  | g => [[g]]

partial def goalOutside : Goal → Option String
  | .outside w => some w
  | .conj gs | .disj gs => gs.findSome? goalOutside
  | .neg g => goalOutside g
  | _ => none

partial def goalAtoms : Goal → List (String × Bool)
  | .atom p _ => [(p, true)]
  | .conj gs | .disj gs => gs.flatMap goalAtoms
  | .neg g => (goalAtoms g).map fun (p, _) => (p, false)
  | _ => []

structure Ctx where
  schema : GSchema
  db : List (String × Option DbPred)
  m : Module
  /-- Module predicates called positively from the entry point, in a cycle. -/
  recursive : List String

def Ctx.isModulePred (c : Ctx) (p : String) : Bool := c.m.clauses.any (·.pred == p)

/-- The literals of a branch: positive database atoms, equations, comparisons and negations;
module predicates called positively are unfolded. Returns the Soufflé literals. -/
partial def branchLits (c : Ctx) (rn : String → String) (depth : Nat) (lits : List Goal) (pre : List Lit) :
    T (List (List Lit)) := do
  match lits with
  | [] => return [pre]
  | g :: rest =>
    match g with
    | .atom p args =>
      match c.db.lookup p with
      | some (some d) =>
        unless args.length == d.sorts.length do throw s!"{p} takes {d.sorts.length} arguments"
        let cs ← (args.zip d.sorts).flatMapM fun (t, so) => cols c.schema true rn t so
        if !(← get).inputs.contains d.rel then modify fun s => { s with inputs := s.inputs ++ [d.rel] }
        -- every column variable, `_` made fresh included: one proof per matching fact
        branchLits c rn depth rest (pre ++ [{ text := s!"{d.rel}({", ".intercalate cs})", binds := cs.filter isVarCol, needs := [] }])
      | some none => throw s!"{p} has list values"
      | none =>
        if !c.isModulePred p then throw s!"{p} is neither a module nor a database predicate"
        if c.recursive.contains p then throw s!"{p} is recursive and called positively"
        if depth > 8 then throw "unfolding too deep"
        -- unfold: one result per clause of p and per branch of its body
        let mut out : List (List Lit) := []
        for cl in c.m.clauses.filter (·.pred == p) do
          let tag ← freshVar "u"
          let rn' (x : String) := s!"{tag}_{x}"
          unless cl.args.length == args.length do throw s!"{p}: arity"
          let eqs := (args.zip cl.args).map fun (a, b) => Goal.cmp "=" a b
          -- the head arguments of `p` are renamed apart, the call's arguments keep `rn`
          for b in dnf cl.body do
            let eqLits ← eqs.mapM fun e => match e with
              | .cmp _ a b => eqLit c rn rn' a b
              | _ => throw "unreachable"
            let rs ← branchLits c rn' (depth + 1) b (pre ++ eqLits)
            -- continue the outer branch after the unfolded body
            for r in rs do out := out ++ (← branchLits c rn depth rest r)
        return out
    | .cmp op a b =>
      let l ← cmpLit rn op a b
      branchLits c rn depth rest (pre ++ [l])
    | .neg ng =>
      let bound := (pre.flatMap (·.binds)).eraseDups
      let k ← freshVar "neg"
      let gvars := ((goalVars ng).map rn).eraseDups
      let hv := gvars.filter bound.contains
      -- the auxiliary relation over the variables bound before the negation
      for b in dnf ng do
        let rs ← negLits c rn b
        modify fun s => { s with rules := s.rules.push (s!"{k}({", ".intercalate hv}) :- " ++
          ", ".intercalate ((pre ++ rs).map (·.text)) ++ ".") }
      let tys ← hv.mapM fun v => do
        match (← get).types.lookup v with
        | some t => pure t
        | none => throw s!"variable {v} has no type"
      if hv.isEmpty then
        modify fun s => { s with decls := s.decls.push s!".decl {k}()" }
      else
        modify fun s => { s with decls := s.decls.push (s!".decl {k}(" ++ ", ".intercalate ((List.range hv.length).zip tys |>.map fun (i, t) => s!"a{i}:{t}") ++ ")") }
      branchLits c rn depth rest (pre ++ [{ text := s!"!{k}({", ".intercalate hv})", binds := [], needs := hv }])
    | .tru => branchLits c rn depth rest pre
    | .outside w => throw w
    | .conj _ | .disj _ => throw "nested goal"
where
  goalVars : Goal → List String
    | .atom _ args => args.flatMap tmVars
    | .conj gs | .disj gs => gs.flatMap goalVars
    | .neg g => goalVars g
    | .cmp _ a b => tmVars a ++ tmVars b
    | _ => []
  cmpLit (rn : String → String) (op : String) (a b : Tm) : T Lit := do
    let (sop, binds) := match op with
      | "is" | "=" => ("=", tmVars a)
      | "=<" => ("<=", [])
      | o => (o, [])
    let num := ["<", ">", ">=", "=<", "<=", "is"].contains op
    if num then for v in tmVars a ++ tmVars b do setType (rn v) "number"
    -- an equation types its unbound side by the other side
    if op == "=" then
      match a, b with
      | .var x, .var y =>
        match (← get).types.lookup (rn y), (← get).types.lookup (rn x) with
        | some t, _ => setType (rn x) t
        | none, some t => setType (rn y) t
        | none, none => pure ()
      | .var x, .int _ | .var x, .arith .. => setType (rn x) "number"
      | .var x, .str _ | .var x, .const _ => setType (rn x) "symbol"
      | _, _ => pure ()
    return { text := s!"{← operand rn a} {sop} {← operand rn b}",
             binds := (binds ++ (if op == "=" then tmVars b else [])).map rn,
             needs := ((tmVars a ++ tmVars b).map rn) }
  eqLit (c : Ctx) (rn rn' : String → String) (a b : Tm) : T Lit := do
    -- `a` (the call's argument, under rn) = `b` (the clause head's argument, under rn')
    let opA ← termOp c rn a
    let opB ← termOp c rn' b
    return { text := s!"{opA} = {opB}", binds := ((tmVars a).map rn ++ (tmVars b).map rn'), needs := [] }
  termOp (_c : Ctx) (rn : String → String) : Tm → T String
    | .wild => freshVar
    | t => operand rn t
  negLits (c : Ctx) (rn : String → String) (b : List Goal) : T (List Lit) :=
    b.mapM fun g => match g with
      | .atom p args => do
        match c.db.lookup p with
        | some (some d) =>
          let cs ← (args.zip d.sorts).flatMapM fun (t, so) => cols c.schema false rn t so
          if !(← get).inputs.contains d.rel then modify fun s => { s with inputs := s.inputs ++ [d.rel] }
          return { text := s!"{d.rel}({", ".intercalate cs})", binds := (args.flatMap tmVars).map rn, needs := [] }
        | some none => throw s!"{p} has list values"
        | none =>
          if !c.isModulePred p then throw s!"{p} is neither a module nor a database predicate"
          let ss ← derivedSorts c p
          let cs ← (args.zip ss).flatMapM fun (t, so) => cols c.schema false rn t so
          return { text := s!"d_{mangle p}({", ".intercalate cs})", binds := (args.flatMap tmVars).map rn, needs := [] }
      | .cmp op a b => cmpLit rn op a b
      | .tru => return { text := "true", binds := [], needs := [] }
      | .neg _ => throw "nested negation"
      | .outside w => throw w
      | _ => throw "nested goal"
  derivedSorts (c : Ctx) (p : String) : T (List ASort) := do
    match c.m.decls.lookup p with
    | some ts => ts.mapM fun t => match sortOfDecl c.schema t with
      | some so => pure so
      | none => throw s!"{p}: argument type {t}"
    | none => throw s!"{p} has no declaration"
  mangle (p : String) : String := p.replace "." "_"

/-- Predicates reached from `entry`, the recursive ones among them, those reached through a
negation, and whether some negation is on a cycle (not stratified). -/
def reach (m : Module) (entry : String) : List String × List String × List String × Bool := Id.run do
  let edges (p : String) : List (String × Bool) :=
    (m.clauses.filter (·.pred == p)).flatMap fun c => goalAtoms c.body
  let mut seen : List String := [entry]
  let mut todo := [entry]
  while !todo.isEmpty do
    let p := todo.head!
    todo := todo.tail
    for (q, _) in edges p do
      if m.clauses.any (·.pred == q) && !seen.contains q then seen := seen ++ [q]; todo := todo ++ [q]
  -- `q` is recursive when it reaches itself
  let reaches (a b : String) : Bool := Id.run do
    let mut vis : List String := []
    let mut st := (edges a).map (·.1)
    let mut fuel := 1000
    while !st.isEmpty && fuel > 0 do
      fuel := fuel - 1
      let x := st.head!
      st := st.tail
      if x == b then return true
      if !vis.contains x then vis := x :: vis; st := st ++ (edges x).map (·.1)
    return false
  let negRoots := seen.flatMap fun p => (edges p).filterMap fun (q, pos) => if pos then none else some q
  let mut underNeg : List String := []
  let mut st := negRoots.filter fun q => m.clauses.any (·.pred == q)
  while !st.isEmpty do
    let q := st.head!
    st := st.tail
    if !underNeg.contains q then
      underNeg := underNeg ++ [q]
      st := st ++ ((edges q).map (·.1)).filter fun r => m.clauses.any (·.pred == r)
  let unstratified := seen.any fun a => (edges a).any fun (b, pos) => !pos && (b == a || reaches b a)
  return (seen, seen.filter (fun p => reaches p p), underNeg, unstratified)

/-- An entry point's answer columns, as Marien prints them. -/
inductive Answer where
  /-- `violation S C X`: severity, code, subject key. -/
  | violation
  /-- A reasoning predicate whose arguments are all nodes: one key column each. -/
  | nodes (n : Nat)
  deriving Inhabited

/-- The answer columns of a head. -/
def answerCols (c : Ctx) (rn : String → String) (a : Answer) (args : List Tm) : T (List String × List String) := do
  match a, args with
  | .violation, [s, code, subj] =>
    let sev ← match s with
      | .const x => pure (quote x)
      | .var x => setType (rn x) "symbol"; pure (rn x)
      | _ => throw "severity"
    let cd ← match code with
      | .str x => pure (quote x)
      | .var x => setType (rn x) "symbol"; pure (rn x)
      | _ => throw "code"
    let key ← match subj with
      | .app ctor [t] =>
        let k := ctor.drop 5 |>.toString
        unless ctor.startsWith "subj_" && c.schema.nodes.any (kindOf ·.name == k) do throw s!"subject {ctor} is not a node"
        cols c.schema false rn t (.node k)
      | _ => throw "subject"
    return ([sev, cd] ++ key, ["symbol", "symbol", "number"])
  | .nodes n, args =>
    unless args.length == n do throw "arity of the entry point"
    let ks ← args.mapM fun t => match t with
      | .var x => do setType (rn x) "number"; pure (rn x)
      | .app _ [.int k] => pure (toString k)
      | _ => throw "an answer that is not a node"
    return (ks, List.replicate n "number")
  | _, _ => throw "entry point arity"

/-- A translated program: its text, the input relations it reads, and the proof relations with
the number of answer columns each starts with. -/
structure Program where
  text : String
  inputs : List String
  outputs : List (String × Nat)

/-- Translate entry point `entry`, or the reason it is outside the fragment. -/
-- @tg: implements:: [[openspec:differential-testing#Soufflé oracle]] {note: "fragment classifier and translator"}
def translate (s : GSchema) (src : String) (entry : String) (answer : Answer) : Except String Program := do
  let m := parseModule src
  if let some w := m.outside then throw w
  let (reached, recursive, underNeg, unstratified) := reach m entry
  for cl in m.clauses.filter (reached.contains ·.pred) do
    if let some w := goalOutside cl.body then throw w
  if unstratified then throw "negation is not stratified"
  let c : Ctx := { schema := s, db := dbPreds s, m, recursive }
  let go : T (List (String × Nat)) := do
    -- module predicates reached through a negation become set relations
    for p in underNeg do
      let ss ← (branchLits.derivedSorts c p)
      modify fun st => { st with decls := st.decls.push (s!".decl d_{p.replace "." "_"}(" ++
        ", ".intercalate ((List.range ss.length).zip (ss.flatMap ASort.types) |>.map fun (i, t) => s!"a{i}:{t}") ++ ")") }
      for cl in m.clauses.filter (·.pred == p) do
        let tag ← freshVar "d"
        let rn (x : String) := s!"{tag}_{x}"
        let hcols ← (cl.args.zip ss).flatMapM fun (t, so) => cols s false rn t so
        for b in dnf cl.body do
          let rs ← branchLits.negLits c rn b
          let bound := (rs.flatMap (·.binds))
          for v in (cl.args.flatMap tmVars).map rn do
            unless bound.contains v do throw s!"{p}: head variable not range-restricted"
          modify fun st => { st with rules := st.rules.push (s!"d_{p.replace "." "_"}({", ".intercalate hcols})" ++
            (if rs.isEmpty then "." else " :- " ++ ", ".intercalate (rs.map (·.text)) ++ ".")) }
    -- the entry point: one proof relation per clause branch
    let mut outs : List (String × Nat) := []
    for cl in m.clauses.filter (·.pred == entry) do
      let tag ← freshVar "c"
      let rn (x : String) := s!"{tag}_{x}"
      for b in dnf cl.body do
        let branches ← branchLits c rn 0 b []
        for lits in branches do
          let (acols, atys) ← answerCols c rn answer cl.args
          let bound := (lits.flatMap (·.binds)).eraseDups
          for v in (lits.flatMap (·.needs)) ++ (cl.args.flatMap tmVars).map rn do
            unless bound.contains v do throw s!"variable {v} is not bound by a positive literal"
          let vs := bound.filter fun v => !acols.contains v
          let st ← get
          let vtys ← vs.mapM fun v => match st.types.lookup v with
            | some t => pure t
            | none => throw s!"variable {v} has no type"
          let name := s!"proof{outs.length}"
          let tys := atys ++ vtys
          modify fun st => { st with
            decls := st.decls.push (s!".decl {name}(" ++ ", ".intercalate ((List.range tys.length).zip tys |>.map fun (i, t) => s!"a{i}:{t}") ++ ")")
            rules := st.rules.push (s!"{name}({", ".intercalate (acols ++ vs)})" ++
              (if lits.isEmpty then "." else " :- " ++ ", ".intercalate (lits.map (·.text)) ++ ".")) }
          outs := outs ++ [(name, acols.length)]
    return outs
  let (outs, st) ← go.run {}
  let inputDecls := (dbPreds s).filterMap fun (_, d) => d.bind fun d =>
    if st.inputs.contains d.rel then
      let tys := d.sorts.flatMap ASort.types
      some (s!".decl {d.rel}(" ++ ", ".intercalate ((List.range tys.length).zip tys |>.map fun (i, t) => s!"a{i}:{t}") ++ s!")\n.input {d.rel}")
    else none
  let text := "\n".intercalate (inputDecls ++ st.decls.toList ++ st.rules.toList ++ outs.map (".output " ++ ·.1)) ++ "\n"
  return { text, inputs := st.inputs, outputs := outs }

/-! ### Facts -/

def PV.fact : PV → Option String
  | .null => none
  | .int i | .date i => some (toString i)
  | .str s => some s
  | .dbl f => some (toString f)
  | .bool b => some (if b then "tt" else "ff")
  | .ints _ => none

/-- The facts of every input relation, by relation, under a scope (`none`: full scope): a
restricted table keeps its listed nodes and their properties, and an edge is kept when each of
its restricted endpoints is listed. -/
def facts (s : GSchema) (g : GGraph) (scope : Option (List (String × List Int))) : List (String × List String) :=
  let listed (t : String) (k : Int) : Bool := match scope with
    | none => true
    | some sc => match sc.lookup t with
      | some ks => ks.contains k
      | none => true
  let nodes := g.nodes.filter fun n => listed n.table n.id
  let edges := (g.edges.zipIdx).filter fun (e, _) => listed e.src.1 e.src.2 && listed e.dst.1 e.dst.2
  let nodeFacts := s.nodes.flatMap fun t =>
    let k := kindOf t.name
    let ns := nodes.filter (·.table == t.name)
    (s!"n_{k}", ns.map (toString ·.id)) ::
      t.props.map fun (p, _) => (s!"p_{k}_{p}", ns.filterMap fun n =>
        ((n.props.lookup p).bind PV.fact).map fun v => s!"{n.id}\t{v}")
  let relFacts := s.rels.flatMap fun r =>
    let k := kindOf r.name
    let es := edges.filter (·.1.rel == r.name)
    let row (e : GEdge) (i : Nat) : String :=
      if r.pairs.length == 1 then s!"{e.src.2}\t{i}\t{e.dst.2}"
      else s!"{kindOf e.src.1}\t{e.src.2}\t{i}\t{kindOf e.dst.1}\t{e.dst.2}"
    (s!"e_{k}", es.map fun (e, i) => row e i) ::
      r.props.map fun (p, _) => (s!"q_{k}_{p}", es.filterMap fun (e, i) =>
        ((e.props.lookup p).bind PV.fact).map fun v => s!"{i}\t{v}")
  nodeFacts ++ relFacts

end Oracle

namespace Oracle

open Property

/-! ### Case directories -/

/-- The hand-written validation rule of the spec's first scenario, over the generator's schema
(`t0` for people, `r0` for reports-to): a subject with a name and no outgoing edge. It is local
at radius 1, so it is also the partitioned case. -/
def scenarioRule : String :=
  "pred violation o:severity, o:string, o:subject.\n" ++
  "violation error \"no-manager\" (subj_t0 P) :- t0.p1 P _, not (r0 P _ _).\n"

/-- The workload of a seed, with the partition module replaced by `scenarioRule` for variant
`rule`. -/
def oracleWorkload (seed size : Nat) (variant : String) : Workload :=
  let w := workload seed size
  if variant == "rule" then
    { w with partition := { body := scenarioRule, annotation := "% @marien partition violation by t0 radius 1\n", radius := 1, bad := none } }
  else w

/-- One comparison: the module, its entry point and answer, the scope of the facts, and the
query Marien answers it with. -/
structure Target where
  name : String
  module : String
  entry : String
  answer : Answer
  scope : Option (List (String × List Int))
  query : String

def targets (w : Workload) : List Target :=
  let report := "CALL elpi_validate(['full']) RETURN severity, code, subject_pk"
  [{ name := "full", module := w.partition.body, entry := "violation", answer := .violation, scope := none, query := report },
   { name := "part", module := w.partition.source, entry := "violation", answer := .violation, scope := none,
     query := "CALL elpi_partition_batch=1; CALL elpi_validate(['part']) RETURN severity, code, subject_pk (partitioned, and at the default batch)" },
   { name := "narrow-full", module := w.narrowing.source, entry := "q", answer := .nodes 2, scope := none,
     query := "CALL elpi_run('narrow', 'q') RETURN out1, out2" },
   { name := "narrow", module := w.narrowing.source, entry := "q", answer := .nodes 2, scope := some w.scope,
     query := s!"CALL elpi_run('narrow', 'q', NULL, {scopeCypher w.scope}) RETURN out1, out2" }]

/-- Write a case: `case.txt` for the runner, `schema.cypher`, and per target `module.elpi`,
`query.txt` and either `prog.dl`, `facts/` and `outputs` (proof relation and answer columns per
line), or `SKIP` with the reason. Prints one line per target: `<target> translated|skip <reason>`. -/
def writeCase (seed size : Nat) (variant : String) (dir : System.FilePath) : IO Unit := do
  let w := oracleWorkload seed size variant
  IO.FS.createDirAll dir
  IO.FS.writeFile (dir / "case.txt") w.text
  IO.FS.writeFile (dir / "schema.cypher") ("\n".intercalate (w.schema.ddl ++ w.graph.cypher) ++ "\n")
  for t in targets w do
    let td := dir / t.name
    IO.FS.createDirAll td
    IO.FS.writeFile (td / "module.elpi") t.module
    IO.FS.writeFile (td / "query.txt") (t.query ++ "\n")
    match translate w.schema t.module t.entry t.answer with
    | .error why =>
      IO.FS.writeFile (td / "SKIP") (why ++ "\n")
      IO.println s!"{t.name} skip {why}"
    | .ok p =>
      IO.FS.writeFile (td / "prog.dl") p.text
      IO.FS.writeFile (td / "outputs") (String.join (p.outputs.map fun (n, k) => s!"{n} {k}\n"))
      IO.FS.createDirAll (td / "facts")
      for (rel, rows) in facts w.schema w.graph t.scope do
        if p.inputs.contains rel then
          IO.FS.writeFile (td / "facts" / s!"{rel}.facts") (String.join (rows.map (· ++ "\n")))
      IO.println s!"{t.name} translated"

end Oracle
