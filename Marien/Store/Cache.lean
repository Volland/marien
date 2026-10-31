import Std.Data.HashMap
import Marien.Engine

/-!
# Handle cache

Compiled programs by module name, version and source hash, schema hash and the sources of the
modules it accumulates, so a run whose key is cached neither parses nor type-checks. The cache lives in
memory only and holds at most `capacity` entries (option `elpi_cache_size`), evicting the least
recently used one.
-/

-- @lat: [[components#Handle cache]]

namespace Marien.Store

/-- What a compiled program depends on. A new version or source of the module, a schema change
or a changed module it accumulates gives a new key. The cache is shared by every database of
the process, and a version number alone is not unique across databases or after a drop, so the
source hashes are part of the key. -/
structure CacheKey where
  name : String
  version : Nat
  sourceHash : String
  schemaHash : String
  /-- Each accumulated module, transitively, with the hash of its source. -/
  deps : List (String × String)
  deriving BEq, Hashable, Repr, Inhabited

/-- An LRU cache of values of type `α` (compiled programs with their load plans). -/
structure Cache (α : Type) where
  capacity : Nat := 64
  tick : Nat := 0
  entries : Std.HashMap CacheKey (α × Nat) := {}
  /-- How often a lookup missed; tests read it to see that a run reused the program. -/
  misses : Nat := 0
  deriving Inhabited

namespace Cache

variable {α : Type}

/-- The value of a key, marked as recently used. -/
def find? (c : Cache α) (k : CacheKey) : Option α × Cache α :=
  match c.entries[k]? with
  | some (v, _) => (some v, { c with tick := c.tick + 1, entries := c.entries.insert k (v, c.tick + 1) })
  | none => (none, { c with misses := c.misses + 1 })

/-- Drop the least recently used entries until at most `capacity` remain. -/
partial def evict (c : Cache α) : Cache α :=
  if c.entries.size ≤ c.capacity then c
  else
    let oldest := c.entries.fold (init := none) fun acc k (_, t) =>
      match acc with
      | some (_, t') => if t < t' then some (k, t) else acc
      | none => some (k, t)
    match oldest with
    | some (k, _) => evict { c with entries := c.entries.erase k }
    | none => c

-- @tg: implements:: [[openspec:rule-storage#Compiled handle cache]]
def insert (c : Cache α) (k : CacheKey) (v : α) : Cache α :=
  evict { c with tick := c.tick + 1, entries := c.entries.insert k (v, c.tick + 1) }

def resize (c : Cache α) (capacity : Nat) : Cache α := evict { c with capacity }

end Cache

end Marien.Store
