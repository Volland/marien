/-!
# Soundness of the monotonicity and locality checks

The checks of `Monotone` and `Locality` are syntactic. This file gives the fragment they accept
an abstract semantics and proves what the checks are for: on a monotone entry point a smaller
database never gives more answers (narrowed scope), and on an accepted partition the answers
about a subject are the same on its neighbourhood as on the whole database (anchor batches).

The semantics is that of a ground Horn program with negation, evaluated in stages: stage 0 is
empty, and stage `n + 1` holds the database facts and the head of every rule whose positive body
holds at stage `n` and whose negated atoms are false. Negation is stratified: a negated atom is
decided by a lower stratum, given here as the valuation `σ`. Cut and `forall` lie outside the
fragment; the monotonicity check treats them like negation over the database and rejects them.

What ties the abstraction to the analyzer:

* the monotonicity check accepts only negated goals that reach no database predicate, so the
  lower stratum that decides them reads no database fact; `static_independent` proves such a
  stratum gives the same answers on every database, so `σ` is the same on both sides of
  `monotone_sound`;
* the locality check accepts a partition only when every atom a clause about subject `a` reads
  lies within the radius of `a`, after inlining helpers; that is the closure hypothesis of
  `locality_sound`, with `near` the atoms of `a`'s neighbourhood.
-/

