## 1. Engine change (in the lean-elpi repository)

- [ ] 1.1 Open the lean-elpi change `add-host-api` with this spec as its requirements, adapted to lean-elpi's capability names
- [ ] 1.2 `Elpi.Host` façade module re-exporting the stable types and functions
- [ ] 1.3 `PredSig` lookup from a compiled program's declarations
- [ ] 1.4 `buildGoal` with fresh output variables and signature type checking
- [ ] 1.5 `ResultTerm`, conversion from the final store, `toJson` and `fromJson?`
- [ ] 1.6 `Step.paused (resume)` produced in `runLoopS`; `runSlice` on prepared queries
- [ ] 1.7 Public `Ast.Program` view: declarations, modes, accumulates, clauses with positions, typed body goals
- [ ] 1.8 `loadUnits` with per-unit positions
- [ ] 1.8a `addFacts` bulk loading of ground facts as terms, with signature checks and in-place index append
- [ ] 1.9 Release LeanElpi 0.4.0 and update its changelog

## 2. Proofs (in lean-elpi)

- [ ] 2.1 Prove `ResultTerm.json_roundtrip : ResultTerm.fromJson? (ResultTerm.toJson t) = some t`
- [ ] 2.2 Prove `TyTerm.beq_iff_eq` for the signature comparison
- [ ] 2.3 Prove `addFacts_atomic`: on error the result carries no program, and on success every row of the batch is present

## 3. Marien side

- [ ] 3.1 Pin `lean-elpi` at `v0.4.0` in `lakefile.lean`
- [ ] 3.2 Write `tests/EngineContract.lean`, one test per scenario below, run in CI against the pinned release

## 4. Traceability

- [ ] 4.1 Annotate Marien's import wrapper in `Marien/Engine.lean` with `@tg: implements:: [[openspec:engine-host-api#Predicate signature lookup]] {note: "realized in lean-elpi Elpi.Host"}`, and add `verifies` above the tests for `#Declared predicate`, `#Polymorphic predicate` and `#Unknown predicate`
- [ ] 4.2 Annotate `implements:: [[openspec:engine-host-api#Goals built from terms]]`, and add `verifies` for `#Input values are not parsed as source` and `#Ill-typed argument`
- [ ] 4.3 Annotate `implements:: [[openspec:engine-host-api#Structured solution terms]]`, and add `verifies` for `#Constructor application`, `#Unbound output` and `#JSON form round-trips` (the last cites the theorem)
- [ ] 4.4 Annotate `implements:: [[openspec:engine-host-api#Resumable fuel slices]]`, and add `verifies` for `#Slices equal one run` and `#Pausing does not copy the store`
- [ ] 4.5 Annotate `implements:: [[openspec:engine-host-api#Public clause AST]]`, and add `verifies` for `#Negation and cut are visible` and `#Hypothetical clause is visible`
- [ ] 4.5a Annotate `implements:: [[openspec:engine-host-api#Bulk fact loading]]`, and add `verifies` for `#Facts from terms answer queries`, `#Loading is linear` and `#Ill-typed fact is rejected`
- [ ] 4.6 Annotate `implements:: [[openspec:engine-host-api#Multi-unit load keeps positions]]`, and add `verifies` for `#Error position inside the module`
- [ ] 4.7 Record in lat.md: once 0.4 ships, mark [[constraints#Out of fuel discards the search]] as resolved and note the release; add a Decision section for the host façade, `motivated_by:: [[decisions#Logic in Lean behind a thin C++ shim]]`
- [ ] 4.8 Update the [[components#Runtime bridge]] section and add `engine-host-api` to the `openspec:` frontmatter of `tg.md/architecture/components.md`
- [ ] 4.9 Run `tg check`, `tg ontology check` and `tg trace engine-host-api --gaps`, and close every gap they report
