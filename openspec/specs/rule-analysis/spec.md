# rule-analysis Specification

## Purpose
Analyse each entry point of a module when it is saved or rechecked: the predicates and tables it reaches, whether it is monotone or dynamic, and whether a declared partition keeps every atom within the radius of its subject.

## Requirements

### Requirement: Entry-point reachability
At save time and on every recheck, the rule analyzer SHALL compute for each predicate with a mode declaration (each entry point) the set of predicates it can call, transitively through clause bodies, local clauses introduced by `=>` and modules pulled in by `accumulate`, using the parsed clause AST from the engine host API. It SHALL record the subset that are generated database predicates together with the tables they belong to, and SHALL store the result with the module. A call through a variable predicate (`R X Y` with `R` unbound at the clause) SHALL be over-approximated by every predicate whose type unifies with the variable's type.

#### Scenario: Reachability through accumulate
- **WHEN** entry point `violation` in `org` calls `manages` defined in accumulated module `base`, and `manages` uses `reports_to`
- **THEN** the reached database predicates of `violation` include `reports_to`

#### Scenario: Variable predicates are over-approximated
- **WHEN** a clause calls `R X Y` where `R : person -> person -> prop` is a parameter
- **THEN** every generated predicate of type `person -> person -> prop` is in the reached set

#### Scenario: Unreached tables are excluded
- **WHEN** `org` also defines a predicate over `Invoice` that no path from `violation` calls
- **THEN** `invoice.*` predicates are not in the reached set of `violation`

### Requirement: Monotonicity check
The rule analyzer SHALL mark an entry point monotone exactly when no clause reachable from it contains `not`, `!` (cut) or `forall`, or a call to a predicate implemented with them, whose goal can reach a generated database predicate. Monotone and non-monotone verdicts SHALL be stored per entry point with, for a non-monotone verdict, the source position of the first offending construct and the database predicate it reaches.

#### Scenario: Negation over database facts is not monotone
- **WHEN** `violation P :- person.name P _, not (reports_to P _ _).` is reachable from `violation`
- **THEN** `violation` is non-monotone and the verdict names `not` at its position and `reports_to`

#### Scenario: Negation over local facts stays monotone
- **WHEN** an entry point uses `not (member X [1, 2])` and no negated goal reaches a database predicate
- **THEN** the entry point is monotone

#### Scenario: Cut is treated like negation
- **WHEN** a reachable clause `first P :- person.name P _, !.` is called by the entry point
- **THEN** the entry point is non-monotone

### Requirement: Dynamic inference
The rule analyzer SHALL mark an entry point `dynamic` when any reachable goal of the form `C => G` adds a clause `C` whose head is a generated database predicate. A module MAY declare `% @marien dynamic <pred>` to mark an entry point dynamic explicitly; no declaration SHALL clear an inferred `dynamic` verdict. Dynamic entry points SHALL be treated as non-monotone.

#### Scenario: Hypothetical database clause makes an entry point dynamic
- **WHEN** a reachable goal is `(reports_to P E M) => check P`
- **THEN** the entry point is `dynamic` and non-monotone

#### Scenario: Users cannot clear dynamic
- **WHEN** a module annotates an entry point as not dynamic while it reaches such a goal
- **THEN** the entry point is still `dynamic` and `elpi_save` reports a warning naming the goal

### Requirement: Locality check
For an entry point with a declared anchor partition of kind `K` and radius `n`, the rule analyzer SHALL accept the partition only when every database atom reachable from the entry point is guarded: connected to the anchor variable (the subject argument) through a chain of at most `n` edge atoms whose shared variables link the anchor to the atom. It SHALL record, for each edge predicate in such a chain, the directions (outgoing, incoming) in which it is traversed from the anchor. It SHALL also require that the entry point's `subject` argument is `subj_<k> A` where `A` is the anchor variable. A rejected partition SHALL be reported at save time with the first unguarded atom and its position.

#### Scenario: Outgoing edge within radius is accepted
- **WHEN** `violation error "no-manager" (subj_person P) :- person.name P _, not (reports_to P _ _).` declares `partition violation by person radius 1`
- **THEN** the partition is accepted with `reports_to` recorded as outgoing

#### Scenario: Unanchored atom is rejected
- **WHEN** a clause adds `person.name Q "Bob"` with `Q` not linked to the anchor
- **THEN** the partition is rejected and the error names `person.name` at its position

#### Scenario: Radius is enforced
- **WHEN** a clause reaches a fact two `reports_to` hops from the anchor under `radius 1`
- **THEN** the partition is rejected

#### Scenario: Subject must be the anchor
- **WHEN** a clause reports `subj_person M` where `M` is the anchor's manager
- **THEN** the partition is rejected with an error saying the subject must be the anchor
