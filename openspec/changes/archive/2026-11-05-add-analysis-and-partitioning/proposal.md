## Why

The target is 1M to 100M facts ([[constraints#Target scale is 1M to 100M facts]]), and after M2 every run loads every reached table in full into one LeanElpi store whose memory grows during long runs ([[constraints#LeanElpi memory grows in long runs]]). Validation mostly uses negation, so it cannot simply look at less data: a partial scope turns missing facts into false violations ([[decisions#Closed-world scope]]). M3 adds the static analyses that say when looking at less data is safe, and the execution modes that use them: narrowed scope for monotone entry points, anchor and key partitions for local and uniqueness rules, and structural facts computed by LadybugDB's graph algorithms. Property tests check the guarantees the analyses claim.

**Milestone:** M3 (analysis and scale).

**Depends on:** `add-typed-validation` (M2: `elpi_run`, `elpi_validate`, reached-table hashes), `add-tracer-bullet` (M1: full-scope materialization, fuel slicing, table scanning), `add-leanelpi-host-api` (M0: public clause AST for analysis, resumable fuel).

## What Changes

- Rule analysis at save time and on recheck: per-entry-point predicate reachability through rules and `accumulate`, a monotonicity check (no `not`, cut or `forall` over generated predicates), `dynamic` inference for entry points whose `=>` adds clauses with a database predicate head, and a locality check for declared partitions.
- Narrowed scope: `elpi_run` and `elpi_validate` accept a scope only for entry points proved monotone; any other request is an error.
- Partitioning: `partition violation by <kind> radius <n>` declares anchor partitions; anchors are processed in batches whose neighbourhoods are scanned in the calling transaction in the recorded directions, each batch in a fresh store. `partition violation by <table>.<prop>` declares key partitions for uniqueness rules. SCC and WCC from the algo extension are computed in the calling transaction and loaded as facts (`in_cycle`, `component`). Dynamic entry points are never partitioned.
- Differential property tests over random schemas, graphs and modules: partitioned equals full scope, narrowed is a subset of full scope, and every rejection has a counterexample graph.

## Capabilities

### New Capabilities
- `rule-analysis`: reachability, monotonicity, `dynamic` inference and locality.
- `partitioning`: anchor partitions, key partitions and structural facts.
- `differential-testing`: random workloads and the three equivalence properties.

### Modified Capabilities
- `rule-execution`: adds "Narrowed scope for monotone entry points".

## Impact

**Motivating decisions:**
- [[decisions#Closed-world scope]] ([[adr:0009]]): full scope unless a check proves otherwise.
- [[decisions#Partitioned validation]] ([[adr:0016]]): anchor, key and structural partitions.
- [[decisions#Scan tables in the calling transaction]] ([[adr:0021]]): neighbourhoods and structural facts are read in the caller's transaction, so they are never stale.
- [[decisions#Differential testing with an oracle]] ([[adr:0018]]): the analyses are tested against their claims.
- [[decisions#Proofs where practical]] ([[adr:0020]]): batch coverage and violation uniqueness are theorems; analysis soundness is a stretch goal.
- [[decisions#Staged rule generation over a reflected schema]] ([[adr:0010]]): M4 feeds generated code into these analyses, so they come first.

**Binding constraints:**
- [[constraints#Target scale is 1M to 100M facts]], [[constraints#LeanElpi memory grows in long runs]]: why partitions exist.
- [[constraints#Out of fuel discards the search]]: batch execution relies on M0's resumable fuel.

**Components introduced or extended:**
- [[components#Rule analyzer]] (`Marien/Analysis/Reach.lean`, `Marien/Analysis/Monotone.lean`, `Marien/Analysis/Locality.lean`), new.
- [[components#Partition planner]] (`Marien/Exec/Partition.lean`), new.
- [[components#Structural facts]] (`shim/structure.cpp`), new.
- [[components#Test harness]] (`tests/Property/`), new.
- [[components#Table scanner]] (`shim/scan.cpp`), [[components#Executor]], [[components#Validator]], extended.

**Requirements added:**
- [[openspec:rule-analysis#Entry-point reachability]], [[openspec:rule-analysis#Monotonicity check]], [[openspec:rule-analysis#Dynamic inference]], [[openspec:rule-analysis#Locality check]]
- [[openspec:partitioning#Anchor partitions]], [[openspec:partitioning#Key partitions]], [[openspec:partitioning#Structural facts]], [[openspec:partitioning#Dynamic entry points stay whole]]
- [[openspec:rule-execution#Narrowed scope for monotone entry points]]
- [[openspec:differential-testing#Random workload generation]], [[openspec:differential-testing#Partition equivalence property]], [[openspec:differential-testing#Narrowing subset property]], [[openspec:differential-testing#Rejection counterexample property]]

**Registered as:** [[changes#add-analysis-and-partitioning]].
