## 1. Rule analysis

- [x] 1.1 Clause AST walker over the host API, with `accumulate` resolved (`Marien/Analysis/Reach.lean`)
- [x] 1.2 Entry-point reachability with type-based over-approximation of variable predicates; store per-entry verdicts with the module
- [x] 1.3 Monotonicity check with offending construct, position and reached database predicate (`Marien/Analysis/Monotone.lean`)
- [x] 1.4 `dynamic` inference from `=>` with a database-predicate head; `% @marien dynamic` annotation; warning when a user tries to clear it
- [x] 1.5 Locality check: guarded atoms within radius, recorded directions, subject-is-anchor rule; key-partition join check (`Marien/Analysis/Locality.lean`)
- [x] 1.6 Recompute verdicts in M2's lazy recheck and in `elpi_recheck`
- [x] 1.7 Prove `Marien.Analysis.reach_closed`
- [ ] 1.8 (optional, stretch) Define an abstract finite Horn-with-negation semantics of the analysed fragment and prove `Marien.Analysis.monotone_sound`
- [ ] 1.9 (optional, stretch) Prove `Marien.Analysis.locality_sound` over that semantics; update the open question in `tg.md/overview.md`

## 2. Narrowed scope

- [x] 2.1 `scope` argument on `elpi_run` and `elpi_validate`; bind-time refusal for non-monotone entry points with the stored verdict
- [x] 2.2 Key-list filtering in the table scanner, edges only between listed restricted endpoints (`shim/scan.cpp`)
- [x] 2.3 `narrowed` output column

## 3. Partitioning

- [x] 3.1 Parse `% @marien partition` declarations (anchor and key forms) at save time
- [x] 3.2 Partition planner: anchor enumeration, batching by `elpi_partition_batch`, batch splitting at `elpi_max_facts` (`Marien/Exec/Partition.lean`)
- [x] 3.3 Neighbourhood scan in the calling transaction in recorded directions (`shim/scan.cpp`)
- [x] 3.4 Fresh store per batch; per-batch limits; fail the whole call on any batch failure
- [x] 3.5 Key partitions: hash buckets by property value, nulls excluded
- [x] 3.6 Structural facts: generate `in_cycle.<rel>` and `component.<rel>`; compute SCC/WCC in the calling transaction via the algo extension, or the built-in fallback (`shim/structure.cpp`) — the built-in routines only (decision "Structural facts from Marien's own graph routines")
- [x] 3.7 Reject partition declarations on dynamic entry points
- [x] 3.8 Prove `Marien.Partition.batches_partition`
- [x] 3.9 Prove `Marien.Partition.violation_unique_batch`
- [x] 3.10 Prove `Marien.Partition.key_buckets_sound`

## 4. Differential testing

- [x] 4.1 Seeded generators for schemas, graphs and modules, with shrinking (`tests/Property/Gen.lean`)
- [x] 4.2 Partition equivalence property at batch sizes 1, 7 and default
- [x] 4.3 Narrowing subset property
- [x] 4.4 Rejection counterexample search and the tracked rejection measure
- [ ] 4.5 Run the properties in CI against an embedded LadybugDB with the built extension

## 5. Traceability annotations

- [x] 5.1 `@tg: implements:: [[openspec:rule-analysis#Entry-point reachability]]`; `@tg: verifies::` for "Reachability through accumulate", "Variable predicates are over-approximated", "Unreached tables are excluded"
- [x] 5.2 `@tg: implements:: [[openspec:rule-analysis#Monotonicity check]]`; `@tg: verifies::` for "Negation over database facts is not monotone", "Negation over local facts stays monotone", "Cut is treated like negation"
- [x] 5.3 `@tg: implements:: [[openspec:rule-analysis#Dynamic inference]]`; `@tg: verifies::` for "Hypothetical database clause makes an entry point dynamic", "Users cannot clear dynamic"
- [x] 5.4 `@tg: implements:: [[openspec:rule-analysis#Locality check]]`; `@tg: verifies::` for "Outgoing edge within radius is accepted", "Unanchored atom is rejected", "Radius is enforced", "Subject must be the anchor"
- [x] 5.5 `@tg: implements:: [[openspec:partitioning#Anchor partitions]]`; `@tg: verifies::` for "Partitioned result equals full scope", "Each batch gets a fresh store", "A failing batch fails the call"
- [x] 5.6 `@tg: implements:: [[openspec:partitioning#Key partitions]]`; `@tg: verifies::` for "Duplicate emails are found across buckets", "Unjoined atom rejects the key partition"
- [x] 5.7 `@tg: implements:: [[openspec:partitioning#Structural facts]]`; `@tg: verifies::` for "Cycles come from SCC", "Structural facts are never stale"
- [x] 5.8 `@tg: implements:: [[openspec:partitioning#Dynamic entry points stay whole]]`; `@tg: verifies::` for "Partition on a dynamic entry point is rejected"
- [x] 5.9 `@tg: implements:: [[openspec:rule-execution#Narrowed scope for monotone entry points]]`; `@tg: verifies::` for "Monotone entry point accepts a scope", "Non-monotone entry point refuses a scope", "Narrowing never adds answers"
- [x] 5.10 `@tg: implements:: [[openspec:differential-testing#Random workload generation]]`; `@tg: verifies::` for "Seeds reproduce workloads", "Failures are shrunk"
- [x] 5.11 `@tg: implements:: [[openspec:differential-testing#Partition equivalence property]]`; `@tg: verifies::` for "Accepted partitions agree with full scope"
- [x] 5.12 `@tg: implements:: [[openspec:differential-testing#Narrowing subset property]]`; `@tg: verifies::` for "Narrowed runs are subsets"
- [x] 5.13 `@tg: implements:: [[openspec:differential-testing#Rejection counterexample property]]`; `@tg: verifies::` for "Rejections are measured"

## 6. Knowledge graph

- [x] 6.1 Record any new decisions and constraints from design.md (for example the algo-extension fallback) in `tg.md/decisions.md` and `tg.md/constraints.md`, with `motivated_by::` and `constrains:: [[openspec:<capability>#<Requirement>]] {strength: must}` edges
- [x] 6.2 Update the component sections for Rule analyzer, Partition planner, Structural facts, Test harness, Table scanner, Executor and Validator; add `rule-analysis`, `partitioning`, `differential-testing` and `rule-execution` to the `openspec:` frontmatter of `tg.md/architecture/components.md`
- [x] 6.3 Register the change in `tg.md/changes.md` as `add-analysis-and-partitioning`
- [x] 6.4 Run `tg check`, `tg ontology check`, and `tg trace rule-analysis --gaps`, `tg trace partitioning --gaps`, `tg trace differential-testing --gaps`, `tg trace rule-execution --gaps`; close every gap
