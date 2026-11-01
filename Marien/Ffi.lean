import Marien.Exec.Run

/-!
# Runtime bridge: the C entry points

Every function the C++ shim calls, exported under a fixed C name. Arguments and results are
strings, arrays of strings, value arrays and opaque handles (`Session`, `Run`), so the shim never
depends on the layout of Marien's own structures. Catalog and stored modules arrive as JSON from
the shim's catalog reader and its scan of `_elpi_module`.

Every argument is owned: the callee consumes it, so the shim increments a handle it keeps
using. Results that can fail are `Except String α`: tag 0 is the error text, tag 1 the value. The
handle cache is the one piece of process-wide state; `IO.Ref` makes its updates atomic.
-/

-- @lat: [[components#Runtime bridge]]

namespace Marien.Ffi

open Lean (Json)
open Marien.Encoding Marien.Store Marien.Exec

/-- The process-wide handle cache. -/
initialize handleCache : IO.Ref HandleCache ← IO.mkRef {}

private def stored (modulesJson : String) : Except String (List Stored) := do
  let j ← Json.parse modulesJson
  let .arr rows := j | throw "stored modules must be a JSON array"
  rows.toList.mapM fun r => do
    let opt (k : String) (d : String) := (r.getObjValAs? String k).toOption.getD d
    return { name := ← r.getObjValAs? String "name", version := ← r.getObjValAs? Nat "version"
             source := ← r.getObjValAs? String "source", derived := opt "derived" ""
             schemaHash := opt "schema_hash" "", status := opt "status" "ok", error := opt "error" "" }

private def schema (catalog : String) : Except String Schema :=
  (Schema.parse catalog).mapError (s!"catalog: {·}")

/-! ### Signature -/

/-- `elpi_signature([table])`: rows `(kind, name, text)`, flattened; kind is `protocol` (the
validation protocol's declarations, with no table named), `table` or `warning`. -/
-- @tg: implements:: [[openspec:schema-encoding#Signature inspection]]
-- @tg: implements:: [[openspec:schema-encoding#Schema model from the catalog]]
@[export marien_signature]
def signature (catalog table : String) : Except String (Array String) := do
  let sig ← (Signature.ofSchema (Engine.reservedNames.contains ·) (← schema catalog)).mapError toString
  let tables := sig.tables.filter fun (n, _) => table.isEmpty || n == table
  if !table.isEmpty && tables.isEmpty then throw s!"no encoded table named {table}"
  let ws := if table.isEmpty then sig.warnings
    else sig.warnings.filter fun w => (w.splitOn s!"table {table}").length > 1
  let proto := if table.isEmpty then ["protocol", "", Encoding.protocolDecls] else []
  return (proto ++ tables.flatMap (fun (n, t) => ["table", n, t]) ++ ws.flatMap (["warning", "", ·])).toArray

/-! ### Module store -/

@[export marien_init_statements]
def initStatements (_ : Unit) : Array String := Store.initStatements.toArray

@[export marien_save]
def save (catalog modules name source : String) : Except String (Array String) := do
  let (stmts, _) ← Store.save (← schema catalog) (← stored modules) name source
  return stmts.toArray

@[export marien_drop]
def drop (modules name : String) : Except String (Array String) := do
  return (← Store.drop (← stored modules) name).toArray

/-- `elpi_export`: rows `(name, version, source)`, flattened, dependencies first. -/
@[export marien_export]
def «export» (modules : String) : Except String (Array String) := do
  let rows ← Store.exportOrder (← stored modules)
  return (rows.flatMap fun r => [r.name, toString r.version, r.source]).toArray

@[export marien_import]
def «import» (catalog modules bundle : String) : Except String (Array String) := do
  let (stmts, _) ← Store.importBundle (← schema catalog) (← stored modules) bundle
  return stmts.toArray

/-! ### Values from the scanner -/

@[export marien_v_int] def vInt (i : Int) : Value := .int i
@[export marien_v_nat] def vNat (n : Nat) : Value := .int n
/-- An INT128 from its two 64-bit halves (two's complement). -/
@[export marien_v_int128] def vInt128 (hi lo : UInt64) : Value :=
  .int ((Int.ofNat hi.toNat - if hi.toNat ≥ 2 ^ 63 then 2 ^ 64 else 0) * 2 ^ 64 + lo.toNat)
@[export marien_v_uint128] def vUInt128 (hi lo : UInt64) : Value := .int (hi.toNat * 2 ^ 64 + lo.toNat)
@[export marien_v_float] def vFloat (f : Float) : Value := .float f.toBits
@[export marien_v_str] def vStr (s : String) : Value := .str s
@[export marien_v_bool] def vBool (b : UInt8) : Value := .bool (b != 0)
@[export marien_v_null] def vNull (_ : Unit) : Value := .null
@[export marien_v_list] def vList (xs : Array Value) : Value := .list xs.toList
@[export marien_v_struct] def vStruct (xs : Array Value) : Value := .struct xs.toList

/-- `elpi_recheck`: the statement persisting every listed module's recheck (all modules when
`all` is set). -/
@[export marien_recheck]
def recheckC (catalog modules : String) (names : Array String) (all : UInt8) :
    Except String (Array String) := do
  return (← Store.recheck (← schema catalog) (← stored modules)
    (if all != 0 then none else some names.toList)).toArray

/-! ### Queries -/

/-- Run `prepare` against the process-wide cache, resized to `cacheSize`. -/
private def withCache (catalog modules : String) (cacheSize : UInt64)
    (prep : HandleCache → Schema → List Stored → Except String (Session × HandleCache)) :
    IO (Except String Session) := do
  match schema catalog, stored modules with
  | .error e, _ | _, .error e => return .error e
  | .ok sc, .ok st =>
    let cache := (← handleCache.get).resize cacheSize.toNat
    match prep cache sc st with
    | .error e => return .error e
    | .ok (s, cache') =>
      handleCache.modify fun c =>
        -- keep entries other calls added meanwhile; add this call's entry
        cache'.entries.fold (init := c.resize cacheSize.toNat) fun acc k (v, _) =>
          if acc.entries.contains k then acc else acc.insert k v
      return .ok s

/-- Find or compile the module and open a session; the cache is resized to `cacheSize`. -/
@[export marien_query_prepare]
def queryPrepare (catalog modules name goal : String) (maxFacts cacheSize : UInt64) :
    IO (Except String Session) :=
  withCache catalog modules cacheSize fun c sc st => prepare c sc st name maxFacts.toNat goal

/-- `elpi_run`: open a session for `pred` with the named parameters; `narrowed` when the call
passes a scope. -/
@[export marien_run_prepare]
def runPrepare (catalog modules name pred : String) (names : Array String) (values : Array Value)
    (maxFacts cacheSize : UInt64) (narrowed : UInt8) : IO (Except String Session) :=
  withCache catalog modules cacheSize fun c sc st =>
    prepareRun c sc st name pred (names.toList.zip values.toList) maxFacts.toNat (narrowed != 0)

/-- The output columns of a typed session: `[name, type token…]` each (`Codec.Col.ltyTokens`). -/
@[export marien_session_columns]
def sessionColumns (s : Session) : Array (Array String) :=
  match s.output with
  | .typed cols => cols.map fun (n, c) => (n :: Codec.Col.ltyTokens c.lty).toArray
  | _ => #[]

/-- `elpi_validate`: the modules to run, in order. -/
@[export marien_validate_order]
def validateOrderC (modules : String) (names : Array String) (all : UInt8) : Except String (Array String) := do
  return (← validationOrder (← stored modules) (if all != 0 then none else some names.toList)).toArray

/-- `elpi_validate`: a session for one module's `violation S C X`. -/
@[export marien_validate_prepare]
def validatePrepare (catalog modules name minSeverity : String) (maxFacts cacheSize : UInt64)
    (narrowed : UInt8) : IO (Except String Session) := do
  let some sev := Severity.ofName? minSeverity
    | return .error s!"min_severity must be error, warning or info, not {minSeverity.quote}"
  withCache catalog modules cacheSize fun c sc st =>
    prepareValidate c sc st name maxFacts.toNat sev (narrowed != 0)

/-! ### Partitions -/

/-- The partition a session runs in (`PartitionPlan.describe`), or nothing for full scope. -/
@[export marien_session_partition]
def sessionPartition (s : Session) : Array String := (s.partition.map (·.describe)).getD #[]

/-- The session for the next anchor batch, keeping rows whose subject is one of `keys`. -/
@[export marien_session_batch]
def sessionBatch (s : Session) (keys : Array Value) : Session := s.forBatch keys

/-- The session for the next key bucket. -/
@[export marien_session_fresh]
def sessionFresh (s : Session) : Session := s.fresh

/-- The size of each batch when `count` anchors are split into batches of at most `n`. -/
@[export marien_partition_batches]
def partitionBatches (n count : UInt64) : Array UInt64 :=
  (Partition.batchSizes n.toNat count.toNat).toArray.map (·.toUInt64)

/-- The bucket of each key value among `k`; `k` for a NULL key, which is in no bucket. -/
@[export marien_partition_buckets]
def partitionBuckets (k : UInt64) (keys : Array Value) : Array UInt64 :=
  (Partition.bucketsOf k.toNat (keys.toList.map fun | .null => none | v => some (keyText v))).toArray.map
    fun | some b => b.toUInt64 | none => k

/-- The scans of a session: `["node" | "rel", table, column…]` each. -/
@[export marien_session_scans]
def sessionScans (s : Session) : Array (Array String) := s.scans.map Scan.describe

@[export marien_add_batch]
def addBatchC (s : Session) (i : USize) (cols : Array (Array Value)) : Except String Session :=
  addBatch s i.toNat cols

@[export marien_query_start]
def queryStart (s : Session) (goal : String) (fuel sliceSteps maxSolutions : UInt64) :
    Except String Run :=
  start s goal fuel.toNat sliceSteps.toNat maxSolutions.toNat

/-- Start a typed session's goal (`elpi_run`, `elpi_validate`). -/
@[export marien_goal_start]
def goalStart (s : Session) (fuel sliceSteps maxSolutions : UInt64) : Except String Run :=
  startGoal s fuel.toNat sliceSteps.toNat maxSolutions.toNat

/-- One slice, shaped for C: a solution carries its items (`Step.solution`). -/
inductive CStep where
  | solution (items : Array String) (next : Run)
  | paused (next : Run)
  | error (msg : String)
  /-- The search ran to completion. -/
  | exhausted
  /-- `elpi_max_solutions` stopped the search. -/
  | stopped

@[export marien_query_step]
def queryStep (r : Run) : CStep :=
  match step r with
  | .solution items r' => .solution items r'
  | .paused r' => .paused r'
  | .done true => .exhausted
  | .done false => .stopped
  | .error e => .error e

/-- How often the handle cache missed (tests). -/
@[export marien_cache_misses]
def cacheMisses (_ : Unit) : IO UInt64 := return (← handleCache.get).misses.toUInt64

end Marien.Ffi
