## ADDED Requirements

### Requirement: Relation combinators
The extension SHALL ship an ELPI module `graph.std` that a module can `accumulate`. It SHALL declare its combinators with prenex polymorphism over relation predicates of type `A -> E -> B -> prop` (a reified-edge relation from the encoding) and over their projections `A -> B -> prop`, so that one combinator applies to every rel table. It SHALL provide at least: `edge_of R X Y` (projection that drops the edge term), `closure R X Y` (transitive closure, terminating on cyclic finite relations), `symmetric_witness R X Y` (a pair related one way but not the other), and `functional_witness R X Y1 Y2` (two distinct targets from one source). On a finite relation, each combinator's answer set SHALL equal that of a Lean reference implementation over the same edge set.

#### Scenario: Closure over a relation
- **WHEN** `reports_to` holds edges a→b and b→c, and `closure (edge_of reports_to) a Y` is solved
- **THEN** the solutions are exactly `Y = b` and `Y = c`

#### Scenario: Closure terminates on cycles
- **WHEN** `reports_to` holds edges a→b and b→a
- **THEN** `closure (edge_of reports_to) a Y` returns `b` and `a`, each once, and the search is exhausted

#### Scenario: One combinator, two relations
- **WHEN** a module applies `closure` to both `edge_of reports_to` (over `person`) and `edge_of part_of` (over `part`)
- **THEN** the module typechecks and both calls return their relation's closure

#### Scenario: Functional witness
- **WHEN** `has_manager` holds edges p→m1 and p→m2 with `m1` and `m2` distinct
- **THEN** `functional_witness (edge_of has_manager) p Y1 Y2` succeeds with `{Y1, Y2} = {m1, m2}`

### Requirement: Cycle detection
`graph.std` SHALL provide `acyclic R` (succeeds when the projection `R` has no cycle reachable within the loaded facts) and `acyclic_witness R X` (succeeds once for each node `X` that lies on a cycle of `R`). Both SHALL terminate on every finite relation. When precomputed structural facts from the algo extension (`in_cycle`) are loaded for `R`, `acyclic_witness` SHALL use them and SHALL return the same answer set as the search-based version.

#### Scenario: Witnesses on a cycle
- **WHEN** `part_of` holds a→b, b→c, c→a and d→a
- **THEN** `acyclic_witness (edge_of part_of) X` yields exactly `a`, `b` and `c`, and `acyclic (edge_of part_of)` fails

#### Scenario: Precomputed facts agree with search
- **WHEN** the same `part_of` relation is validated once with search and once with `in_cycle` facts from strongly connected components
- **THEN** both runs report the same set of witnesses

### Requirement: Cardinality checks
`graph.std` SHALL provide `card R X Min Max` and `card_witness R Min Max X N`. `card_witness` SHALL succeed once for each source node `X` in the loaded facts of the source kind whose number of distinct targets `N` under `R` is below `Min` or above `Max`. A `Max` of `-1` SHALL mean unbounded. Nodes with no outgoing edge SHALL count as `N = 0`.

#### Scenario: Missing mandatory edge
- **WHEN** person `p` has no `has_manager` edge and `card_witness (edge_of has_manager) 1 1 X N` is solved
- **THEN** a solution `X = p, N = 0` is returned

#### Scenario: Unbounded maximum
- **WHEN** a person has five `knows` edges and `card_witness (edge_of knows) 0 (-1) X N` is solved
- **THEN** no solution names that person

### Requirement: Combinators in violation rules
Rules built from `graph.std` combinators SHALL take part in `elpi_validate` like any other rule, and the rule analysis SHALL treat each combinator by its definition: a combinator that uses negation (`acyclic`, `card_witness`, `symmetric_witness`, `functional_witness`) SHALL make the calling entry point non-monotone. `graph.std` SHALL declare locality metadata: `card_witness`, `functional_witness` and `symmetric_witness` SHALL be local at radius 1 around their source node, and `closure`, `acyclic` and `acyclic_witness` SHALL be non-local unless structural facts are used.

#### Scenario: Cardinality rule partitions by anchor
- **WHEN** `violation error "no-manager" (subj_person X) :- card_witness (edge_of has_manager) 1 1 X _.` declares `partition violation by person radius 1`
- **THEN** the module saves, and partitioned `elpi_validate` returns the same rows as full scope

#### Scenario: Search-based cycle rule cannot be anchor-partitioned
- **WHEN** a violation rule uses search-based `acyclic_witness` and declares an anchor partition
- **THEN** the save fails with a locality error that names `acyclic_witness`
