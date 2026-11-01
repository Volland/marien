import Marien.Schema

/-!
# Partition planner

How a partitioned run splits its work. The shim enumerates anchors and key values and scans the
rows in the calling transaction; the splitting itself happens here, so the theorems below are
about the code that runs.

* **Anchor batches.** `batches n anchors` cuts the anchor list into consecutive batches of at
  most `n`. Together they are exactly the anchor list (`batches_partition`), so with distinct
  anchors every anchor is in exactly one batch, and as a batch keeps only the rows whose subject
  is one of its anchors, every violation is reported by exactly one batch
  (`violation_unique_batch`).
* **Key buckets.** `bucketOf k v` puts a key value in one of `k` buckets by its hash; a row
  whose key is NULL is in none. Every other row is in exactly one bucket, and rows with equal
  keys share it (`key_buckets_sound`).
-/

-- @lat: [[components#Partition planner]]

namespace Marien.Partition

/-! ### Anchor batches -/

/-- Consecutive batches of at most `n` anchors (`n = 0` is taken as 1). -/
def batches {α : Type} (n : Nat) (xs : List α) : List (List α) :=
  if h : xs = [] then [] else
    have : xs.length - max n 1 < xs.length := by
      have : xs.length > 0 := List.length_pos_iff.mpr h
      omega
    xs.take (max n 1) :: batches n (xs.drop (max n 1))
termination_by xs.length

theorem batches_flatten {α : Type} (n : Nat) (xs : List α) : (batches n xs).flatten = xs := by
  fun_induction batches n xs with
  | case1 => rfl
  | case2 xs _ _ ih => rw [List.flatten_cons, ih, List.take_append_drop]

theorem batches_size {α : Type} (n : Nat) (xs : List α) :
    ∀ b ∈ batches n xs, b ≠ [] ∧ b.length ≤ max n 1 := by
  fun_induction batches n xs with
  | case1 => intro b hb; simp at hb
  | case2 xs h _ ih =>
    intro b hb
    rcases List.mem_cons.mp hb with rfl | hb
    · refine ⟨?_, List.length_take_le _ _⟩
      rw [Ne, List.take_eq_nil_iff]
      rintro (h' | h')
      · omega
      · exact h h'
    · exact ih b hb

/-- The batches cover the anchors exactly, in order, and each holds one to `n` anchors. -/
-- @tg: verifies:: [[openspec:partitioning#Anchor partitions#Partitioned result equals full scope]] {level: unit, confidence: partial, note: "batch coverage; the integration test runs the scenario"}
theorem batches_partition {α : Type} (n : Nat) (xs : List α) :
    (batches n xs).flatten = xs ∧ ∀ b ∈ batches n xs, b ≠ [] ∧ b.length ≤ max n 1 :=
  ⟨batches_flatten n xs, batches_size n xs⟩

theorem countP_mem_flatten {α : Type} [DecidableEq α] (a : α) :
    ∀ (bs : List (List α)), bs.flatten.Nodup → a ∈ bs.flatten → bs.countP (fun b => a ∈ b) = 1 := by
  intro bs
  induction bs with
  | nil => intro _ h; simp at h
  | cons b bs ih =>
    intro hnd hmem
    rw [List.flatten_cons] at hnd hmem
    have hdis := (List.nodup_append.mp hnd).2.2
    rw [List.countP_cons]
    by_cases hb : a ∈ b
    · have hnot : ∀ b' ∈ bs, ¬ a ∈ b' := by
        intro b' hb' ha
        exact hdis a hb a (List.mem_flatten.mpr ⟨b', hb', ha⟩) rfl
      rw [List.countP_eq_zero.mpr (by simpa using hnot)]
      simp [hb]
    · have : a ∈ bs.flatten := by
        rcases List.mem_append.mp hmem with h | h
        · exact absurd h hb
        · exact h
      rw [ih (List.nodup_append.mp hnd).2.1 this]
      simp [hb]

/-- With distinct anchors, a row whose subject is the anchor `a` is kept by exactly one batch:
every violation is reported once. -/
-- @tg: verifies:: [[openspec:partitioning#Anchor partitions#Partitioned result equals full scope]] {level: unit, confidence: partial, note: "no row is reported twice"}
theorem violation_unique_batch {α : Type} [DecidableEq α] (n : Nat) (xs : List α) (a : α)
    (hnd : xs.Nodup) (ha : a ∈ xs) : (batches n xs).countP (fun b => a ∈ b) = 1 := by
  apply countP_mem_flatten
  · rw [batches_flatten]; exact hnd
  · rw [batches_flatten]; exact ha

/-- The size of each batch of `count` anchors, for the shim. -/
def batchSizes (n count : Nat) : List Nat := (batches n (List.range count)).map (·.length)

/-! ### Key buckets -/

/-- The bucket of a key value among `k` buckets (`k = 0` is taken as 1). -/
def bucketOf (k : Nat) (v : String) : Nat := (Schema.fnv1a64 v).toNat % max k 1

/-- The rows of bucket `i`: those whose key is not NULL and hashes to `i`. -/
def bucket {ρ : Type} (k i : Nat) (key : ρ → Option String) (rows : List ρ) : List ρ :=
  rows.filter fun r => (key r).map (bucketOf k) == some i

/-- Rows whose key is NULL are in no bucket; every other row is in exactly one bucket, below
`k`; rows with equal keys are in the same buckets. -/
-- @tg: verifies:: [[openspec:partitioning#Key partitions#Duplicate emails are found across buckets]] {level: unit, confidence: partial, note: "bucket soundness; the integration test runs the scenario"}
theorem key_buckets_sound {ρ : Type} (k : Nat) (key : ρ → Option String) (rows : List ρ) :
    (∀ r ∈ rows, key r = none → ∀ i, r ∉ bucket k i key rows) ∧
    (∀ r ∈ rows, ∀ v, key r = some v →
      bucketOf k v < max k 1 ∧ r ∈ bucket k (bucketOf k v) key rows ∧
      ∀ i, r ∈ bucket k i key rows → i = bucketOf k v) ∧
    (∀ r ∈ rows, ∀ r' ∈ rows, key r = key r' → ∀ i, r ∈ bucket k i key rows ↔ r' ∈ bucket k i key rows) := by
  refine ⟨?_, ?_, ?_⟩
  · intro r _ hk i hi
    simp [bucket, hk] at hi
  · intro r hr v hk
    refine ⟨Nat.mod_lt _ (by omega), ?_, ?_⟩
    · simp [bucket, hk, hr]
    · intro i hi
      simp [bucket, hk] at hi
      exact hi.2.symm
  · intro r hr r' hr' heq i
    simp [bucket, heq, hr, hr']

/-- The bucket of each key value (`none` for NULL), for the shim. -/
def bucketsOf (k : Nat) (keys : List (Option String)) : List (Option Nat) := keys.map (·.map (bucketOf k))

end Marien.Partition
