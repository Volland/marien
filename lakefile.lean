import Lake

open System Lake DSL

package marien where
  version := v!"0.0.1"
  description := "LadybugDB extension that stores λProlog (ELPI) rules in the database and runs them with LeanElpi."
  license := "Apache-2.0"
  leanOptions := #[⟨`autoImplicit, false⟩]

-- LeanElpi's host API (lean-elpi change `add-host-api`), pinned by commit until it is released
-- as v0.4.0 (task 3.1 of openspec/changes/add-leanelpi-host-api).
require «lean-elpi» from git "https://github.com/Volland/lean-elpi" @ "91ea5ba471f930c8314c79a758fa9c76f20f65dd"

@[default_target] lean_lib Marien

/-- The test suites the test driver runs. -/
lean_lib Tests where
  srcDir := "tests"
  roots := #[`EngineContract, `M1, `M2]

/-- `lake test`: the engine contract (one check per `engine-host-api` scenario, against the pinned
LeanElpi) and the M1 unit tests of the Lean layers. -/
@[test_driver] lean_exe «marien-tests» where
  root := `Main
  srcDir := "tests"
