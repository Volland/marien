# differential-testing Specification

## Purpose
Check the analyses against execution on random workloads: seeded, shrinkable generators of schemas, graphs and modules; partition equivalence and narrowing subset properties; and a measure of how conservative the rejections are. M5 adds the Soufflé oracle.

## Requirements

### Requirement: Random workload generation
The test harness SHALL generate, from a seed, random schemas (node tables, rel tables including ones with several FROM/TO pairs, every property type with a codec mapping, nullable columns), random graphs over a schema (with controllable size, degree, cycles and duplicate property values), and random rule modules over the generated signature drawn from a grammar that covers conjunction, disjunction, `not`, cut, `forall`, `=>`, recursion and the `violation` protocol. Every failing case SHALL be reported with its seed and SHALL be shrunk to a smaller failing case before it is reported.

#### Scenario: Seeds reproduce workloads
- **WHEN** the generator runs twice with the same seed
- **THEN** it produces byte-identical schemas, graphs and module sources

#### Scenario: Failures are shrunk
- **WHEN** a property fails on a generated case
- **THEN** the report contains a seed and a case no larger than the original that still fails

### Requirement: Partition equivalence property
For every generated module whose declared anchor or key partition the locality check accepts, and every generated graph, the harness SHALL check that the partitioned run returns the same rows as the full-scope run, compared as multisets, for batch sizes 1, 7 and the default.

#### Scenario: Accepted partitions agree with full scope
- **WHEN** 1000 accepted partitioned modules run over random graphs at the three batch sizes
- **THEN** every partitioned result equals its full-scope result as a multiset

### Requirement: Narrowing subset property
For every generated module entry point marked monotone and every random scope over a random graph, the harness SHALL check that the narrowed run's rows are a sub-multiset of the full-scope run's rows.

#### Scenario: Narrowed runs are subsets
- **WHEN** 1000 monotone entry points run with random scopes
- **THEN** every narrowed result is contained in its full-scope result

### Requirement: Rejection counterexample property
For a sample of generated modules whose partition the locality check rejects, or whose entry point the monotonicity check rejects, the harness SHALL search for a graph and a partition or scope on which the partitioned or narrowed run differs from the full-scope run, and SHALL report the fraction of rejections for which a counterexample was found. The fraction SHALL be tracked over time as the measure of how conservative the analyses are; a missing counterexample SHALL NOT fail the build.

#### Scenario: Rejections are measured
- **WHEN** the harness samples 200 rejected modules
- **THEN** it reports how many had a counterexample, with one example seed per rejection reason