-- @lat: [[components#Rule analyzer]]

namespace Marien.Analysis.Semantics

variable {α : Type}

/-- A ground rule: `head :- pos, not neg₁, …, not negₖ`. -/
structure Rule (α : Type) where
  head : α
  pos : List α
  neg : List α

/-- One application of the rules: the database facts and every head whose body holds in `I`,
with the negated atoms decided by `σ`. -/
def step (P : List (Rule α)) (σ : α → Prop) (D I : α → Prop) (a : α) : Prop :=
  D a ∨ ∃ r ∈ P, r.head = a ∧ (∀ b ∈ r.pos, I b) ∧ ∀ b ∈ r.neg, ¬ σ b

/-- The atoms derived within `n` steps. -/
def stage (P : List (Rule α)) (σ : α → Prop) (D : α → Prop) : Nat → α → Prop
  | 0 => fun _ => False
  | n + 1 => step P σ D (stage P σ D n)

/-- The answers: the atoms derived in some number of steps. -/
def answers (P : List (Rule α)) (σ : α → Prop) (D : α → Prop) (a : α) : Prop :=
  ∃ n, stage P σ D n a

theorem stage_mono_db (P : List (Rule α)) (σ : α → Prop) {D D' : α → Prop}
    (hD : ∀ a, D a → D' a) : ∀ n a, stage P σ D n a → stage P σ D' n a := by
  intro n
  induction n with
  | zero => intro _ h; exact h.elim
  | succ n ih =>
    intro a h
    rcases h with hd | ⟨r, hr, hh, hp, hn⟩
    · exact Or.inl (hD a hd)
    · exact Or.inr ⟨r, hr, hh, fun b hb => ih b (hp b hb), hn⟩

/-- Monotonicity soundness: with negation decided by a stratum that reads no database fact,
every answer on a sub-database is an answer on the database. This is why a narrowed run of a
monotone entry point never adds answers. -/
-- @tg: verifies:: [[openspec:rule-execution#Narrowed scope for monotone entry points#Narrowing never adds answers]] {level: unit, confidence: partial, note: "over the abstract semantics of the analysed fragment"}
theorem monotone_sound (P : List (Rule α)) (σ : α → Prop) {D D' : α → Prop}
    (hD : ∀ a, D a → D' a) {a : α} (h : answers P σ D a) : answers P σ D' a :=
  let ⟨n, hn⟩ := h
  ⟨n, stage_mono_db P σ hD n a hn⟩

theorem stage_local (P : List (Rule α)) (σ : α → Prop) (D : α → Prop) (near : α → Prop)
    (closed : ∀ r ∈ P, near r.head → ∀ b ∈ r.pos, near b) :
    ∀ n a, near a → (stage P σ D n a ↔ stage P σ (fun x => D x ∧ near x) n a) := by
  intro n
  induction n with
  | zero => intro _ _; exact Iff.rfl
  | succ n ih =>
    intro a ha
    have body : ∀ r ∈ P, r.head = a → ∀ b ∈ r.pos, near b := fun r hr hh =>
      closed r hr (by rw [hh]; exact ha)
    constructor
    · intro h
      rcases h with hd | ⟨r, hr, hh, hp, hn⟩
      · exact Or.inl ⟨hd, ha⟩
      · exact Or.inr ⟨r, hr, hh, fun b hb => (ih b (body r hr hh b hb)).mp (hp b hb), hn⟩
    · intro h
      rcases h with hd | ⟨r, hr, hh, hp, hn⟩
      · exact Or.inl hd.1
      · exact Or.inr ⟨r, hr, hh, fun b hb => (ih b (body r hr hh b hb)).mpr (hp b hb), hn⟩

/-- Locality soundness: when every rule about an atom near the subject reads only atoms near
it, the answers near the subject are the same on the subject's neighbourhood of the database as
on the whole database. This is why an accepted anchor partition reports what full scope does. -/
-- @tg: verifies:: [[openspec:partitioning#Anchor partitions#Partitioned result equals full scope]] {level: unit, confidence: partial, note: "over the abstract semantics of the analysed fragment"}
theorem locality_sound (P : List (Rule α)) (σ : α → Prop) (D : α → Prop) (near : α → Prop)
    (closed : ∀ r ∈ P, near r.head → ∀ b ∈ r.pos, near b) {a : α} (ha : near a) :
    answers P σ D a ↔ answers P σ (fun x => D x ∧ near x) a :=
  ⟨fun ⟨n, h⟩ => ⟨n, (stage_local P σ D near closed n a ha).mp h⟩,
   fun ⟨n, h⟩ => ⟨n, (stage_local P σ D near closed n a ha).mpr h⟩⟩

theorem stage_congr_db (P : List (Rule α)) (σ : α → Prop) {D D' : α → Prop}
    (hD : ∀ a, D a ↔ D' a) (n : Nat) (a : α) : stage P σ D n a ↔ stage P σ D' n a :=
  ⟨stage_mono_db P σ (fun x => (hD x).mp) n a, stage_mono_db P σ (fun x => (hD x).mpr) n a⟩

/-- A stratum that reads no database fact answers the same on every database: when the rules
about `static` atoms read only `static` atoms, and no database holds a `static` atom, the
`static` answers do not depend on the database. -/
theorem static_independent (P : List (Rule α)) (σ : α → Prop) (static : α → Prop)
    (closed : ∀ r ∈ P, static r.head → ∀ b ∈ r.pos, static b) {D D' : α → Prop}
    (hD : ∀ a, D a → ¬ static a) (hD' : ∀ a, D' a → ¬ static a) {a : α} (ha : static a) :
    answers P σ D a ↔ answers P σ D' a := by
  have none (E : α → Prop) (hE : ∀ a, E a → ¬ static a) (n : Nat) (x : α) :
      stage P σ (fun y => E y ∧ static y) n x ↔ stage P σ (fun _ => False) n x :=
    stage_congr_db P σ (fun y => ⟨fun h => hE y h.1 h.2, False.elim⟩) n x
  constructor
  · intro ⟨n, h⟩
    refine ⟨n, (stage_local P σ D' static closed n a ha).mpr ((none D' hD' n a).mpr ?_)⟩
    exact (none D hD n a).mp ((stage_local P σ D static closed n a ha).mp h)
  · intro ⟨n, h⟩
    refine ⟨n, (stage_local P σ D static closed n a ha).mpr ((none D hD n a).mpr ?_)⟩
    exact (none D' hD' n a).mp ((stage_local P σ D' static closed n a ha).mp h)

end Marien.Analysis.Semantics
